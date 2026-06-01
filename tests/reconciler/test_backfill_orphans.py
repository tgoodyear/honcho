from contextlib import asynccontextmanager
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest

from src.reconciler import scheduler, sync_vectors


@pytest.mark.asyncio
async def test_backfill_orphan_message_embeddings_creates_rows_and_continues_on_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    added_embeddings: list[object] = []
    orphan_messages = [
        SimpleNamespace(
            public_id="msg_1",
            content="first message",
            workspace_name="ws",
            session_name="session",
            peer_name="peer",
        ),
        SimpleNamespace(
            public_id="msg_2",
            content="second message",
            workspace_name="ws",
            session_name="session",
            peer_name="peer",
        ),
    ]

    @asynccontextmanager
    async def fake_tracked_db(operation_name: str | None = None):
        assert operation_name == "reconciliation_orphan_backfill"
        yield fake_db

    async def fake_get_orphan_messages(_db: object, batch_size: int = 100):
        assert batch_size == sync_vectors.ORPHAN_BACKFILL_BATCH_SIZE
        return orphan_messages

    async def fake_embed(content: str) -> list[float]:
        if content == "second message":
            raise RuntimeError("token expired")
        return [1.0] * 1536

    def capture_add(embedding: object) -> None:
        added_embeddings.append(embedding)

    fake_db = SimpleNamespace(
        scalar=AsyncMock(side_effect=[None, None]),
        add=MagicMock(side_effect=capture_add),
        commit=AsyncMock(),
        rollback=AsyncMock(),
    )

    monkeypatch.setattr(sync_vectors, "tracked_db", fake_tracked_db)
    monkeypatch.setattr(sync_vectors, "_get_orphan_messages", fake_get_orphan_messages)
    monkeypatch.setattr(sync_vectors.settings, "EMBED_MESSAGES", True)
    monkeypatch.setattr(sync_vectors.embedding_client, "embed", fake_embed)

    found, fixed, failed = await sync_vectors.backfill_orphan_message_embeddings()

    assert (found, fixed, failed) == (2, 1, 1)
    assert len(added_embeddings) == 1
    added_embedding = added_embeddings[0]
    assert added_embedding.message_id == "msg_1"
    assert added_embedding.sync_state == "synced"
    assert added_embedding.workspace_name == "ws"
    assert added_embedding.session_name == "session"
    assert added_embedding.peer_name == "peer"
    assert added_embedding.embedding == [1.0] * 1536
    fake_db.commit.assert_awaited_once()
    fake_db.rollback.assert_awaited_once()


def test_backfill_orphans_task_registered_with_same_cadence_as_sync_vectors() -> None:
    backfill_task = scheduler.RECONCILER_TASKS["backfill_orphans"]
    sync_task = scheduler.RECONCILER_TASKS["sync_vectors"]

    assert backfill_task.name == "backfill_orphans"
    assert backfill_task.work_unit_key == "reconciler:backfill_orphans"
    assert backfill_task.interval_seconds == sync_task.interval_seconds
