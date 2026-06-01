"""
Backfill missing message_embeddings rows for messages that have none.

This is intended for the case where message rows were committed but embedding
row creation failed, typically due to an expired Azure OpenAI token.

Usage (from inside the deriver container):
  python /app/backfill-orphan-embeddings.py [--workspace ave-team] [--batch-size 50] [--dry-run]
"""

import argparse
import asyncio
import logging
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime

# Ensure we can import from /app when running in the container
sys.path.insert(0, "/app")

from pgvector.sqlalchemy import Vector
from sqlalchemy import func, select

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [orphan-backfill] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("orphan-backfill")


@dataclass(frozen=True)
class OrphanMessage:
    id: int
    public_id: str
    content: str
    workspace_name: str
    session_name: str
    peer_name: str


RETRYABLE_MARKERS = (
    "429",
    "rate limit",
    "too many requests",
    "temporarily unavailable",
    "timeout",
    "connection",
    "server busy",
)


async def fetch_total(workspace_name: str) -> int:
    from src import models
    from src.dependencies import tracked_db

    async with tracked_db("orphan_backfill.count") as db:
        stmt = (
            select(func.count(models.Message.id))
            .select_from(models.Message)
            .outerjoin(
                models.MessageEmbedding,
                models.MessageEmbedding.message_id == models.Message.public_id,
            )
            .where(models.Message.workspace_name == workspace_name)
            .where(models.MessageEmbedding.id.is_(None))
        )
        result = await db.execute(stmt)
        return int(result.scalar_one() or 0)


async def fetch_batch(workspace_name: str, batch_size: int) -> list[OrphanMessage]:
    from src import models
    from src.dependencies import tracked_db

    async with tracked_db("orphan_backfill.fetch_batch") as db:
        stmt = (
            select(
                models.Message.id,
                models.Message.public_id,
                models.Message.content,
                models.Message.workspace_name,
                models.Message.session_name,
                models.Message.peer_name,
            )
            .select_from(models.Message)
            .outerjoin(
                models.MessageEmbedding,
                models.MessageEmbedding.message_id == models.Message.public_id,
            )
            .where(models.Message.workspace_name == workspace_name)
            .where(models.MessageEmbedding.id.is_(None))
            .order_by(models.Message.id)
            .limit(batch_size)
        )
        result = await db.execute(stmt)
        return [OrphanMessage(*row) for row in result.all()]


async def insert_embeddings(
    messages: list[OrphanMessage],
    embedding_map: dict[str, list[list[float]]],
) -> int:
    from src import models
    from src.dependencies import tracked_db

    now = datetime.now(UTC)
    embedding_rows: list[models.MessageEmbedding] = []

    for message in messages:
        embeddings = embedding_map.get(message.public_id, [])
        if not embeddings:
            raise ValueError(
                f"No embeddings were returned for message {message.public_id}."
            )

        for embedding in embeddings:
            embedding_rows.append(
                models.MessageEmbedding(
                    content=message.content,
                    message_id=message.public_id,
                    workspace_name=message.workspace_name,
                    session_name=message.session_name,
                    peer_name=message.peer_name,
                    embedding=embedding,
                    sync_state="synced",
                    last_sync_at=now,
                    sync_attempts=0,
                )
            )

    async with tracked_db("orphan_backfill.insert_batch") as db:
        db.add_all(embedding_rows)
        await db.commit()

    return len(embedding_rows)


def is_retryable_error(exc: Exception) -> bool:
    message = str(exc).lower()
    return any(marker in message for marker in RETRYABLE_MARKERS)


async def embed_with_backoff(
    embedding_client,
    id_resource_dict: dict[str, tuple[str, list[int]]],
    *,
    batch_number: int,
    max_attempts: int = 6,
) -> dict[str, list[list[float]]]:
    delay_seconds = 2.0

    for attempt in range(1, max_attempts + 1):
        try:
            return await embedding_client.batch_embed(id_resource_dict)
        except Exception as exc:
            if attempt >= max_attempts or not is_retryable_error(exc):
                raise

            log.warning(
                "Batch %s hit a transient embedding error on attempt %s/%s: %s. Retrying in %.0fs",
                batch_number,
                attempt,
                max_attempts,
                exc,
                delay_seconds,
            )
            await asyncio.sleep(delay_seconds)
            delay_seconds = min(delay_seconds * 2, 60.0)

    raise RuntimeError("Embedding retry loop exited unexpectedly")


async def main(batch_size: int, workspace_name: str, dry_run: bool) -> None:
    from src.config import settings
    from src.db import engine as async_engine
    from src.embedding_client import EmbeddingClient

    # Keep the pgvector SQLAlchemy type imported and initialized alongside the ORM model.
    Vector(settings.EMBEDDING.VECTOR_DIMENSIONS)

    log.info(
        "Embedding model %s on %s with %s dimensions",
        settings.EMBEDDING.MODEL_CONFIG.model,
        settings.EMBEDDING.MODEL_CONFIG.overrides.base_url,
        settings.EMBEDDING.VECTOR_DIMENSIONS,
    )

    total_messages = await fetch_total(workspace_name)
    log.info("Found %s messages without embedding rows in workspace '%s'", total_messages, workspace_name)

    if total_messages == 0:
        await async_engine.dispose()
        return

    if dry_run:
        log.info("Dry run requested; no embeddings were created")
        await async_engine.dispose()
        return

    embedding_client = EmbeddingClient()
    processed_messages = 0
    created_rows = 0
    batch_number = 0
    started_at = time.monotonic()

    while True:
        messages = await fetch_batch(workspace_name, batch_size)
        if not messages:
            break

        batch_number += 1
        id_resource_dict = {
            message.public_id: (
                message.content,
                embedding_client.encoding.encode(message.content),
            )
            for message in messages
        }

        embedding_map = await embed_with_backoff(
            embedding_client,
            id_resource_dict,
            batch_number=batch_number,
        )
        created_this_batch = await insert_embeddings(messages, embedding_map)

        processed_messages += len(messages)
        created_rows += created_this_batch
        elapsed = max(time.monotonic() - started_at, 0.001)
        rate = processed_messages / elapsed
        remaining_messages = max(total_messages - processed_messages, 0)
        eta_seconds = remaining_messages / rate if rate > 0 else 0.0

        log.info(
            "Batch %s complete: %s messages processed, %s embedding rows created (%s/%s messages, %.2f msg/s, ETA %.0fs)",
            batch_number,
            len(messages),
            created_this_batch,
            processed_messages,
            total_messages,
            rate,
            eta_seconds,
        )

    elapsed = time.monotonic() - started_at
    remaining = await fetch_total(workspace_name)
    log.info(
        "Finished in %.1fs. Created %s embedding rows for %s messages. Remaining orphan messages: %s",
        elapsed,
        created_rows,
        processed_messages,
        remaining,
    )

    await async_engine.dispose()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--workspace", default="ave-team")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.batch_size, args.workspace, args.dry_run))
