# Runbook: updating the MCP Budget Server

**Stack:** `infra/actual/docker-compose.yml` on the Hetzner VPS at `/opt/household-os/actual`
**Data:** `/mnt/data/actual-mcp` (persistent volume — local synced budget copy)
**Verify:** `docker compose ps` shows `actual-mcp` as `Up`

This covers updating the **MCP Budget Server** (`ghcr.io/agigante80/actual-mcp-server`) container. It does **not** cover updates to the core Actual Budget server (see [`runbook-actual-updates.md`](runbook-actual-updates.md)) or OS security patches (see [`runbook-os-updates.md`](runbook-os-updates.md)).

---

## 0 — Before you start

The `actual-mcp` container holds critical credentials (your Actual Budget password and end-to-end encryption key) and has read/write access to your financial data. Do not treat updates casually.

1. **Review Release Notes:** Check the [agigante80/actual-mcp-server releases/commits](https://github.com/agigante80/actual-mcp-server) first for any breaking changes, authentication schema updates, or new required environment variables.
2. **Determine Target Tag:** Pin your image in `docker-compose.yml` to a specific version tag (e.g., `v0.7.11`) rather than leaving it on `develop` or `latest`. This ensures that updates are deliberate, reproducible, and tracked in git.

Set the server IP locally:

```bash
IP=$(cd infra/terraform && terraform output -raw server_ipv4)
```

---

## 1 — Backup and record current state

Because the MCP server has write permissions to Actual Budget, always perform a fresh backup of your actual budget server before updating, and record the current image tag or digest for rollback.

```bash
ssh root@$IP
cd /opt/household-os/actual

# 1a. Run fresh Actual Budget backup to R2
./backup.sh
# Confirm output ends with "Backup complete."

# 1b. Record current image tag and digest
docker compose images actual-mcp
# Copy the IMAGE / TAG / DIGEST, e.g.:
#   ghcr.io/agigante80/actual-mcp-server   develop   sha256:xyz123...
# Keep this info handy until the update is verified.
```

---

## 2 — Update process

Modify the image configuration on the server to point to the new version tag.

```bash
# Still in /opt/household-os/actual on the server.

# 2a. Update the image tag in docker-compose.yml
# Change:
#     image: ghcr.io/agigante80/actual-mcp-server:develop
# To:
#     image: ghcr.io/agigante80/actual-mcp-server:vX.Y.Z   # Target tag (e.g., v0.7.11)
nano docker-compose.yml

# 2b. Pull the new image
docker compose pull actual-mcp

# 2c. Recreate the actual-mcp container
docker compose up -d actual-mcp

# 2d. Check container status
docker compose ps
# Wait ~30s and ensure actual-mcp is "Up"

# 2e. Check logs for clean startup
docker compose logs --tail=50 actual-mcp
# Confirm there are no OIDC/JWKS initialization errors or Actual connection errors.
exit
```

---

## 3 — Verification (Smoke Tests)

Since the MCP server acts as an OIDC provider client and handles write-back requests, verify that authentication and basic tools work correctly after the bump.

### 3a. OIDC / Auth Check
Verify that your configured AI clients (Claude.ai web, Claude Desktop, or Claude Code) can still authenticate.
1. Open your AI client of choice.
2. Run a read command: `List my accounts and balances.`
3. If it returns the list of accounts with correct balances, OIDC validation is functioning.
4. If the client gets a 401/403 or fails to connect, check the VPS container logs:
   ```bash
   ssh root@$IP 'docker compose -f /opt/household-os/actual/docker-compose.yml logs --tail=40 actual-mcp'
   ```

### 3b. Read / Write Smoke Test
1. Ask the AI client to add a test transaction:
   * **Prompt:** `"Add a $1.00 transaction in my Cash account today with payee 'MCP Update Smoke Test' and category 'Uncategorized'."`
2. Open the Actual Budget web application in your browser (`https://budget.yourdomain.com`).
3. Verify that the transaction has appeared in the Cash account.
4. Ask the AI client to delete the test transaction:
   * **Prompt:** `"Delete the $1.00 transaction with payee 'MCP Update Smoke Test' that we just created."`
5. Verify in the web UI that the transaction has been removed.

---

## 4 — Rollback plan

If the updated MCP server crashes, fails to connect to Actual, or experiences OIDC validation failures, follow these steps to roll back.

### 4a. Restore the binary tag
```bash
ssh root@$IP
cd /opt/household-os/actual

# Revert image tag in docker-compose.yml back to the previous tag/digest
nano docker-compose.yml

# Recreate the container
docker compose up -d actual-mcp
```

### 4b. Clear synced cache (if needed)
If the new version of the MCP server modified the local database sync files in `/mnt/data/actual-mcp` in an incompatible way, clear the cached files to force a clean download from the Actual server:
```bash
docker compose stop actual-mcp
rm -rf /mnt/data/actual-mcp/*
docker compose start actual-mcp
docker compose logs -f actual-mcp  # watch it download and sync the budget
```

### 4c. Restore Actual Budget data (only if MCP wrote bad data)
If the MCP server successfully connected but wrote corrupted or incorrect transactions to Actual before it failed, restore the Actual Budget server data to the pre-update backup:
```bash
/opt/household-os/actual/restore.sh actual-<timestamp>.tar.gz   # Use the archive from step 1a
```

---

## 5 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| OIDC/JWT parse error / 401 Unauthorized | Google OIDC client configuration changed, or the updated MCP server handles claims differently | Verify OIDC client parameters in `mcp.env`. Check the MCP server log outputs for signature/audience mismatch info. |
| Sync loop / `@actual-app/api` crash | The new MCP server's internal API library is incompatible with the running Actual Budget version | Roll back the MCP server. Consider upgrading the Actual Budget server first per [`runbook-actual-updates.md`](runbook-actual-updates.md), then retry the MCP upgrade. |
| Container status is "Exit 1" | Missing environment variables or syntax error in `mcp.env` | Run `docker compose logs actual-mcp` to locate startup errors. Check configuration parameters against `mcp.env.example`. |
| Client requests return stale or cached data | Local SQLite cache out of sync | Clear the SQLite cache on the host: stop `actual-mcp`, run `rm -rf /mnt/data/actual-mcp/*`, and start it again. |
