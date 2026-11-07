# Centrifugo Beta Hardening Review

This document records the Phase 11 threat model, security and privacy reviews, service-level objectives, support boundaries, and verification evidence for the Centrifugo beta. It covers the local Compose reference and the documented production topology; it does not certify an upstream Supabase Realtime deployment.

Review date: 2026-11-06. Reviewed version: `centrifugo/centrifugo:v6.10.2`, `supabase/centrifugo-auth:0.1.0`, and `supabase/centrifugo-outbox:0.1.0`.

## Review Status

| Item | Status | Evidence |
| --- | --- | --- |
| Threat model | Complete | This document |
| Security review | Complete | This document; no critical or high findings; automated security and SQL tests |
| Privacy review | Complete | This document; notification-only and allowlist tests |
| SLOs | Defined | This document; alerts in [OPERATIONS.md](OPERATIONS.md) |
| Support boundaries | Defined | This document; [COMPATIBILITY.md](COMPATIBILITY.md) |
| Upgrade to next patch | Blocked | `v6.10.2` is the latest Centrifugo release as of the review date |
| Backup and restore | Verified | Schema dump restored with 6 functions, 3 tables, and the test outbox row; env backups mode `600` |
| Secret rotation | Verified | 12 checks passed for token overlap/removal and API key rotation; outbox test passed on the new key |
| Redis loss recovery | Verified | `tests/test-centrifugo-scale.sh` and `tests/test-centrifugo-scale-ha.sh` |
| Postgres restart recovery | Verified | Auth 48/48, SQL 50/50, outbox 11/11 after restart |
| Full regression suite | Verified | Two consecutive base+scale runs and two consecutive HA runs passed; see [Verification record](#verification-record) |
| Rollback rehearsal | Verified locally | Overlays removed; upstream Realtime routes remained reachable; Centrifugo routes returned `503` while absent |
| External sign-off | Pending | Fork owner and upstream Realtime maintainers |

The beta is not complete until the external sign-off is recorded and every promotion gate in [OPERATIONS.md](OPERATIONS.md) is green. The upgrade gate remains blocked until a newer patch is available; do not change the pinned image without repeating the upgrade checks.

## Threat Model

### Assets

- Supabase user access tokens, anonymous/publishable keys, and Centrifugo connection tokens.
- The connection-token HMAC secret, Centrifugo HTTP API key, database passwords, and Redis credentials.
- Tenant identifiers, change-notification metadata, and any full-row payloads explicitly allowlisted by an operator.
- Outbox and dead-letter rows, which may retain event payloads after delivery.
- Availability of the WebSocket, token, authorization, and change-delivery paths.

### Actors and Trust Boundaries

| Actor | Trust | Capability |
| --- | --- | --- |
| Anonymous internet client | Untrusted | Can reach the gateway routes and request anonymous tokens. |
| Authenticated tenant user | Untrusted for authorization | Holds a valid Supabase session and can attempt channel operations. |
| Cross-tenant attacker | Untrusted | Attempts to forge tenant claims, guess channels, or replay tokens. |
| Compromised client | Untrusted | Can send malformed commands, oversized payloads, and reconnect floods. |
| Compromised internal container | Conditionally trusted | Can reach internal service ports and Redis on the Compose network. |
| Operator or migration role | Trusted | Can change configuration, secrets, allowlists, and database objects. |
| Upstream Supabase services | Trusted for identity | Issue JWTs, host JWKS, and run the base gateway. |

Trust boundaries:

1. Client to Envoy: TLS termination, CORS, and route selection.
2. Envoy to Centrifugo/auth: the gateway is the only supported public entry point.
3. Centrifugo to `centrifugo-auth`: proxy requests carry the connection identity and requested action.
4. `centrifugo-auth` and `centrifugo-outbox` to Postgres: least-privilege roles and fixed-search-path functions.
5. `centrifugo-outbox` to Centrifugo: internal HTTP API authenticated with the API key.
6. Centrifugo nodes to Redis: internal broker, presence, and history traffic.
7. Containers to Logflare: metadata and denial reasons only; no tokens or full claims.

### Threat Review

| Threat | Mitigation | Residual risk |
| --- | --- | --- |
| Forged or modified connection token | HMAC-SHA256 signing, short token TTL, issuer/audience/expiry checks, supported previous-key overlap. | Compromise of the HMAC secret allows token forgery until rotation completes. |
| Service-role or admin token used as a client | Service-role keys are rejected in `apikey`; unknown roles are rejected; connection tokens are minted by the auth service, not accepted from clients. | A leaked user token remains valid until expiry or key rotation. |
| Cross-tenant subscribe or publish | Tenant comes from server-controlled claims, not `user_metadata`; the database authorizer is authoritative; channels are parsed and validated before authorization. | A mis-issued tenant claim grants that tenant's access. |
| Unauthorized client publish | Publish proxy is the authorization path; payloads must be JSON objects; size and rate limits apply; direct static client publish is not enabled. | An application-level authorization bug can still allow an authorized user to publish to a channel they can read. |
| SQL injection through channel, table, or tenant values | Channel grammar and UUID validation, identifier regexes, parameterized queries, `SECURITY DEFINER` functions with `search_path = pg_catalog`. | The `postgres` migration role is trusted and retains platform-level privileges. |
| Outbox privilege escalation | Dedicated login roles, connection limits, schema/table/function revokes, no `INSERT` grant on the outbox to the worker, owner-run trigger. | Database password or role compromise bypasses these controls. |
| Replay or duplicate delivery | `message_id` idempotency in the outbox and API, stable message IDs, client-side duplicate suppression. | Delivery is at-least-once across retries and failover windows. |
| Secret exposure through logs or images | No tokens or API keys in request logs, generated env files mode `600`, no published service ports, health endpoints do not print secrets. | Docker environment inspection and host/backup access expose secrets to operators. |
| Gateway exposes an internal endpoint | Only WebSocket, health, API, auth, and the SDK alias are routed; auth proxy and metrics endpoints remain internal. | The API key is a bearer credential; anyone who can read it can publish. |
| Denial of service | Token, authorization, and publish rate limits; payload caps; database connection limits; Envoy health checks. | No L7 connection flood protection is provided by the beta; deploy a WAF or edge rate limit. |
| Supply-chain compromise | Pinned image tags, lockfiles, pinned Kotlin compiler and checksums, path-filtered CI. | Images are tag-pinned, not digest-pinned; upstream image compromise remains possible. |
| Privacy leakage through change events | Notification-only payload is the default; full rows require an explicit reviewed allowlist. | Full-row events bypass table RLS and every tenant-channel subscriber receives them. |

## Security Review

### Token Issuance

- `/auth/token` accepts a valid legacy anon or publishable key in `apikey`. It optionally verifies a Supabase access token from the `Authorization: Bearer` header against JWKS; legacy HS256 is accepted only when `SUPABASE_JWT_SECRET` is configured.
- Tokens are limited to 16 KiB, must carry `exp`, and are checked for issuer, audience, subject, and role. `service_role`, `supabase_admin`, and unknown roles are rejected.
- Tenant identity is taken only from `app_metadata.tenant_id` or a top-level `tenant_id` claim. `user_metadata` is never used for authorization.
- CORS is restricted to the configured site and public URLs. Responses are `no-store` and include `nosniff`.
- Token issuance and authorization are rate-limited per client IP and per user. The limits are in-process; the beta runs one auth service. A future multi-replica auth deployment needs a shared limiter.
- Previous connection-token keys can be accepted during a bounded overlap window. New tokens are always signed with the current key.

### Subscribe and Publish Authorization

- Channel authorization is default deny. `centrifugo.authorize(channel, claims)` is authoritative when `CENTRIFUGO_AUTH_DATABASE_URL` is set; the local fallback keeps the same tenant and namespace rules.
- The authorizer receives the action (`subscribe` or `publish`) and checks it explicitly. A subscribe decision cannot be reused for publish.
- `public:*` subscribe is open; `public:*` publish requires an authenticated user. `user:<uuid>` requires the matching subject. `tenant:<uuid>:...` requires a matching server-controlled tenant claim.
- Authorization decisions are cached briefly by action, user, channel, and cache version. Role or tenant changes can take up to the cache TTL to apply; bump `CENTRIFUGO_AUTHZ_CACHE_VERSION` to invalidate immediately.
- The static `allow_*_for_client` flags remain `false`; the subscribe and publish proxies are the supported authorization path. Do not enable direct static client publish as a shortcut.
- Client publish payloads must be JSON objects, are capped at 16 KiB, and are rate-limited. Trusted server broadcasts should use the internal HTTP API.

### Database and Outbox

- `centrifugo_auth` and `centrifugo_outbox` are dedicated `LOGIN NOINHERIT` roles with connection limits and `search_path = pg_catalog`.
- Public schema/table/function privileges are revoked. The auth role can execute `authorize` and `is_uuid`; the outbox role can read/update/delete the outbox and read/insert dead letters, but cannot insert new outbox rows.
- `centrifugo.send`, `centrifugo.broadcast_changes`, and `centrifugo.authorize` use fixed search paths and validate channel grammar, UUIDs, schema/table/column identifiers, event names, and JSON payload shape. They never accept SQL text.
- The change trigger runs as its owner, so table RLS does not filter the row that is copied into the outbox. This is why full-row payloads require an explicit privacy review and allowlist entry.
- The outbox claims rows with `FOR UPDATE SKIP LOCKED`, renews locks while publishing, uses bounded retries, retains published rows for a configured period, and moves permanent failures to `centrifugo.dead_letter`.
- Strict ordering is the default. Partitioned mode keeps per-partition ordering and allows multiple workers without duplicate claims. Dead-letter rows retain payloads and must be purged under the deployment's retention policy.
- The `postgres` migration role is trusted. It can execute the trigger function and manage the allowlist, but cannot execute `send` or `broadcast_changes` or write the outbox directly.

### Gateway and Exposure

- Envoy routes `/centrifugo/v1/connection/*`, `/centrifugo/v1/websocket`, `/centrifugo/v1/health`, `/centrifugo/v1/api/*`, `/centrifugo/v1/auth/token`, and `/realtime/v1/connection/*` to Centrifugo or auth.
- `/realtime/v1/websocket` and `/realtime/v1/api/*` remain on Supabase Realtime. `/centrifugo/v1/auth/subscribe`, `/centrifugo/v1/auth/publish`, and all `/metrics` endpoints are not routed publicly.
- The Centrifugo HTTP API requires the API key and stays internal. The admin UI is disabled. Redis has no published port.
- `/centrifugo/v1/health` is unauthenticated so load balancers can probe it. It returns only health state.
- The gateway does not add connection-level rate limiting. Production deployments must add edge rate limiting or a WAF for WebSocket and token floods.

### Secrets and Logging

- Generated secrets are 48–64 hex characters, written with mode `600`, and excluded from generator output. `.env.centrifugo*` and their backups are gitignored.
- Auth logs include route, status, action, decision, denial reason, channel, and user where available. Tokens, API keys, full claims, and passwords are not logged.
- Vector forwards Centrifugo, auth, and outbox logs to `centrifugo.logs.prod` when the logs overlay is enabled. Log delivery is not guaranteed during a Logflare or Vector outage.
- Backups of `.env.centrifugo`, database dumps, and dead-letter rows must be protected as secrets and tenant data respectively.

## Privacy Review

Notification-only events are the default for every reviewed table. The payload is exactly:

```json
{
  "event": "insert",
  "schema": "public",
  "table": "orders",
  "tenant_id": "00000000-0000-4000-8000-000000000000",
  "occurred_at": "2026-11-06T00:00:00Z"
}
```

The notification contains no row ID, column values, old row, or user identity. It does reveal that a change occurred, which table changed, and which tenant it belongs to. Every subscriber to `tenant:<tenant_id>:table:<table>` receives it, so opt in only when every member of that tenant may know the change occurred.

Full-row payloads add `record` and, for updates, `old_record`. They bypass table RLS because the trigger runs as its owner. Enabling a table in `centrifugo.full_payload_tables` requires a documented review that confirms every channel subscriber is allowed to receive every column. The beta ships with an empty allowlist.

Outbox rows are deleted after `CENTRIFUGO_OUTBOX_RETENTION_SECONDS`; dead-letter rows are retained until an operator purges them. Both contain the same payloads as the delivered event. Logs and metrics do not contain full payloads, but denial audit fields include channel and user identifiers.

## Service-Level Objectives

These are beta targets, not contractual SLAs. Measure them at the gateway and with a synthetic probe, not only from container health.

| Area | SLO | Measurement | Alert |
| --- | --- | --- | --- |
| Connection success | 99.5% of synthetic connect-and-subscribe attempts succeed over 30 days; 99% over any 5-minute window | Synthetic client through the gateway using the documented token flow | Page on five consecutive probe failures |
| Token availability | 99.9% of `/centrifugo/v1/auth/token` requests return a non-5xx response over 30 days | `centrifugo_auth_http_requests_total{path="/auth/token"}` | 5xx ratio above 1% for 5 minutes |
| Auth latency | p95 token and authorization HTTP latency below 250 ms; p99 below 1 s | `centrifugo_auth_http_request_duration_seconds` | Existing p95 > 250 ms alert |
| Authorization errors | Fewer than 0.1% of authorization decisions are `error` over 30 days | `centrifugo_auth_authorization_decisions_total{decision="error"}` | Existing error-rate alert |
| Delivery latency | p95 trigger-to-subscriber delivery below 2 s when the outbox is not backlogged; p99 below 5 s | Synthetic table trigger plus subscriber timestamp | Investigate when outbox lag is above target |
| Outbox lag | 99% of 1-minute samples have `centrifugo_outbox_lag_seconds <= 60`; no sample above 300 for 5 minutes | `centrifugo_outbox_lag_seconds` | Existing outbox lag alert |
| Outbox availability | `centrifugo_outbox_worker_up == 1` for 99.9% of samples | `centrifugo_outbox_worker_up` | Existing worker-down alert |

Error budgets follow directly from the targets. A 99.5% connection target allows about 3.6 hours of failed probes per 30 days; a 99.9% token target allows about 43 minutes. Use the budget to pause client rollout, not to suppress alerts.

The local stack does not include a synthetic probe or a 30-day metrics store. Run the synthetic probe from the deployment's monitoring system and scrape the internal metrics endpoints through the platform's private network.

## Support Boundaries

Supported in the beta:

- Official Centrifugo SDKs (JS/TS and the documented Kotlin client) against `/realtime/v1/connection/websocket` or `/centrifugo/v1/connection/websocket`.
- The `public`, `user`, and `tenant` namespaces, subscribe/publish proxies, presence, join/leave, history, and recovery described in [COMPATIBILITY.md](COMPATIBILITY.md).
- Notification-only change events from explicitly reviewed tables, plus full-row events after an allowlist privacy review.
- The local Compose topology, the optional scale overlay, and the optional local Redis HA reference.

Not supported:

- Phoenix protocol compatibility, WAL-level CDC, exact RLS row filtering, old-record replay, arbitrary per-client presence state, or durable history.
- Non-UUID user/tenant identifiers, channel names over 255 characters, `public` names over 128 characters, or client publish payloads over 16 KiB.
- Production Redis, Sentinel, or HAProxy deployment from the bundled local services. Use external Redis with authentication, TLS, persistence, and a supported failover mechanism.
- Multi-region delivery, cross-region replication, an admin UI, or a 24/7 on-call commitment from the upstream Realtime team.
- Silent upgrades across minor Centrifugo versions. Test each patch against the pinned client and conformance suites.

Known limitations:

- Delivery is at-least-once. Clients must deduplicate by `message_id`.
- A Redis restart or failover can unset subscriptions and lose in-memory history. Clients must resubscribe and recover from history where available.
- A publish during a Redis promotion window can be lost. Treat that window as at-most-once.
- The local HA reference can require a client reconnect and resubscribe after a master change; a publish attempted during promotion may time out even though the topology recovers.
- Authorization cache TTL can delay role and tenant changes by a few seconds.
- Rate limits are per auth process and are not shared across replicas.
- The local stack has no production-like load, multi-region, or long-duration soak evidence.

## Verification Record

Run these checks from `docker/` with the Centrifugo overlay enabled. Do not print secret values in command output.

### Backup and Restore

The backup set is:

- `.env.centrifugo` and `.env.centrifugo-scale` (mode `600`, gitignored).
- `docker/volumes/centrifugo/config.json`.
- `docker/volumes/centrifugo/sql/centrifugo.sql`.
- A `pg_dump` of the `centrifugo` schema, including outbox, dead-letter, and allowlist state.

Restore procedure:

1. Stop the stack or put clients into maintenance mode so new outbox rows are not produced during the restore.
2. Restore the env files and configuration first, preserving mode `600`.
3. Restore the schema with `psql -v ON_ERROR_STOP=1` against the target database.
4. Re-run `docker/volumes/centrifugo/sql/centrifugo.sql` to confirm idempotency.
5. Run the SQL, outbox, and security tests before restarting traffic.
6. Confirm the outbox worker is up, the pending count is not growing unexpectedly, and no dead letters were introduced by the restore.

Verification result: verified on 2026-11-06. A suspended outbox row was included in the dump, restored into a temporary `centrifugo_restore_check` database, and found by `message_id`. The restored schema contained the three tables and all six public functions. The temporary database was dropped and the suspended row was removed from the live outbox. Env backups were written with mode `600`.

### Secret Rotation

Connection-token key rotation uses the previous-key overlap described in [README.md](README.md#token-rotation). Test it as follows:

1. Issue a connection token before rotation and keep it for the overlap check.
2. Set `CENTRIFUGO_CLIENT_TOKEN_HMAC_PREVIOUS_SECRET_KEY` to the old secret and a future `..._VALID_UNTIL`, then set the current secret to the new value.
3. Recreate `centrifugo-auth` and `centrifugo`, not just restart them, so both read the new environment.
4. Confirm the pre-rotation token still connects during the overlap, and a newly issued token also connects.
5. Remove the previous key after the overlap and recreate again. Confirm pre-rotation tokens are rejected and new tokens work.
6. Rotate the HTTP API key separately; restart the outbox worker and Centrifugo together, then confirm a server publish succeeds.

Verification result: verified on 2026-11-06. The check rotated the connection-token key with a 30-minute previous-key overlap and rotated the HTTP API key at the same time. The pre-rotation token connected during the overlap; after the previous key was removed it closed with code `3500`; the new token remained valid. The old API key returned `401` and the new key published successfully before and after overlap removal. The outbox suite passed with the rotated API key. The original `.env.centrifugo` was restored and the stack recreated; a restored token and the original API key both worked.

### Disaster Recovery

Redis loss: the scale suite restarts Redis with an existing subscriber, asserts the `2500` unsubscribe, resubscribes, and verifies cross-node delivery. The HA suite stops the master, verifies Sentinel promotion and proxy routing, then restores the original topology. Both suites must pass on the scale and HA overlays.

Postgres restart: restart `supabase-db`, wait for healthy, confirm `centrifugo-auth` and both outbox workers reconnect, verify token issuance, authorization, and outbox delivery, then run the auth, SQL, and outbox tests. The local `pgsodium_root.key` must be readable by the `postgres` user (`uid 100`, `gid 101`); a permission error prevents the database from starting after a host or volume restore.

Verification result: Redis loss was exercised on 2026-11-07. The scale suite restarted Redis with an existing subscriber, observed unsubscribe code `2500`, resubscribed, and verified cross-node delivery; two consecutive runs passed 33/33. The HA suite stopped the master, observed Sentinel promotion and proxy recovery, restored the original topology, and passed 19/19 in two consecutive runs. The HA reference exposed a stale `/tmp/dump.rdb` crash loop after promotion; both Redis services now remove the file before startup. An earlier HA run timed out during publish recovery, consistent with the documented at-most-once promotion window, and an earlier scale run timed out at Redis restart before passing twice on rerun.

Postgres restart was verified on 2026-11-06: `supabase-db` returned to healthy, `centrifugo-auth`, both Centrifugo nodes, and both outbox workers reconnected, and the auth (48/48), SQL (50/50), and outbox (11/11) suites passed immediately afterward. The restart also exposed a local-only pgsodium key permission issue; the key volume was corrected to owner `100:101`, and subsequent restarts succeeded.

### Rollback

Rehearse the [rollback checklist](OPERATIONS.md#rollback-checklist) on a non-production deployment:

1. Point test clients back to Supabase Realtime.
2. Stop writing new feature traffic to Centrifugo channels.
3. Stop the stack and remove the Centrifugo, scale, and HA overlays.
4. Restart the base stack and keep the `centrifugo` schema, outbox, dead-letter, and allowlist data.
5. Verify `/realtime/v1/websocket` and `/realtime/v1/api/*` still reach Supabase Realtime.

Verification result: verified on 2026-11-07 on the local reference. With the overlays removed, `/realtime/v1/websocket` and `/realtime/v1/api/*` returned `401`, which confirms the requests reached Supabase Realtime without an API key. The Centrifugo data remained intact. Centrifugo paths returned `503` because the additive Envoy routes remain while the service is absent; move clients back before disabling the overlay. The beta stack was restored to base, Centrifugo, and scale after the rehearsal.

### Upgrade

As of 2026-11-06, `centrifugo/centrifugo:v6.10.2` is the latest release. There is no next patch to test. When one is available:

1. Pin the new image in the base and scale overlays.
2. Recreate one Centrifugo node, verify token issuance, connect, subscribe, publish, presence, history, and recovery.
3. Run the client conformance, feature, outbox, auth, SQL, and security suites.
4. Confirm the config keys and metrics used by the alerts still exist.
5. Roll back to `v6.10.2` if any gate fails.

Verification result: blocked until a newer patch is released.

### Regression Suite

Run the full suite twice before sign-off:

```sh
sh tests/test-centrifugo.sh
sh tests/test-centrifugo-auth.sh
sh tests/test-centrifugo-security.sh
sh tests/test-centrifugo-sql.sh
sh tests/test-centrifugo-features.sh
sh tests/test-centrifugo-clients.sh
sh tests/test-centrifugo-outbox.sh
sh tests/test-centrifugo-scale.sh
sh tests/test-centrifugo-load.sh
sh tests/test-centrifugo-scale-ha.sh
sh tests/test-centrifugo-secrets.sh
sh tests/test-centrifugo-logs.sh
```

Record the pass counts for both runs. Scale, load, and HA are required before promotion even though they are manual.

Verification result: verified on 2026-11-07. Two consecutive full runs with the base, Centrifugo, and scale overlays passed: gateway 30/30, auth 48/48, security 21/21, SQL 50/50, features 41/41, clients 7/7, outbox 11/11, scale 33/33, load 10/10, secrets 19/19, and live log checks passed. The HA suite skipped as expected without the HA overlay. Two consecutive runs with the HA overlay passed 19/19 each.

## Sign-off

| Role | Name | Date | Decision |
| --- | --- | --- | --- |
| Fork owner | Pending | | |
| Upstream Realtime maintainers | Pending | | |
| Security reviewer | Pending | | |
| Beta operator | Pending | | |

Sign-off requires the regression suite to pass twice, the backup/restore and rotation records to be filled in, the Postgres restart check to pass, the upgrade gate to be either passed or explicitly waived until a patch exists, and every promotion gate in [OPERATIONS.md](OPERATIONS.md) to be green.
