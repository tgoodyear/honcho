"""
Backfill NULL embeddings in message_embeddings table.

In pgvector mode, embeddings are computed inline at message creation.
If the embedding API was down during creation, rows get NULL vectors
and are marked "synced" — the reconciler won't retry them.

This script reads NULL-embedding rows in batches, calls the embedding
API, and updates them in place.

Usage (from inside the deriver container):
  python /app/backfill-embeddings.py [--batch-size 50] [--dry-run]
"""

import argparse
import asyncio
import logging
import os
import sys
import time

# Ensure we can import from /app
sys.path.insert(0, "/app")

from sqlalchemy import text, update
from pgvector.sqlalchemy import Vector

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [backfill] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("backfill")


async def get_token():
    """Get a fresh Azure OpenAI AD token via az CLI (MSIT tenant)."""
    import subprocess
    try:
        result = subprocess.run(
            ["az", "account", "get-access-token",
             "--resource", "https://cognitiveservices.azure.com",
             "--tenant", "72f988bf-86f1-41af-91ab-2d7cd011db47",
             "--query", "accessToken", "-o", "tsv"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "AZURE_CLOUD_NAME": "AzureCloud"},
        )
        if result.returncode == 0 and result.stdout.strip().startswith("eyJ"):
            return result.stdout.strip()
    except Exception:
        pass
    # Fallback to env var
    return os.environ.get("AZURE_OPENAI_AD_TOKEN")


async def embed_batch(client, model: str, texts: list[str], dimensions: int) -> list[list[float]]:
    """Call the embedding API for a batch of texts."""
    response = await client.embeddings.create(
        model=model,
        input=texts,
        dimensions=dimensions,
    )
    return [d.embedding for d in response.data]


# Rate limit: 120 requests/min = 2/sec. With batch_size tokens,
# we need to pace to stay under the token-per-minute limit too (120K TPM).
REQUESTS_PER_MINUTE = 100  # stay under 120 RPM with margin


async def main(batch_size: int = 50, dry_run: bool = False):
    from src.config import settings
    from src.dependencies import tracked_db
    from src import models

    # Set up embedding client from Honcho's config
    from openai import AsyncAzureOpenAI
    token = await get_token()
    if not token:
        log.error("No AZURE_OPENAI_AD_TOKEN set")
        return

    mc = settings.EMBEDDING.MODEL_CONFIG
    client = AsyncAzureOpenAI(
        azure_ad_token=token,
        azure_endpoint=mc.overrides.base_url,
        api_version=mc.overrides.api_version,
    )
    model = mc.model
    dimensions = settings.EMBEDDING.VECTOR_DIMENSIONS
    log.info(f"Model: {model}, dimensions: {dimensions}, endpoint: {mc.overrides.base_url}")

    # Count total work
    async with tracked_db("backfill_count") as db:
        result = await db.execute(
            text("SELECT COUNT(*) FROM message_embeddings WHERE embedding IS NULL")
        )
        total = result.scalar()
    log.info(f"Total rows needing embeddings: {total}")

    if total == 0:
        log.info("Nothing to do!")
        return

    if dry_run:
        log.info("Dry run — not computing any embeddings")
        return

    processed = 0
    failed = 0
    start = time.monotonic()
    last_token_refresh = time.monotonic()
    TOKEN_REFRESH_INTERVAL = 30 * 60  # 30 minutes

    while processed + failed < total:
        async with tracked_db("backfill_batch") as db:
            # Get a batch of NULL-embedding rows
            result = await db.execute(
                text("""
                    SELECT id, content 
                    FROM message_embeddings 
                    WHERE embedding IS NULL 
                    ORDER BY id 
                    LIMIT :limit
                """),
                {"limit": batch_size},
            )
            rows = result.fetchall()

            if not rows:
                break

            # Refresh token periodically
            if time.monotonic() - last_token_refresh > TOKEN_REFRESH_INTERVAL:
                new_token = await get_token()
                if new_token and new_token != token:
                    token = new_token
                    client = AsyncAzureOpenAI(
                        azure_ad_token=token,
                        azure_endpoint=mc.overrides.base_url,
                        api_version=mc.overrides.api_version,
                    )
                    last_token_refresh = time.monotonic()
                    log.info("Token refreshed")

            ids = [r[0] for r in rows]
            texts = [r[1] for r in rows]

            try:
                embeddings = await embed_batch(client, model, texts, dimensions)

                # Update each row using ORM to avoid raw SQL cast issues
                from sqlalchemy import update as sa_update
                from sqlalchemy.sql.functions import func as sa_func
                for row_id, embedding in zip(ids, embeddings):
                    await db.execute(
                        sa_update(models.MessageEmbedding)
                        .where(models.MessageEmbedding.id == row_id)
                        .values(
                            embedding=embedding,
                            sync_state="synced",
                            last_sync_at=sa_func.now(),
                            sync_attempts=0,
                        )
                    )

                await db.commit()
                processed += len(rows)

                elapsed = time.monotonic() - start
                rate = processed / elapsed if elapsed > 0 else 0
                remaining = (total - processed - failed) / rate if rate > 0 else 0
                log.info(
                    f"Progress: {processed}/{total} embedded "
                    f"({failed} failed) | "
                    f"{rate:.1f}/s | "
                    f"ETA: {remaining:.0f}s"
                )

                # Pace to avoid rate limits
                await asyncio.sleep(60.0 / REQUESTS_PER_MINUTE)

            except Exception as e:
                log.error(f"Batch failed: {e}")
                failed += len(rows)
                # Mark these as attempted so we skip them next round
                try:
                    await db.rollback()
                    from sqlalchemy import update as sa_update
                    from sqlalchemy.sql.functions import func as sa_func
                    await db.execute(
                        sa_update(models.MessageEmbedding)
                        .where(models.MessageEmbedding.id.in_(ids))
                        .values(
                            sync_attempts=models.MessageEmbedding.sync_attempts + 1,
                            last_sync_at=sa_func.now(),
                        )
                    )
                    await db.commit()
                except Exception:
                    pass

                # Rate limit backoff
                if "rate" in str(e).lower() or "429" in str(e):
                    log.info("Rate limited, waiting 30s...")
                    await asyncio.sleep(30)
                else:
                    await asyncio.sleep(2)

    elapsed = time.monotonic() - start
    log.info(f"Done! {processed} embedded, {failed} failed in {elapsed:.1f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(batch_size=args.batch_size, dry_run=args.dry_run))
