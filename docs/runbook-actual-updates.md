# Runbook: updating Actual Budget

**Stack:** `infra/actual/docker-compose.yml` on the Hetzner VPS at `/opt/household-os/actual`
**Data:** `/mnt/data/actual` (persistent volume — survives container recreation)
**Backups:** `infra/actual/backup.sh` → Cloudflare R2 (weekly; also run manually before an update)
**Verify:** `docker compose ps` shows `actual-server` as `Up (healthy)`

This covers updating the **Actual Budget server** container. It does **not** cover OS
patches (see [`runbook-os-updates.md`](runbook-os-updates.md)) or the MCP budget server,
which is a separate release track — see [§4](#4--the-mcp-server-caveat-read-before-you-update).

---

## 0 — Before you start

The `actual-server` image is currently pinned to **`:latest`** in `docker-compose.yml`, so
an update is *pulling a newer image and recreating the container* — there's no version
number to edit. The trade-off: `:latest` doesn't record which build you were on, which
complicates rollback. [§5](#5--recommended-pin-a-version-tag-instead-of-latest) explains how
to switch to a pinned tag so updates and rollbacks become deliberate, git-tracked changes.

Set the server IP locally (same as the other runbooks):

```bash
IP=<your-server-ipv4>    # or: IP=$(cd infra/terraform && terraform output -raw server_ipv4)
```

Check the [Actual release notes](https://github.com/actualbudget/actual/releases) first —
especially for a **major** version bump — for any breaking-change or migration warnings.
As of this writing the current release is **v26.7.0**.

---

## 1 — Back up and record the current version

Always take a fresh backup immediately before updating, and record the image digest you're
on so you have a concrete rollback target (this is what `:latest` otherwise loses).

```bash
ssh root@$IP
cd /opt/household-os/actual

# 1a. Fresh backup to R2 (pauses Actual ~1s).
./backup.sh
# Ends with "Backup complete." — note the archive name it uploads.

# 1b. Record the CURRENT image digest — this is your rollback target.
docker compose images actual-server
# Copy the IMAGE / DIGEST, e.g.:
#   actualbudget/actual-server   latest   sha256:abc123...
# Keep this sha256 somewhere safe until the update is confirmed good.
```

> **Why record the digest?** `restore.sh` restores your *data* but not the *binary*
> ([§3](#3--rollback-plan) explains why that distinction matters). Under `:latest` the old
> image loses its tag on the next `pull` and survives only as a dangling image until pruned,
> so the digest is the reliable handle for rolling the binary back.

---

## 2 — Update

```bash
# Still in /opt/household-os/actual on the server.

# 2a. Pull the newest image.
docker compose pull actual-server

# 2b. Recreate ONLY actual-server (Caddy and actual-mcp keep running).
docker compose up -d actual-server

# 2c. Verify it came back healthy.
docker compose ps
# actual-server should show "Up (healthy)" (health check may take ~60s to flip to healthy).
docker compose logs --tail=30 actual-server
# Should show a clean startup on port 5006, no errors.

exit
```

Then open `https://budget.yourdomain.com` in a browser and confirm your budget loads.

> **First load after an update** may prompt to **migrate the budget file to a newer
> format**. This is expected and safe — click through it. Note that once the data has been
> migrated, an **older** server version may refuse to open it, which is exactly why a
> rollback must restore the pre-update data too ([§3](#3--rollback-plan)).

Once you've confirmed everything works, you can reclaim the old image (**skip this if you
might still roll back** — pruning removes the untagged old image):

```bash
ssh root@$IP 'docker image prune -f'
```

---

## 3 — Rollback plan

An update changes **two independent things**, and a correct rollback reverses **both, in
order**:

| What changed | Reversed by | Notes |
|---|---|---|
| The **binary** (container image) | Re-pin to the old digest + recreate | `restore.sh` does **not** do this |
| The **data** (budget file format) | `restore.sh` | Only needed if the new version migrated the file |

`restore.sh` runs `docker compose stop` then `start` (lines 52–53, 71–72) — it restarts the
**existing container**, keeping whatever image it currently has. By rollback time that
container is already on the **new** image, so restoring data alone would run the new (broken)
binary against old data. And because Actual migrates the file format forward on load, a new
binary would just re-migrate restored old data. **So roll the image back first, then the
data.**

### 3a — Roll the binary back to the recorded digest

```bash
ssh root@$IP
cd /opt/household-os/actual

# Pin actual-server to the digest you recorded in step 1b.
# Edit docker-compose.yml: change
#     image: actualbudget/actual-server:latest
# to
#     image: actualbudget/actual-server@sha256:abc123...   # your recorded digest
nano docker-compose.yml

docker compose up -d actual-server    # recreates the container on the old image
docker compose ps                     # confirm Up (healthy)
```

If the digest wasn't recorded and the old image was already pruned, pull the specific old
version by tag instead (find the previous version in the
[release list](https://github.com/actualbudget/actual/releases)):

```bash
# e.g. previous release was v26.6.0
docker pull actualbudget/actual-server:v26.6.0
# then set image: actualbudget/actual-server:v26.6.0 in docker-compose.yml and `up -d`.
```

### 3b — Roll the data back (only if the new version migrated it)

If the budget file was migrated forward and the old binary now can't open it, restore the
pre-update data. `restore.sh` moves the current data aside as `actual.bak.<timestamp>` before
extracting, and prints an exact roll-forward command at the end:

```bash
./restore.sh                              # restores the most recent archive, or:
./restore.sh actual-20260704T030000Z.tar.gz   # the archive from step 1a

docker compose ps                         # confirm Up (healthy)
exit
```

Reload `https://budget.yourdomain.com` and confirm the budget opens on the old version.

> **If the update was fine and you only rolled back out of caution:** revert
> `docker-compose.yml` back to `image: actualbudget/actual-server:latest` (or your pinned
> tag) so the next update works normally.

---

## 4 — The MCP server caveat (read before you update)

The stack runs a **second** container, `actual-mcp`
(`ghcr.io/agigante80/actual-mcp-server`, see [`mcp-budget-server.md`](mcp-budget-server.md)).
Keep these facts in mind when updating Actual:

- **It is a separate release track.** An Actual Budget release does **not** update
  `actual-mcp`, and `docker compose pull actual-server` / `up -d actual-server` only touch
  Actual. That's deliberate — [§2](#2--update) updates *only* `actual-server` so the MCP
  container (which holds your Actual password) isn't changed as a side effect.
- **It depends on `@actual-app/api`, which is version-sensitive to the server.** The MCP
  server keeps its own synced copy of the budget via that library. It tolerates minor server
  drift, but a **major** Actual version jump can break the sync. **After a major update, the
  MCP server is the first place to check** — run `docker compose logs --tail=40 actual-mcp`
  and look for sync/download errors, then re-run the MCP smoke test
  ([`mcp-budget-server.md` §6](mcp-budget-server.md#6-smoke-test--guardrails)): "list my
  accounts and this month's balances."
- **If the MCP server breaks after an Actual update,** first roll Actual back
  ([§3](#3--rollback-plan)). If it still misbehaves, updating the MCP server itself may be
  required — that's its own procedure with its own auth re-verification, in
  [`mcp-budget-server.md` → Operations → Upgrades](mcp-budget-server.md#operations). Do
  **not** bump both at once; change one variable at a time so you know what broke.
- **The MCP container is already pinned** (to `:develop` per the ADR-0004 supply-chain note
  in `docker-compose.yml`), so it will not drift on its own during an Actual update.

---

## 5 — Recommended: pin a version tag instead of `:latest`

`:latest` makes updates implicit and rollbacks a scavenger hunt. Pinning `actual-server` to a
concrete version turns both into one-line, git-tracked changes:

```yaml
# infra/actual/docker-compose.yml
  actual-server:
    image: actualbudget/actual-server:v26.7.0   # was :latest
```

With a pinned tag:

- **Update** = bump the tag in `docker-compose.yml`, commit, `scp` it to the box (or edit in
  place), `docker compose up -d actual-server`. Deliberate and reviewable.
- **Rollback** = revert the tag, `up -d`. The old version is still pullable from Docker Hub,
  so you never depend on a leftover dangling image.

This is the same posture the MCP server already uses (it's pinned, not on `:latest`). If you
adopt it, the digest-recording step in [§1](#1--back-up-and-record-the-current-version)
becomes optional — the tag itself is the rollback handle.

---

## 6 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `actual-server` stuck "unhealthy" after update | Health check needs ~60s; or a bad image | Wait a minute and re-check `docker compose ps`. If still failing, `docker compose logs actual-server`; roll back per [§3](#3--rollback-plan). |
| Browser: blank white app / `SharedArrayBufferMissing` after update | COOP/COEP headers — not an update regression per se | See [`install-actual.md`](install-actual.md) Troubleshooting; confirm `crossOriginIsolated === true`. Don't set these headers in Caddy. |
| Budget won't open on the **old** version after rollback | New version already migrated the file format | You must also restore pre-update data — do [§3b](#3b--roll-the-data-back-only-if-the-new-version-migrated-it). |
| `actual-mcp` erroring / AI client returns stale or no data after update | `@actual-app/api` drift from a major server jump | `docker compose logs --tail=40 actual-mcp`; re-run the MCP smoke test. See [§4](#4--the-mcp-server-caveat-read-before-you-update). |
| Old image already gone, need to roll back | `docker image prune` ran, `:latest` untagged the old build | Pull the previous version by tag: `docker pull actualbudget/actual-server:vXX.Y.Z` ([§3a](#3a--roll-the-binary-back-to-the-recorded-digest)). |
| No `budget.yourdomain.com` load, Caddy 502 | `actual-server` didn't come back up | `docker compose ps`; `docker compose up -d actual-server`; check logs. |
