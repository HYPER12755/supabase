# Centrifugo Beta

Centrifugo runs as an additive, opt-in realtime backend alongside Supabase Realtime.

Phase 3 status: `centrifugo-auth` issues short-lived Centrifugo connection tokens, validates Supabase JWTs/JWKS, and runs subscribe/publish authorization through Centrifugo proxies. Envoy is the only supported gateway for this beta.

Phase 4 status: `centrifugo-migrate` applies the idempotent Postgres schema, roles, outbox tables, and `centrifugo.authorize`; `centrifugo-outbox` publishes change events through the internal Centrifugo HTTP API. A reviewed table trigger emits notification-only events by default, and full-row payloads require an explicit allowlist entry.

Phase 5 status: the `tenant`, `user`, and `public` namespaces enable presence, opt-in join/leave events, history, and forced recovery, with subscribe/publish still authorized through the proxies and database. Anonymous access is limited to `public` subscriptions; presence and history are available to authenticated subscribers. The compatibility matrix and beta limitations are in [COMPATIBILITY.md](COMPATIBILITY.md).

Phase 6 status: `docker-compose.centrifugo-scale.yml` adds a second Centrifugo node, a second outbox consumer, and a local Redis reference service. Both nodes use Redis for the engine, broker, and presence manager, and Envoy routes to the shared `centrifugo` DNS alias without sticky sessions. The two outbox workers run partitioned mode and cover different channel partitions. Local load targets and sizing guidance are in [SCALING.md](SCALING.md); the local acceptance checks pass. An optional HA overlay adds a Redis replica, three Sentinels, and an HAProxy master-only endpoint; `tests/test-centrifugo-scale-ha.sh` exercises local promotion, client continuity, and recovery. The bundled Redis services are for local testing only; production should use external Redis with HA/failover, and external HA remains an operational validation.

Phase 7 status: Centrifugo, auth, and outbox logs route through Vector to the `centrifugo.logs.prod` source when the logs overlay is enabled. Centrifugo exposes its native Prometheus metrics, and `centrifugo-auth` exposes request, token, authorization, rate-limit, and process metrics. Authorization denials and rate limits include channel and user fields without tokens. Health checks remain internal. Alerts, dashboard queries, and failure procedures are in [OPERATIONS.md](OPERATIONS.md).

Phase 8 status: applications use the official Centrifugo SDKs directly; no separate client SDK is published. The shared client contract is in [CLIENT_CONTRACT.md](CLIENT_CONTRACT.md), the Supabase-to-Centrifugo mapping and rollback steps are in [CLIENT_MIGRATION.md](CLIENT_MIGRATION.md), and copy-paste JS and Kotlin integrations are in [examples/](examples/). `tests/test-centrifugo-clients.sh` runs the JS and Kotlin conformance checks against both `/realtime/v1/connection/websocket` and `/centrifugo/v1/connection/websocket`.

## Enable

From `docker/`:

```sh
sh utils/generate-centrifugo-keys.sh
sh run.sh config add centrifugo
sh run.sh start
sh run.sh status
```

The generated `docker/.env.centrifugo` contains the auth/outbox database passwords and URLs. It is ignored by git and must not be committed. `run.sh start` runs the Centrifugo migrations before bringing the stack up; use `sh run.sh migrate` to apply them explicitly.

Do not rely on `docker compose up -d --wait` for a one-shot migration service: Compose treats a successfully exited container as a failed wait. The migration service is behind the `centrifugo-migrate` profile, and `run.sh` runs it before `up --wait`.

## Disable

```sh
sh run.sh stop
sh run.sh config remove centrifugo
sh run.sh start
```

Stop before removing the overlay so Compose can remove the Centrifugo container. The base stack does not reference `.env.centrifugo`, so it starts normally with the overlay disabled.

## Scale out (optional)

From `docker/`, keep the base overlay enabled and add the scale overlay:

```sh
sh utils/generate-centrifugo-keys.sh --scale-only
sh run.sh config add centrifugo
sh run.sh config add centrifugo-scale
sh run.sh start
sh tests/test-centrifugo-scale.sh
```

`--scale-only` writes `docker/.env.centrifugo-scale` without rotating the existing database or token secrets. The scale file is loaded only by the scale overlay (and the optional HA overlay); the default overlay remains memory-only.

The local topology is:

- `supabase-centrifugo` and `supabase-centrifugo-2` are two Centrifugo nodes behind the `centrifugo` Compose network alias. Envoy resolves that alias, so no upstream configuration change or sticky session is required.
- `supabase-centrifugo-redis` is a single-node Redis reference service with password authentication. It has no published port, no persistence, and no high-availability guarantees. It is not a production Redis deployment.
- Both nodes share Redis for history and presence, so a client connected to one node can recover publications written through the other. A Centrifugo node restart does not lose Redis-backed history; a local Redis restart does. A Redis restart also sends existing subscribers `unsubscribe` code `2500` (`insufficient state`), so clients must resubscribe and use history recovery where delivery matters.
- `supabase-centrifugo-outbox` and `supabase-centrifugo-outbox-2` run as two partitioned consumers (`PARTITION_COUNT=2`, indexes 0 and 1). Each channel belongs to one partition, so rows are claimed once. Increase the partition count and worker count together for production throughput.
- The Centrifugo auth service remains shared. Redis is internal to the Compose network and must never be exposed publicly.

For production, use an external Redis deployment with authentication, TLS, persistence, and the deployment's failover policy. Set the engine, broker, and presence-manager addresses and credentials in `.env.centrifugo-scale`; use `rediss://` and the matching `*_REDIS_TLS_*` flags when TLS is required. Do not ship the bundled Redis service to production. See `.env.centrifugo-scale.example` for the full variable set.

The scale test checks cross-node join, presence, publish, history/recovery, subscribe-proxy calls on both nodes, gateway distribution, partitioned outbox ownership without duplicate publication, node restart/reconnect, and Redis restart/reconnect. The test keeps an existing subscriber connected across a Redis restart, asserts the `2500` unsubscribe, resubscribes, and verifies delivery; see [OPERATIONS.md](OPERATIONS.md).

### Redis HA reference (optional)

Add the HA overlay on top of the scale overlay:

```sh
sh run.sh config add centrifugo-scale-ha
sh run.sh start
sh tests/test-centrifugo-scale-ha.sh
```

The overlay keeps `supabase-centrifugo-redis` as the initial master, adds `supabase-centrifugo-redis-replica`, three Sentinels, and `supabase-centrifugo-redis-proxy` (HAProxy). Sentinel promotes the replica on master loss. HAProxy health-checks `ROLE` and routes Centrifugo only to the current master, so Centrifugo reconnects through a stable internal address instead of tracking Sentinel directly. When a backend is marked down, HAProxy closes its sessions so subscriptions cannot remain pinned to a demoted replica. This is a local reference: Redis is ephemeral, Sentinel has no authentication, and no Redis, Sentinel, or proxy port is published. For production, use a managed Redis HA endpoint or an equivalent master-only proxy with authentication and TLS.

A publish issued immediately after promotion can race Centrifugo's pub/sub reconnect and be missed by live subscribers. The HA test retries publication until a client receives it; applications should treat the small failover window as at-most-once and use history recovery where delivery matters.

## Verify

```sh
docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo
docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo-auth
docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo-outbox
docker exec supabase-auth wget -qO- http://centrifugo:8000/health
docker exec supabase-centrifugo-outbox node -e "fetch('http://127.0.0.1:9100/health').then(r=>r.text()).then(console.log)"
sh tests/test-centrifugo.sh
sh tests/test-centrifugo-auth.sh
sh tests/test-centrifugo-features.sh
sh tests/test-centrifugo-clients.sh
sh tests/test-centrifugo-outbox.sh
sh tests/test-centrifugo-scale.sh
sh tests/test-centrifugo-load.sh
sh tests/test-centrifugo-scale-ha.sh
sh tests/test-centrifugo-logs.sh
```

`docker port supabase-centrifugo`, `docker port supabase-centrifugo-auth`, `docker port supabase-centrifugo-outbox`, and `docker port supabase-centrifugo-redis-proxy` should print nothing. `test-centrifugo.sh` checks the gateway contract and internal health/metrics endpoints, including that `/realtime/v1/websocket` still reaches Supabase Realtime. `test-centrifugo-auth.sh` checks token issuance, CORS, user/anonymous access, service-role rejection, channel authorization through the live proxies, auth metrics, and audit fields. `test-centrifugo-features.sh` checks subscribe/unsubscribe, server and client broadcast, presence, join/leave, history/recovery, anonymous restrictions, private and tenant authorization, two-tenant isolation, and error mapping. `test-centrifugo-clients.sh` runs the JS client unit tests and the official JS and Kotlin SDKs against both client WebSocket routes, checking token exchange, presence, history, reconnect, recovery, and duplicate suppression. `test-centrifugo-outbox.sh` checks trigger capture, delivery, restart durability, allowlisted full payloads, duplicate message ids, dead-letter handling, and cross-tenant isolation. `test-centrifugo-scale.sh` requires the scale overlay and checks two-node routing, Redis-backed presence/history, gateway distribution, partitioned outbox ownership, and node/Redis restart recovery, including existing-subscriber resubscription after Redis restart. `test-centrifugo-load.sh` runs the local reconnect, fan-out, channel, and outbox throughput smoke tests described in [SCALING.md](SCALING.md). `test-centrifugo-scale-ha.sh` requires the HA overlay and checks Sentinel promotion, master-only proxy routing, client continuity, publish/presence/history recovery, and restoration of the original master. `test-centrifugo-logs.sh` validates the Vector configuration, routing, health filtering, JSON parsing, audit fields, and the Logflare source name.

## Endpoints

These paths are routed through the gateway:

- `/centrifugo/v1/connection/websocket` (primary WebSocket)
- `/centrifugo/v1/websocket` (alias)
- `/centrifugo/v1/health` (no dashboard basic auth)
- `/centrifugo/v1/api/*` (requires `X-API-Key`; no CORS)
- `/centrifugo/v1/auth/token` (CORS, apikey, optional bearer session)
- `/realtime/v1/connection/*` (reserved SDK alias to Centrifugo)

`/centrifugo/v1/auth/subscribe` and `/centrifugo/v1/auth/publish` are internal proxy endpoints on `centrifugo-auth:8090`; they are not routed publicly. Supabase Realtime keeps `/realtime/v1/websocket` and `/realtime/v1/api/*`.

## Auth behavior

- Anonymous token: a valid legacy anon or publishable key in `apikey`; the token has an empty `sub`, short expiry, and no service claims.
- User token: the same `apikey` plus `Authorization: Bearer <Supabase access token>`. JWTs are verified against Supabase Auth JWKS; legacy HS256 is accepted only when `SUPABASE_JWT_SECRET` is configured.
- Service-role and unknown roles are rejected. Service-role keys are rejected in `apikey`.
- Channel rules are default deny. Generated environments set `CENTRIFUGO_AUTH_DATABASE_URL`, so `centrifugo.authorize(channel, claims)` is authoritative. Without that URL, the service keeps a local default-deny fallback: `public:*` subscribe is open, public publish requires a user, `user:<uuid>` requires the matching user, and `tenant:<uuid>` requires a matching server-controlled `app_metadata.tenant_id` or top-level `tenant_id` claim. `user_metadata` is user-editable and is never trusted for tenant access.
- Authorization decisions are cached for a few seconds keyed by action, user, channel, and `CENTRIFUGO_AUTHZ_CACHE_VERSION`. Bump the version or wait for the TTL after a role change.
- Publish requests are size-limited and rate-limited. Prefer Centrifugo's internal HTTP API for trusted server-side broadcasts.
- Logs contain request metadata and denial reasons only; tokens, API keys, and full claims are never logged.

## Channel behavior

- All three namespaces enable presence, opt-in join/leave events, history, and forced recovery. Clients request join/leave with the subscription `join_leave` option; it is not forced namespace-wide.
- History keeps the latest 100 publications for 300 seconds. The default memory engine loses history on restart. With the scale overlay, history is stored in Redis and survives Centrifugo node restarts, but the bundled local Redis has no persistence and loses it on a Redis restart. Clients must treat history as a bounded cache and reload authoritative state when recovery reports failure.
- Authenticated subscribers may read presence and history. Anonymous clients may subscribe to `public:*` but cannot publish, read presence, or read history.
- Client publishes go through the publish proxy and accept JSON objects only. Server-side broadcasts should use the internal HTTP API.
- Namespaced private access uses `user:<uuid>`; tenant access uses `tenant:<uuid>:...`. Supabase's `private:` prefix is not translated automatically.
- See [COMPATIBILITY.md](COMPATIBILITY.md) for the full supported/partial/unsupported matrix and error mapping.

## Configuration

- `config.json` contains non-secret server defaults, channel proxies, and namespace configuration.
- `.env.centrifugo` contains local secrets and is loaded by the base overlay.
- `.env.centrifugo-scale` contains Redis addresses, credentials, and TLS flags and is loaded only by the scale overlay. See `.env.centrifugo-scale.example`.
- `CENTRIFUGO_CLIENT_ALLOWED_ORIGINS` is derived from the deployment's `SITE_URL` and `SUPABASE_PUBLIC_URL`; the auth service enforces the same origins for token CORS.
- The HTTP API requires the Centrifugo API key and must not be exposed to clients. Do not publish port 8000 or the API key.
- Internal HTTP API requests use the `X-API-Key` header; `Authorization: Bearer` is not accepted.
- The admin UI is disabled by default.
- `CENTRIFUGO_AUTH_DATABASE_URL` and `CENTRIFUGO_OUTBOX_DATABASE_URL` use the least-privilege `centrifugo_auth` and `centrifugo_outbox` roles. The migration uses the deployment's `POSTGRES_PASSWORD` and `supabase_admin` to create those roles; the application containers never receive admin credentials.
- The outbox worker has no published port. Its metrics and health endpoints are exposed only to the Compose network on port 9100.
- `centrifugo-auth` exposes Prometheus text at `/metrics` on port 8090. The endpoint is internal and must not be routed publicly.
- Centrifugo exposes native Prometheus metrics at `/metrics` on port 8000. The endpoint is internal and must not be routed publicly.

## Database schema and change plane

- `centrifugo.send(channel, payload, event, tenant_id, message_id, available_at)` validates channels and payloads and appends to `centrifugo.outbox`. Reusing `message_id` is idempotent.
- `centrifugo.broadcast_changes_trigger('tenant_id')` is an `AFTER INSERT OR UPDATE OR DELETE` row trigger. It derives the channel `tenant:<tenant_id>:table:<table_name>` and calls `centrifugo.send`.
- Notification-only payloads are the default: event, schema, table, tenant ID, timestamp, and `message_id`. Full rows require an entry in `centrifugo.full_payload_tables`; see `sql/reviewed-table-example.sql`.
- The outbox consumer claims rows with `FOR UPDATE SKIP LOCKED`, renews its lock while publishing, retries transient HTTP failures with exponential backoff, moves permanent or exhausted failures to `centrifugo.dead_letter`, and removes published rows after `CENTRIFUGO_OUTBOX_RETENTION_SECONDS`. Dead-letter rows retain their payloads for inspection; restrict access and purge them under the deployment's data-retention policy.
- Strict ordering is the default (`CENTRIFUGO_OUTBOX_ORDERING_MODE=strict`): one consumer processes rows in `id` order. If a transient failure is scheduled, the worker releases the rest of its claimed batch and waits; the delayed row also blocks later rows across polls until it succeeds or dead-letters. Partitioned mode (`partitioned`) runs one worker per `hashtext(channel) % partition_count` partition; the same per-partition ordering applies. The scale overlay switches both outbox containers to partitioned mode with two partitions.
- The worker wakes on `LISTEN centrifugo_outbox` notifications and polls as a fallback. The HTTP API request carries `idempotency_key=<message_id>` and the payload carries `message_id` for client-side deduplication.
- Metrics are exposed as Prometheus text at `/metrics` on port 9100: pending rows, lag, batch size, claims, publishes, retries, failures, dead letters, and cleanup deletions.
- Outbox tuning uses `CENTRIFUGO_OUTBOX_BATCH_SIZE`, `_POLL_INTERVAL_MS`, `_LOCK_TIMEOUT_SECONDS`, `_MAX_ATTEMPTS`, `_RETRY_BASE_SECONDS`, `_RETRY_MAX_SECONDS`, `_HTTP_TIMEOUT_MS`, `_RETENTION_SECONDS`, `_CLEANUP_INTERVAL_MS`, `_STATEMENT_TIMEOUT_MS`, `_PARTITION_COUNT`/`_PARTITION_INDEX`, `_WORKER_ID`, and `_METRICS_HOST`/`_METRICS_PORT`; defaults are in `outbox/src/config.js`.

## Reviewed table opt-in

1. Confirm that every member of the tenant channel may receive the event. Notification-only mode is the default.
2. Use a UUID tenant key column and create an `AFTER` trigger with `centrifugo.broadcast_changes_trigger('<tenant_column>')`; see `sql/reviewed-table-example.sql`.
3. For full-row payloads, insert the table into `centrifugo.full_payload_tables` only after a privacy review. The trigger runs as its owner, so table RLS does not filter the row that is placed in the outbox.
4. Apply the trigger through your normal migration process; the Centrifugo migration does not modify application tables. The migration grants the `postgres` role only `USAGE` on the schema, `EXECUTE` on the trigger function, and access to the full-payload allowlist. It cannot delete allowlist entries or insert outbox messages; an administrator removes allowlist entries. Supabase's `postgres` role can retain platform-level read-all membership, so treat it as a trusted migration role rather than assuming it cannot read tables. Other migration roles need equivalent grants, applied by an administrator.

## Migration

`sql/centrifugo.sql` is idempotent and safe to run on fresh and existing databases. It creates the `centrifugo` schema, the two login roles, outbox/dead-letter/allowlist tables, indexes, and the `send`, `broadcast_changes`, `broadcast_changes_trigger`, and `authorize` functions. All functions use a fixed `search_path` and do not accept SQL text.

The migration service uses `supabase_admin` only for this one command. It requires `CENTRIFUGO_AUTH_DB_PASSWORD` and `CENTRIFUGO_OUTBOX_DB_PASSWORD`, reads the SQL from a read-only mount, and does not expose a port. `sh run.sh start` runs the migration before `up --wait`; `sh run.sh migrate` runs it directly. The service is behind the `centrifugo-migrate` profile, so a plain `docker compose up` does not migrate.

## Token rotation

1. Set `CENTRIFUGO_CLIENT_TOKEN_HMAC_PREVIOUS_SECRET_KEY` to the current secret and `CENTRIFUGO_CLIENT_TOKEN_HMAC_PREVIOUS_SECRET_KEY_VALID_UNTIL` to a Unix timestamp at least one token TTL plus clock skew in the future.
2. Replace `CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY` with the new secret and restart `centrifugo-auth` and `centrifugo`.
3. After the expiry timestamp, clear both previous-secret variables and restart again.

Centrifugo accepts the previous key until the timestamp; new tokens are always signed with the current key.

## Notes

- The images are pinned to `centrifugo/centrifugo:v6.10.2`, `node:22.23.4-alpine` (auth/outbox build base), `redis:7.4.2-alpine` (local scale/HA reference only), and `haproxy:3.0.5-alpine` (local HA reference only).
- Phase 3 uses HMAC-SHA256 with the previous-key rotation above; Ed25519 remains a future option.
- `--force` keeps the previous generated files as `.env.centrifugo.old` and `.env.centrifugo-scale.old`; all generated files are ignored by git.
- Redis is not part of the default overlay. It is enabled only by the scale and HA overlays; production should use external Redis.
