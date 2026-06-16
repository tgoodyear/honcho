# Upgrading the Azure/AVE Honcho deployment

This fork runs Honcho for the **AVE team** with Azure-specific customizations on top of
upstream [`plastic-labs/honcho`](https://github.com/plastic-labs/honcho). This document is
the concrete, repeatable path to pull a new upstream release while preserving those
customizations and the ingested data.

## Layout

- **Remotes:** `origin` = `tgoodyear/honcho` (our fork), `upstream` = `plastic-labs/honcho`.
- **Deploy branch:** `deploy/azure-vX.Y.Z-wip` (e.g. `deploy/azure-v3.0.10-wip`).
- **Runtime:** Podman Compose (`docker-compose.yml`) builds `honcho-api` and `honcho-deriver`
  from the same `Dockerfile`; `database` (pgvector) and `redis` use upstream images.
- **Data:** Postgres volume `honcho_pgdata` (workspace `ave-team`). Rebuilds do **not** touch it.

## Azure customizations to preserve (the recurring conflict surface)

These commits/areas are ours and must survive every upgrade:

- `src/embedding_client.py` — `azure_openai` transport + Entra ID (`azure_ad_token` /
  `AZURE_OPENAI_AD_TOKEN` / token-provider) auth. **Main merge hotspot** (upstream changes
  embedding here too, e.g. defer-embedding #704).
- `src/config.py` — `transport=azure_openai`, `use_entra_id` config.
- `src/deriver/queue_manager.py` — our deriver auto-dreams/reconciler fix (check whether a
  new upstream release supersedes it, e.g. Deriver Jitter / backoff).
- `src/reconciler/sync_vectors.py`, `backfill-embeddings.py`, `backfill-orphan-embeddings.py`.
- `honcho-foundry/` (Azure Foundry IaC), `Refresh-HonchoToken.ps1`, `.env.template`,
  `config.toml.example`, `docker-compose.yml` (mounts `${USERPROFILE}/.azure`, sets
  `AZURE_CONFIG_DIR`).
- Tests: `tests/llm/test_embedding_client.py` (keep **both** our Azure tests and upstream's).

## Procedure

### 0. Pre-flight safety (always)

```powershell
$h = "C:\Users\tgoodyear\honcho"; $ts = Get-Date -Format yyyyMMdd-HHmmss
# a) Tag current images for image-level rollback
podman tag honcho-api:latest      honcho-api:rollback-<current-tag>
podman tag honcho-deriver:latest  honcho-deriver:rollback-<current-tag>
# b) Full DB dump (data-level rollback) -> .upgrade-backup/ (gitignored)
podman exec honcho-database-1 sh -c "pg_dump -U postgres -d postgres -f /tmp/honcho-$ts.sql"
podman cp "honcho-database-1:/tmp/honcho-$ts.sql" "$h\.upgrade-backup\honcho-$ts.sql"
```

Record current commit (`git -C $h describe --tags`) and rollback image tags in
`.upgrade-backup/ROLLBACK-INFO.txt`. The `.upgrade-backup/` dir is **gitignored** — never
commit the multi-GB dump.

### 1. Check what's new

```powershell
git -C $h fetch upstream --tags --prune
git -C $h tag --sort=-v:refname | Select-Object -First 5        # newest releases
git -C $h log --oneline HEAD..<newtag>                          # incoming commits
git -C $h diff --name-only HEAD..<newtag> | Select-String "migrations|alembic|\.sql"  # DB migrations?
```

If migrations exist, they run automatically on container start via `docker/entrypoint.sh`
(`alembic upgrade head`) — review them and ensure the DB dump (step 0b) is fresh.

### 2. Branch + merge

```powershell
git -C $h checkout -- uv.lock                 # discard any stray lock pin
git -C $h checkout -b deploy/azure-<newtag>-wip
git -C $h merge --no-ff --no-commit <newtag>  # e.g. v3.0.10
git -C $h diff --name-only --diff-filter=U    # conflicts
```

### 3. Resolve conflicts

Focus on the surface listed above. For `tests/llm/test_embedding_client.py`, keep both
sides' test functions (re-add `@pytest.mark.asyncio` on upstream's first function if the
shared decorator landed on ours). After resolving:

```powershell
git -C $h add -A                              # .upgrade-backup is gitignored
git -C $h diff --cached --diff-filter=U --name-only   # must be empty
python -m py_compile src\embedding_client.py src\config.py src\deriver\queue_manager.py src\reconciler\sync_vectors.py tests\llm\test_embedding_client.py
git -C $h commit -F <msg-file-OUTSIDE-repo>
```

### 4. Build (non-destructive — running stack stays on old `:latest`)

```powershell
cd $h; podman compose build
# import smoke on the new image:
podman run --rm honcho-api:latest /app/.venv/bin/python -c `
  "import src.main, src.embedding_client, src.config, src.deriver.queue_manager, src.reconciler.sync_vectors; print('IMPORTS OK')"
```

### 5. Recreate + verify

```powershell
cd $h; podman compose up -d                   # recreates api+deriver on new images
podman ps --format "{{.Names}} {{.Status}}" | Select-String honcho
podman logs --tail 25 honcho-api-1            # alembic no-op / clean startup
# functional:
#  - POST /v3/workspaces/ave-team/search {"query":"...","limit":5}  -> results > 0 (data intact)
#  - POST .../sessions/<sid>/messages                                -> HTTP 201 (writes work)
#  - podman logs honcho-deriver-1                                    -> PERFORMANCE panels, no crashes
```

### 6. Finalize

- Push branch to `origin`, open a PR for review (optional but recommended).
- Once stable, this branch becomes the new deploy baseline for the next upgrade.

## Rollback

No-migration upgrades are reversible at the image level (data volume is untouched):

```powershell
podman tag honcho-api:rollback-<old-tag>     honcho-api:latest
podman tag honcho-deriver:rollback-<old-tag> honcho-deriver:latest
cd $h; podman compose up -d
```

If a migration was applied (or data is suspect), restore the dump:

```powershell
# CAUTION: replaces current workspace data
podman cp "$h\.upgrade-backup\honcho-<ts>.sql" honcho-database-1:/tmp/restore.sql
podman exec honcho-database-1 sh -c "psql -U postgres -d postgres -f /tmp/restore.sql"
```

## History

| Date | From | To | Conflicts | DB migrations | Notes |
|------|------|----|-----------|---------------|-------|
| 2026-06-16 | v3.0.7 (+5 azure) | v3.0.10 | `tests/llm/test_embedding_client.py` (kept both) | none | defer-embedding #704, deriver jitter/backoff, dedup, read-db. Azure transport + Entra preserved. Verified: search/write/deriver OK. |
