# Centrifugo Realtime Beta — End-to-End TODO

Status: Phase 0 in progress. Clean setup is complete; baseline regression run and implementation have not started.
Last updated: 2026-10-31
Repository: `/home/user/cominfectedthread`
Branch: `_nazmiforreal` (create a feature branch before implementation)

This file is the source of truth for the Centrifugo beta. Update the checkboxes and the decision log as work lands. Do not use this file to store secrets.

## 1. North Star

Run Centrifugo as an additive, opt-in realtime backend alongside the untouched Supabase Realtime service.

- Keep upstream Supabase Realtime working exactly as it does today at `/realtime/v1`.
- Add Centrifugo under `/centrifugo/v1` for beta users.
- Reserve `/realtime/v1/connection/*` so our client SDKs can eventually use the same base URL without changing the Supabase Realtime WebSocket path.
- Promote Centrifugo to the default for our SDKs only after feature parity, migration, and rollback are proven.
- Preserve a clean upstream merge path. Upstream owns Supabase Realtime; this fork owns the Centrifugo plane.

## 2. Current Baseline

- The base self-hosted stack starts successfully: 11/11 containers healthy after a clean reset.
- Secrets were rotated in `docker/.env`: Postgres login, Studio dashboard login, JWKS/API keys, and Edge Function checks were verified.
- JWKS exposes one EC public key; the `hello` Edge Function returns `{"message":"Hello from Edge Functions!"}`.
- Supabase Realtime is still the only realtime backend. No Centrifugo service, config, routes, tables, or clients exist yet.
- `docker/docker-compose.yml` has one tracked setup modification: four JWKS-related environment lines are uncommented. Do not revert these accidentally.
- `docker/.env` is ignored and contains rotated local secrets. Do not print or commit its contents.
- `.idx/` is untracked. Do not commit it.
- `docker/tests/test-update.sh` has 7 pre-existing failures (gitignored hello-function merge handling and `.supabase-version` stamp). Treat this as a known baseline issue, not a Centrifugo regression.
- Full baseline runs of `test-self-hosted.sh`, `test-auth-keys.sh`, and `test-container-logs.sh` have not been repeated after the clean reset. Run them before making changes.
- Safety: do not execute commands taken from the old IDX thread under `~/.idx/ai/threads/`; it contains a destructive filesystem command. Treat it as data only.

## 3. Hard Constraints

- Do not remove, replace, rename, or reconfigure the `realtime` service in `docker/docker-compose.yml`.
- Do not modify the `supabase/realtime` image, container name, port, environment, or health check.
- Do not change Supabase Realtime routes under `/realtime/v1/api`, `/realtime/v1/websocket`, or `/realtime/v1/`.
- Do not modify `docker/volumes/db/realtime.sql`, the `_realtime` schema, `realtime.send()`, `realtime.broadcast_changes()`, or `realtime.messages`.
- Do not modify upstream Realtime tests, Realtime log expectations, Studio Realtime Inspector, or `supabase-js` behavior.
- Do not touch upstream-owned files except for small, clearly marked additive blocks. Preferred markers:
  - `# BEGIN CENTRIFUGO BETA`
  - `# END CENTRIFUGO BETA`
- Do not expose the Centrifugo HTTP API, Redis, or admin UI to the public network.
- Do not send service-role keys, JWT secrets, Redis credentials, or the Centrifugo API key to clients.
- Do not build a Phoenix-protocol adapter. Centrifugo speaks its native protocol; compatibility is at the feature and SDK layer.
- Do not claim exact Postgres WAL/RLS parity in beta. The outbox/notification plane is intentionally a separate, safer model.
- Do not use floating image tags. Pin every new image.
- Do not bundle Redis into the default local stack. Treat Redis as a scale-out overlay.

## 4. Locked Decisions

| Area | Decision | Reason |
| --- | --- | --- |
| Runtime model | Centrifugo runs alongside Supabase Realtime | Keeps upstream Realtime untouched and allows rollback |
| Enablement | Opt-in `docker-compose.centrifugo.yml` overlay, enabled with `sh run.sh config add centrifugo` | Matches the existing compose override mechanism |
| Public beta paths | `/centrifugo/v1/connection/websocket`, `/centrifugo/v1/websocket`, `/centrifugo/v1/auth/token`, `/centrifugo/v1/health`, `/centrifugo/v1/api/*` | Clear versioned namespace and room for promotion |
| Legacy path reservation | `/realtime/v1/connection/*` reserved for Centrifugo; `/realtime/v1/websocket` stays Supabase Realtime | Allows same-base-URL SDK migration without a Phoenix adapter |
| Protocol | Native Centrifugo protocol; no Phoenix adapter | Avoid a fragile protocol bridge |
| Client strategy | Separate client SDKs per platform; official Centrifugo SDKs are the assumed transport | User selected separate SDKs; exact adapter boundary remains an open decision |
| Connection auth | Dedicated `centrifugo-auth` service validates Supabase JWTs/JWKS and issues short-lived Centrifugo connection tokens | Keeps Supabase auth authoritative and supports token refresh |
| Channel auth | Subscribe proxy plus a database-backed `centrifugo.authorize(...)` function; default deny | Server-side authorization is required; client-only checks are not acceptable |
| Anonymous access | Auth service accepts a valid publishable key and issues an anonymous token with empty `sub`; anonymous channel access is explicit | Mirrors the Supabase anon-key use case without leaking service credentials |
| Postgres changes | Separate `centrifugo` schema, outbox table, trigger helpers, and an outbox consumer | Avoids WAL CDC complexity and keeps `_realtime` untouched |
| Postgres change payload | Notification-only by default; full row payload only for explicitly reviewed tables | Prevents accidental cross-tenant row leakage under RLS |
| Scale-out | Redis Cluster/Sentinel and multiple Centrifugo nodes; no sticky sessions | Standard Centrifugo scale model |
| Gateway | Additive Envoy routes by default; mirror in Kong when the Kong override is active | Both supported self-hosted gateways must behave the same |
| Logging | Add a Vector route and a distinct Logflare source, e.g. `centrifugo.logs.prod` | Keeps Realtime log expectations unchanged |
| HTTP API | Internal-only by default; if exposed, require the Centrifugo API key and explicit opt-in | Server-to-server API must not become a public surface |
| Admin UI | Disabled by default; if enabled, internal-only | Avoid a new public admin surface |
| Studio | Existing Realtime Inspector stays on Supabase Realtime; Centrifugo Studio work is out of beta scope | Avoid upstream Studio coupling |

## 5. Open Decisions

Resolve these before the phase that depends on them.

1. SDK boundary (before Phase 8)
   - Option A: official Centrifugo SDKs only, with a documented native API.
   - Option B: official Centrifugo SDKs plus a thin Supabase-like adapter for `channel`, `broadcast`, `presence`, and `postgres_changes`.
   - Recommendation: Option B if behavioral parity is required; do not build a Phoenix wire adapter.
2. `centrifugo-auth` and outbox language (before Phase 3)
   - Recommendation: Go for both services, with small static binaries and a shared internal module.
   - Alternative: TypeScript/Node if the team prefers one runtime.
3. Centrifugo token signing (before Phase 3)
   - Recommendation: Ed25519 (Centrifugo verifies with a public key; private key stays in auth).
   - Fallback: HS256 with a strong shared secret and a documented rotation procedure.
4. Redis deployment (before Phase 6)
   - Recommendation: external Redis for production; no Redis in the default local overlay.
   - If bundled for local testing, pin the image and keep it behind a separate scale overlay.
5. Postgres change payload mode (before Phase 4)
   - Recommendation: notification-only by default. Full row payload is opt-in per table after a privacy review.
6. `/realtime/v1/connection/*` timing (before Phase 2)
   - Recommendation: add the route in beta behind the same overlay so early adopters can test the eventual URL. Keep `/realtime/v1/websocket` on Supabase.
7. Exact Centrifugo image tag (before Phase 1)
   - Candidate: a pinned Centrifugo v6.x patch release; verify the latest stable v6 tag at implementation time.
8. Studio Centrifugo inspector (before Phase 10)
   - Recommendation: out of scope for beta. Document Centrifugo admin/metrics instead.

## 6. Architecture

```text
Browser / mobile / server SDK
  |
  | wss /centrifugo/v1/connection/websocket        (beta)
  | wss /realtime/v1/connection/websocket           (reserved alias)
  | http /centrifugo/v1/auth/token                  (token exchange)
  v
Envoy api-gw :8000  (or Kong when the Kong override is active)
  |-- /realtime/v1/websocket, /realtime/v1/api/* --> Supabase Realtime :4000   (unchanged)
  |-- /centrifugo/v1/* ---------------------------> Centrifugo :8000
  |-- /centrifugo/v1/auth/token ------------------> centrifugo-auth :8090
  |-- /realtime/v1/connection/* ------------------> Centrifugo :8000           (reserved)
  v
Centrifugo
  |-- subscribe/publish proxy --------------------> centrifugo-auth :8090
  |                                                   |-- Supabase Auth JWKS
  |                                                   |-- centrifugo.authorize() in Postgres
  |-- HTTP API :8000/api (internal) <---------------- centrifugo-outbox
  |-- Redis (scale overlay only)
  v
Postgres
  |-- public tables
  |-- centrifugo.outbox
  |-- triggers / helpers
```

### 6.1 Path Contract

| Public path | Upstream target | Auth | Notes |
| --- | --- | --- | --- |
| `/realtime/v1/websocket` | Supabase Realtime `/socket/websocket` | Supabase apikey/JWT | Must remain unchanged |
| `/realtime/v1/api/*` | Supabase Realtime `/api/*` | Supabase apikey | Management paths stay blocked |
| `/realtime/v1/connection/websocket` | Centrifugo `/connection/websocket` | Centrifugo JWT | Reserved for SDK migration |
| `/centrifugo/v1/connection/websocket` | Centrifugo `/connection/websocket` | Centrifugo JWT | Primary beta WebSocket |
| `/centrifugo/v1/websocket` | Centrifugo `/connection/websocket` | Centrifugo JWT | Alias |
| `/centrifugo/v1/health` | Centrifugo `/health` | None | Health only |
| `/centrifugo/v1/auth/token` | `centrifugo-auth` `/auth/token` | Supabase JWT or publishable key | CORS enabled; no service key |
| `/centrifugo/v1/auth/subscribe` | Internal only | Centrifugo proxy | Do not expose publicly |
| `/centrifugo/v1/auth/publish` | Internal only | Centrifugo proxy | Do not expose publicly |
| `/centrifugo/v1/api/*` | Centrifugo `/api/*` | Centrifugo API key | Internal by default |

### 6.2 Connection Flow

1. Client obtains or refreshes a Supabase session.
2. Client calls `POST /centrifugo/v1/auth/token` with `apikey: <publishable key>` and, when signed in, `Authorization: Bearer <supabase access token>`.
3. `centrifugo-auth` validates the Supabase token:
   - Asymmetric tokens: verify against Supabase Auth JWKS.
   - Legacy HS256 tokens: verify against the configured legacy secret if supported.
   - Opaque publishable keys: constant-time compare against the configured publishable key.
   - Reject `service_role` and unknown roles for client connections.
4. Auth returns a short-lived Centrifugo connection JWT with `sub`, `exp`, `iat`, `aud`, `iss`, `info`, and `meta`.
5. Client connects to the Centrifugo WebSocket with the token.
6. On token expiry, the official Centrifugo SDK calls the supplied `getToken` callback, which calls the token endpoint again.
7. On subscribe, Centrifugo calls `centrifugo-auth /auth/subscribe`; auth parses the channel, checks the user/tenant, and calls the database authorization function. Default deny.
8. On client publish, Centrifugo calls `centrifugo-auth /auth/publish`; auth applies the same channel rules plus rate limits.

### 6.3 Postgres Change Flow

1. A reviewed table gets an opt-in trigger.
2. The trigger inserts a row into `centrifugo.outbox` and sends `pg_notify`.
3. `centrifugo-outbox` claims rows with `FOR UPDATE SKIP LOCKED`, preserving per-channel order where required.
4. The consumer publishes through the internal Centrifugo HTTP API.
5. Published rows are marked and cleaned up on a retention schedule.
6. Clients receive a change event. In notification-only mode the event contains identity and operation metadata, not the full row; clients refetch through the existing Supabase REST/GraphQL path so RLS remains authoritative.

## 7. Data Model and Channel Contract

### 7.1 Schema and Roles

- Create schema `centrifugo`.
- Create roles:
  - `centrifugo_auth`: login role with `USAGE` on `centrifugo` and `EXECUTE` on `centrifugo.authorize(...)`; no table access.
  - `centrifugo_outbox`: login role with `SELECT`/`UPDATE` on `centrifugo.outbox` and read-only access to dead-letter state; no DDL.
  - `centrifugo_migrator`: optional DDL role used only by the migration path.
- Revoke public access from every `centrifugo` object.
- Do not grant `centrifugo` objects to `anon` or `authenticated` through PostgREST.

### 7.2 Outbox Table

Proposed shape:

```sql
create table centrifugo.outbox (
  id bigint generated always as identity primary key,
  message_id uuid not null default gen_random_uuid(),
  channel text not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  attempts integer not null default 0,
  last_error text
);

create index on centrifugo.outbox (created_at) where published_at is null;
create index on centrifugo.outbox (channel, id);
```

Requirements:

- `channel` is validated against the allowed namespace and length limits.
- `payload` is JSON with a documented envelope and size cap.
- Claim with `FOR UPDATE SKIP LOCKED`, publish, then mark `published_at`.
- Retry transient failures with exponential backoff and a max attempt count.
- Move poison messages to `centrifugo.outbox_dead` or mark them with a terminal error.
- Delete published rows after the retention window; keep dead letters longer.
- Support a single-consumer mode for strict ordering and a partitioned mode for scale.

### 7.3 Change Envelope

Default notification-only event:

```json
{
  "id": "01J...",
  "source": "postgres_changes",
  "schema": "public",
  "table": "messages",
  "operation": "INSERT",
  "tenant_id": "tenant-uuid",
  "record_id": "row-primary-key",
  "commit_timestamp": "2026-10-31T00:00:00.000Z",
  "record": null,
  "old_record": null
}
```

Full-row mode may include `record` and `old_record` only for tables explicitly approved for that mode.

### 7.4 SQL Helpers

- `centrifugo.send(channel text, payload jsonb) returns bigint`
  - Validates the channel and payload, inserts into the outbox, and notifies the consumer.
- `centrifugo.broadcast_changes(...)`
  - Builds the change envelope and calls `centrifugo.send`.
- `centrifugo.broadcast_changes_trigger()`
  - Trigger function using `TG_OP`, `TG_TABLE_SCHEMA`, `TG_TABLE_NAME`, `NEW`, and `OLD`.
  - Reads the tenant key from a reviewed trigger argument, not from untrusted input.
- `centrifugo.authorize(channel text, claims jsonb) returns boolean`
  - `SECURITY DEFINER`, fixed `search_path`, default deny.
  - Encodes tenant/user/channel rules.
  - Never accepts raw SQL or dynamic identifiers from the client.

### 7.5 Channel Naming

| Pattern | Use |
| --- | --- |
| `tenant:<tenant_id>:table:<table>` | Change notifications for a tenant table |
| `tenant:<tenant_id>:table:<table>:row:<pk>` | Optional row-scoped channel |
| `user:<user_id>:...` | Private per-user events |
| `public:<name>` | Explicitly public broadcast channels |

Rules:

- Namespace is the prefix before the first `:` (`tenant`, `user`, `public`).
- Validate IDs and table names; never interpolate untrusted text into SQL identifiers.
- Keep channels under Centrifugo's 255-character limit.
- Do not put PII in channel names.
- Configure namespace-level history, presence, recovery, and anonymous access explicitly.

## 8. File Map

### 8.1 New Files

| Path | Purpose |
| --- | --- |
| `docker/docker-compose.centrifugo.yml` | Beta overlay: Centrifugo, auth, outbox, migration/config mounts |
| `docker/docker-compose.centrifugo-default.yml` | Promotion/rollback marker and default-client route set |
| `docker/volumes/centrifugo/config.json` | Centrifugo server config, non-secret defaults |
| `docker/volumes/centrifugo/auth/` | `centrifugo-auth` service source and Dockerfile |
| `docker/volumes/centrifugo/outbox/` | Outbox consumer source and Dockerfile |
| `docker/volumes/centrifugo/sql/centrifugo.sql` | Idempotent schema, roles, functions, triggers, grants |
| `docker/volumes/centrifugo/README.md` | Operator guide: enable, configure, operate, disable |
| `docker/volumes/centrifugo/CLIENT_MIGRATION.md` | SDK mapping and migration guide |
| `docker/volumes/centrifugo/COMPATIBILITY.md` | Feature matrix and known limitations |
| `docker/utils/generate-centrifugo-keys.sh` | Generate local Centrifugo secrets without printing them |
| `docker/.env.centrifugo.example` | Placeholder environment file |
| `docker/.env.centrifugo` | Local secrets, ignored by git |
| `docker/tests/test-centrifugo.sh` | End-to-end beta tests |

### 8.2 Existing Files

| Path | Change |
| --- | --- |
| `docker/docker-compose.yml` | Do not modify for Centrifugo. Preserve the existing JWKS setup edits. |
| `docker/volumes/api/envoy/cds.yaml` | Add a Centrifugo cluster in a marked block |
| `docker/volumes/api/envoy/lds.template.yaml` | Add Centrifugo routes in a marked block |
| `docker/volumes/api/kong.yml` | Mirror the routes for the Kong override |
| `docker/volumes/api/kong-entrypoint.sh` | Only if key translation or WebSocket handling needs a Centrifugo-specific branch |
| `docker/volumes/logs/vector.yml` | Add a Centrifugo router, parser, and sink |
| `docker/tests/test-self-hosted.sh` | Do not change existing Realtime expectations; add Centrifugo coverage separately |
| `docker/tests/test-auth-keys.sh` | Do not change existing Realtime expectations; add Centrifugo coverage separately |
| `docker/tests/test-container-logs.sh` | Do not change existing Realtime expectations; add Centrifugo coverage separately |
| `docker/.gitignore` | Add `.env.centrifugo` and backup variants |
| `docker/versions.md` | Add the pinned Centrifugo and Redis versions |
| `docker/CONFIG.md` | Add a short pointer to the Centrifugo guide, or leave untouched |

### 8.3 Upstream-Owned Files to Avoid

- `docker/volumes/db/realtime.sql`
- Realtime sections of `docker/docker-compose.yml`
- `apps/studio/components/interfaces/Realtime/Inspector/*`
- `apps/studio/data/realtime/*`
- `apps/studio/components/interfaces/Realtime/RealtimeSettings.tsx`
- `apps/studio/components/interfaces/Realtime/Policies.tsx`
- `e2e/studio/features/realtime-inspector.spec.ts`

## 9. Phases

### Phase 0 — Baseline and Guardrails

Description: Prove the current stack is healthy and record the upstream boundary before adding anything.

- [x] Perform a clean reset and rotate local secrets.
- [x] Verify 11/11 containers healthy, DB login, Studio 200, JWKS, and the `hello` function.
- [x] Map every Supabase Realtime touchpoint: compose, Envoy, Kong, Vector, DB init, tests, Studio, env scripts.
- [x] Record the architecture decision: dual stack, opt-in overlay, no Phoenix adapter.
- [ ] Run `docker/tests/test-self-hosted.sh` after the clean reset and record the baseline.
- [ ] Run `docker/tests/test-auth-keys.sh` after the clean reset and record the baseline.
- [ ] Run `docker/tests/test-container-logs.sh` after the clean reset and record the baseline.
- [ ] Record the known `test-update.sh` failures and confirm they are unchanged before/after Centrifugo work.
- [ ] Confirm the four JWKS lines in `docker/docker-compose.yml` are intentional and preserved.
- [ ] Create a feature branch from `_nazmiforreal`.
- [ ] Resolve Open Decisions 1-4 and 6-7.

Acceptance: Base stack passes the same tests it passed before; no Centrifugo changes exist yet.

### Phase 1 — Additive Service and Secrets

Description: Add Centrifugo as a standalone service with a pinned image, config, health check, and local secret generation. No gateway or database changes yet.

- [ ] Pin the Centrifugo image and record the version in `docker/versions.md`.
- [ ] Create `docker/volumes/centrifugo/config.json` with:
  - [ ] `http_server.port: 8000`.
  - [ ] `health.enabled: true`.
  - [ ] `prometheus.enabled: true` if supported by the pinned OSS build.
  - [ ] `client.allowed_origins` derived from `SUPABASE_PUBLIC_URL` plus localhost.
  - [ ] Token signing configuration (Ed25519 public key or HMAC secret).
  - [ ] `http_api.key` from the Centrifugo environment.
  - [ ] Namespace placeholders for `tenant`, `user`, and `public`.
  - [ ] Admin UI disabled by default.
- [ ] Create `docker/.env.centrifugo.example` with placeholders for:
  - [ ] Centrifugo HTTP API key.
  - [ ] Connection-token signing key/secret.
  - [ ] Admin credentials (only if the admin UI is enabled).
  - [ ] Auth database URL/password.
  - [ ] Outbox database URL/password.
  - [ ] Redis settings (commented out by default).
- [ ] Create `docker/utils/generate-centrifugo-keys.sh`:
  - [ ] Generate strong random values.
  - [ ] Write `.env.centrifugo` with restrictive permissions.
  - [ ] Do not echo secret values.
  - [ ] Support a `--force` or explicit overwrite guard.
- [ ] Add `.env.centrifugo` and backup variants to `docker/.gitignore`.
- [ ] Create `docker/docker-compose.centrifugo.yml`:
  - [ ] Centrifugo service named `centrifugo`, container `supabase-centrifugo`.
  - [ ] No public host port; internal `expose` only.
  - [ ] Read-only config mount.
  - [ ] `env_file: .env.centrifugo`.
  - [ ] Health check against `/health`.
  - [ ] `restart: unless-stopped`.
  - [ ] Depends only on what it truly needs; do not make it a dependency of upstream services.
- [ ] Verify the overlay works with Envoy and with the Kong override.
- [ ] Verify the base stack still starts with the overlay disabled and no Centrifugo env file.
- [ ] Verify `sh run.sh config add centrifugo` detects the overlay and `config remove` removes it.
- [ ] Document the enable/disable commands in the Centrifugo README.

Acceptance: With the overlay enabled, Centrifugo is healthy and reachable only inside the Compose network; with it disabled, the base stack is unchanged.

### Phase 2 — Gateway Contract

Description: Expose Centrifugo through Envoy and Kong without touching Supabase Realtime routes.

- [ ] Add a `centrifugo` cluster to `docker/volumes/api/envoy/cds.yaml`:
  - [ ] `STRICT_DNS` to `centrifugo:8000`.
  - [ ] HTTP health check on `/health`.
  - [ ] Circuit breakers matching the Realtime cluster.
- [ ] Add Envoy routes in a marked block:
  - [ ] `/centrifugo/v1/connection/websocket` to the Centrifugo cluster.
  - [ ] `/centrifugo/v1/websocket` alias rewrite to `/connection/websocket`.
  - [ ] `/centrifugo/v1/health` rewrite to `/health`.
  - [ ] `/centrifugo/v1/auth/token` to `centrifugo-auth:8090/auth/token`.
  - [ ] `/centrifugo/v1/api` rewrite to `/api`, internal-only by default.
  - [ ] `/realtime/v1/connection/` rewrite to `/connection/`, ordered before the existing `/realtime/v1/` route.
- [ ] Ensure `/realtime/v1/websocket` still goes to `realtime-dev.supabase-realtime:4000`.
- [ ] Ensure `/realtime/v1/api/tenants` and `/realtime/v1/api/openapi` remain blocked.
- [ ] Disable basic auth on the Centrifugo routes as appropriate; do not inherit Supabase gateway restrictions that break WebSocket upgrades.
- [ ] Configure CORS for the token endpoint.
- [ ] Mirror the routes in `docker/volumes/api/kong.yml`:
  - [ ] WebSocket service with `protocol: ws`.
  - [ ] Health service with `protocol: http`.
  - [ ] Auth token service with `protocol: http`.
  - [ ] API service with `protocol: http`, internal-only by default.
  - [ ] `/realtime/v1/connection/websocket` route ordered before the existing `/realtime/v1/` route.
- [ ] Verify WebSocket upgrade through Envoy and through Kong.
- [ ] Verify `/centrifugo/v1/websocket` and `/centrifugo/v1/connection/websocket` both reach Centrifugo.
- [ ] Verify `/realtime/v1/websocket` still reaches Supabase Realtime.
- [ ] Verify the HTTP API is not reachable without the Centrifugo API key.
- [ ] Add gateway tests to `docker/tests/test-centrifugo.sh`.

Acceptance: The full path table in section 6.1 behaves as documented; existing Realtime tests still pass.

### Phase 3 — Auth and Authorization

Description: Build `centrifugo-auth` as the only bridge between Supabase Auth, Centrifugo, and Postgres channel authorization.

- [ ] Implement the service skeleton and health endpoint.
- [ ] Implement Supabase JWT validation:
  - [ ] Fetch and cache Supabase Auth JWKS.
  - [ ] Verify signature, expiry, issuer, and audience.
  - [ ] Support legacy HS256 only if required; otherwise document the limitation.
  - [ ] Reject `service_role` and unknown roles for client connections.
- [ ] Implement token issuance:
  - [ ] Authenticated user: `sub` = Supabase user UUID.
  - [ ] Anonymous: `sub` = empty string, only with a valid publishable key.
  - [ ] Include short `exp`, `iat`, `aud`, `iss`, `info`, and `meta`.
  - [ ] Never include secrets or service-role claims.
- [ ] Implement `POST /auth/token`:
  - [ ] Accept `apikey` for publishable/legacy anon keys.
  - [ ] Accept `Authorization: Bearer` for user sessions.
  - [ ] Set CORS headers for allowed origins.
  - [ ] Rate-limit by IP and user.
- [ ] Implement token refresh behavior compatible with Centrifugo SDK `getToken`.
- [ ] Implement `POST /auth/subscribe`:
  - [ ] Parse and validate the channel.
  - [ ] Reject unknown namespaces and malformed IDs.
  - [ ] Check user/tenant ownership.
  - [ ] Call `centrifugo.authorize(channel, claims)`.
  - [ ] Default deny; return a clean Centrifugo error on denial.
- [ ] Implement `POST /auth/publish` for client broadcasts:
  - [ ] Apply the same channel checks.
  - [ ] Add payload size and rate limits.
  - [ ] Prefer server-side publish via the HTTP API for trusted services.
- [ ] Implement short-lived authorization caching:
  - [ ] Key by user, channel, and a claims/role version.
  - [ ] TTL measured in seconds, not minutes.
  - [ ] Clear or bypass on role changes.
- [ ] Implement key rotation for the connection-token signing material.
- [ ] Add unit tests for claims, expiry, anonymous access, cross-tenant denial, and malformed input.
- [ ] Add integration tests against the live auth service.
- [ ] Ensure logs never contain tokens, publishable keys, or full claims.

Acceptance: Valid users and anonymous clients connect; invalid, expired, cross-tenant, and service-role attempts are rejected; no auth secrets appear in logs.

### Phase 4 — Postgres Outbox and Change Notifications

Description: Add the separate change plane without touching `_realtime`.

- [ ] Create `docker/volumes/centrifugo/sql/centrifugo.sql`:
  - [ ] `CREATE SCHEMA IF NOT EXISTS centrifugo`.
  - [ ] Roles and grants.
  - [ ] Outbox and dead-letter tables.
  - [ ] `centrifugo.send`.
  - [ ] `centrifugo.broadcast_changes`.
  - [ ] `centrifugo.broadcast_changes_trigger`.
  - [ ] `centrifugo.authorize`.
  - [ ] Idempotent `CREATE OR REPLACE` statements.
- [ ] Ensure all functions use a fixed `search_path` and do not accept raw SQL.
- [ ] Create a migration path:
  - [ ] Idempotent SQL that can run on fresh and existing databases.
  - [ ] A migration service or `run.sh` subcommand that waits for Postgres.
  - [ ] Verify `docker compose up --wait` behavior for one-shot services; if it fails, run migrations from the auth/outbox entrypoint or an explicit command.
- [ ] Build `centrifugo-outbox`:
  - [ ] Connect with the least-privilege role.
  - [ ] `LISTEN` for low-latency wake-ups.
  - [ ] Poll as a fallback.
  - [ ] Claim rows with `FOR UPDATE SKIP LOCKED`.
  - [ ] Publish through the internal Centrifugo HTTP API.
  - [ ] Mark published rows and retry transient failures.
  - [ ] Move poison messages to dead-letter.
  - [ ] Clean up published rows on retention.
  - [ ] Expose metrics for lag, batch size, retries, and failures.
- [ ] Define ordering semantics:
  - [ ] Single-consumer mode for strict ordering.
  - [ ] Partitioned mode for scale; one worker per channel hash.
- [ ] Implement notification-only payloads by default.
- [ ] Implement full-row payloads only for an explicit allowlist of tables.
- [ ] Add a reviewed table opt-in example:
  - [ ] Trigger creation SQL.
  - [ ] Tenant key argument.
  - [ ] Channel naming.
  - [ ] RLS/privacy note.
- [ ] Add tests:
  - [ ] Insert/update/delete triggers create outbox rows.
  - [ ] Consumer publishes to Centrifugo.
  - [ ] Consumer restart does not lose rows.
  - [ ] Duplicate publish is safe for clients via `message_id`.
  - [ ] Poison messages land in dead-letter.
  - [ ] Notification-only mode contains no row data.
  - [ ] Cross-tenant payloads are never published to a tenant channel.

Acceptance: A reviewed table change reaches a subscribed client; no rows are lost or leaked; `_realtime` is untouched.

### Phase 5 — Channel Behavior and Feature Parity

Description: Define and test the behavior our SDKs expose.

- [ ] Configure namespaces:
  - [ ] `tenant` for tenant-scoped table changes.
  - [ ] `user` for private user channels.
  - [ ] `public` for explicitly public broadcast channels.
- [ ] Enable and test:
  - [ ] Subscribe/unsubscribe.
  - [ ] Broadcast from server and authorized client.
  - [ ] Presence (`track`, `untrack`, `presence`).
  - [ ] Join/leave events.
  - [ ] History and recovery.
  - [ ] Private channel authorization.
  - [ ] Anonymous access only where explicitly allowed.
  - [ ] Error mapping for denied subscription, invalid token, and rate limit.
- [ ] Document mapping from Supabase Realtime concepts:
  - [ ] `channel.subscribe()` -> Centrifugo subscription.
  - [ ] `channel.send()` -> publish proxy or server API.
  - [ ] `presence` -> Centrifugo presence.
  - [ ] `postgres_changes` -> outbox change events.
  - [ ] `private` -> subscribe proxy.
  - [ ] `system` events -> connection/error events.
  - [ ] `filters` -> client-side filtering in beta; no server-side filter parity.
- [ ] Write `COMPATIBILITY.md` with supported, partial, and unsupported features.
- [ ] Explicitly document the beta limitation: no WAL CDC and no exact Postgres RLS row filtering.
- [ ] Test multi-tenant isolation with two users and two tenants.

Acceptance: The compatibility matrix is accurate and covered by tests; no channel leaks data across tenants.

### Phase 6 — Scale and Resilience

Description: Make Centrifugo horizontally scalable without changing the public contract.

- [ ] Add a Redis scale overlay or environment profile.
- [ ] Configure Centrifugo engine/broker/presence manager for Redis.
- [ ] Pin the Redis image if bundled; prefer external Redis for production.
- [ ] Add Redis authentication and TLS options.
- [ ] Run at least two Centrifugo nodes behind Envoy/Kong.
- [ ] Verify no sticky sessions are required.
- [ ] Verify WebSocket connections survive a node restart via reconnect.
- [ ] Verify history/recovery across nodes.
- [ ] Verify subscribe proxy calls work from every node.
- [ ] Verify outbox consumers do not duplicate work.
- [ ] Test Redis failover and reconnect behavior.
- [ ] Run load tests:
  - [ ] Reconnect storm.
  - [ ] Fan-out to many subscribers.
  - [ ] Large channel count per user.
  - [ ] Outbox throughput.
- [ ] Record capacity limits and recommended node sizing.
- [ ] Document local vs production topology.

Acceptance: Losing one Centrifugo node does not lose data or permanently disconnect clients; load targets are documented and met.

### Phase 7 — Observability and Operations

Description: Make the beta operable without reading source code.

- [ ] Add Docker log routing:
  - [ ] `supabase-centrifugo` -> `centrifugo` route.
  - [ ] `supabase-centrifugo-auth` -> `centrifugo` route with a service field.
  - [ ] Parse JSON or text as appropriate.
  - [ ] Filter health-check noise.
  - [ ] Sink to a distinct Logflare source (`centrifugo.logs.prod`).
- [ ] Expose Prometheus metrics on an internal endpoint.
- [ ] Add health checks for Centrifugo, auth, and outbox.
- [ ] Add alerts/dashboards for:
  - [ ] Connection count.
  - [ ] Subscribe denials.
  - [ ] Auth latency and errors.
  - [ ] Token refresh failures.
  - [ ] Outbox lag and dead letters.
  - [ ] Redis errors.
  - [ ] Node restarts.
- [ ] Add an audit trail for authorization denials without logging tokens.
- [ ] Add a runbook:
  - [ ] WebSocket 401/403.
  - [ ] Auth service down.
  - [ ] Outbox lag.
  - [ ] Redis down.
  - [ ] Gateway route mismatch.
  - [ ] Secret rotation.
  - [ ] Rollback.
- [ ] Add log tests to `docker/tests/test-centrifugo.sh`.

Acceptance: An operator can diagnose the common failures from logs, metrics, and the runbook.

### Phase 8 — Client SDKs and Migration

Description: Provide client support on every target platform without a Phoenix adapter.

- [ ] Confirm the SDK boundary decision (Open Decision 1).
- [ ] Write a shared contract:
  - [ ] Connection states.
  - [ ] Channel lifecycle.
  - [ ] Broadcast, presence, and postgres-change event shapes.
  - [ ] Error codes.
  - [ ] Token refresh.
  - [ ] Reconnect and recovery.
- [ ] Build or adopt clients:
  - [ ] JavaScript/TypeScript.
  - [ ] Swift/iOS.
  - [ ] Kotlin/Android.
  - [ ] Flutter/Dart.
  - [ ] Python/Go/other as required.
- [ ] Use official Centrifugo SDKs as the transport.
- [ ] If a Supabase-like API is required, keep the adapter thin and platform-local; do not emulate the Phoenix wire protocol.
- [ ] Implement `getToken` against `/centrifugo/v1/auth/token`.
- [ ] Implement channel authorization errors with actionable messages.
- [ ] Implement reconnect, history recovery, and duplicate-event handling.
- [ ] Add example apps for at least JS and one mobile platform.
- [ ] Add cross-SDK conformance tests against the same server.
- [ ] Write `CLIENT_MIGRATION.md`:
  - [ ] Base URL changes.
  - [ ] Auth changes.
  - [ ] Event mapping.
  - [ ] Unsupported behavior.
  - [ ] Rollback to Supabase Realtime.
- [ ] Verify `/realtime/v1/connection/websocket` and `/centrifugo/v1/connection/websocket` both work with the clients.

Acceptance: At least JS/TS and one mobile client pass the shared conformance suite; migration and rollback are documented.

### Phase 9 — Test Suite and CI

Description: Make the beta safe to merge and maintain.

- [ ] Create `docker/tests/test-centrifugo.sh`:
  - [ ] Health endpoint.
  - [ ] WebSocket upgrade through Envoy.
  - [ ] WebSocket upgrade through Kong.
  - [ ] Valid user token connects.
  - [ ] Anonymous publishable key connects.
  - [ ] Missing/invalid token is rejected.
  - [ ] Expired token is rejected.
  - [ ] Cross-tenant subscribe is denied.
  - [ ] Allowed subscribe succeeds.
  - [ ] Broadcast publish succeeds.
  - [ ] Unauthorized publish is denied.
  - [ ] Outbox trigger -> consumer -> client delivery.
  - [ ] Notification-only payload contains no row data.
  - [ ] `/realtime/v1/websocket` still reaches Supabase Realtime.
  - [ ] `/realtime/v1/connection/websocket` reaches Centrifugo.
  - [ ] Centrifugo logs reach the expected source.
- [ ] Add unit tests for:
  - [ ] Secret generation (no secret output).
  - [ ] Token claims and expiry.
  - [ ] Subscribe channel parsing.
  - [ ] SQL helper validation.
  - [ ] Outbox retry/backoff.
- [ ] Add integration tests for auth + Centrifugo + Postgres + outbox.
- [ ] Add security tests:
  - [ ] Service-role token cannot connect as a client.
  - [ ] API key cannot be used as a client token.
  - [ ] Cross-tenant channel access is denied.
  - [ ] Outbox functions are not callable by `anon`/`authenticated`.
  - [ ] Secrets are not present in logs.
- [ ] Add load/soak tests or documented manual load-test procedures.
- [ ] Add a path-filtered CI workflow for Centrifugo files.
- [ ] Do not alter existing required CI checks.
- [ ] Ensure tests skip cleanly when the overlay is disabled.
- [ ] Ensure no test prints `.env` values.

Acceptance: The new suite passes locally and in CI; existing upstream suites still pass.

### Phase 10 — Documentation and Promotion

Description: Make enablement, migration, and rollback obvious.

- [ ] Write `docker/volumes/centrifugo/README.md`:
  - [ ] What the beta is and is not.
  - [ ] Enable/disable commands.
  - [ ] Required secrets and where they live.
  - [ ] Endpoint table.
  - [ ] Auth flow.
  - [ ] Outbox setup and table opt-in.
  - [ ] Redis scale-out.
  - [ ] Logs and metrics.
  - [ ] Troubleshooting.
  - [ ] Rollback.
- [ ] Write `CLIENT_MIGRATION.md` and `COMPATIBILITY.md`.
- [ ] Add the pinned versions to `docker/versions.md`.
- [ ] Add a short pointer from `docker/CONFIG.md` or the main self-hosting docs, or keep all Centrifugo docs isolated and link from the README.
- [ ] Add a promotion checklist:
  - [ ] Parity matrix is green.
  - [ ] JS/TS and mobile conformance pass.
  - [ ] Load targets pass.
  - [ ] Security review complete.
  - [ ] Rollback rehearsed.
- [ ] Add a rollback checklist:
  - [ ] Remove the default overlay.
  - [ ] Point clients back to Supabase Realtime.
  - [ ] Keep Centrifugo data for postmortem if needed.
  - [ ] Verify upstream Realtime still serves `/realtime/v1/websocket`.
- [ ] Decide whether `docker-compose.centrifugo-default.yml` only flips client/docs defaults or also adds the `/realtime/v1/connection` alias. Do not route legacy Phoenix traffic to Centrifugo.

Acceptance: A new operator can enable, operate, migrate, and roll back using only the docs.

### Phase 11 — Hardening and Beta Exit

Description: Close the gap between "works" and "safe to default".

- [ ] Run a threat model review.
- [ ] Run a security review of token issuance, subscribe authorization, outbox SQL, and gateway exposure.
- [ ] Run a privacy review of notification-only events and any full-row allowlist.
- [ ] Define SLOs for connection success, auth latency, delivery latency, and outbox lag.
- [ ] Define support boundaries and known limitations.
- [ ] Test upgrade from the pinned Centrifugo version to the next patch.
- [ ] Test backup/restore of config, secrets, SQL, and outbox state.
- [ ] Test secret rotation for the connection-token key and API key.
- [ ] Test disaster recovery with Redis loss and Postgres restart.
- [ ] Re-run all upstream and Centrifugo tests.
- [ ] Obtain sign-off from the owner of the fork and the upstream Realtime maintainers.
- [ ] Mark beta as complete only after the promotion checklist is green.

Acceptance: The beta exit checklist is complete; promotion and rollback are both proven.

## 10. Test Matrix

| Area | Test | Gate |
| --- | --- | --- |
| Base stack | `test-self-hosted.sh` unchanged | Required |
| Base auth | `test-auth-keys.sh` unchanged | Required |
| Base logs | `test-container-logs.sh` unchanged | Required |
| Gateway | `/realtime/v1/websocket` -> Supabase | Required |
| Gateway | `/realtime/v1/connection/websocket` -> Centrifugo | Required |
| Gateway | `/centrifugo/v1/*` paths | Required |
| Auth | Valid, invalid, expired, anonymous, service-role | Required |
| Auth | Cross-tenant subscribe denial | Required |
| DB | Trigger -> outbox -> consumer -> client | Required |
| DB | Notification-only payload has no row data | Required |
| DB | Consumer restart and poison message | Required |
| Feature | Broadcast, presence, history, private | Required |
| Scale | Node loss and reconnect storm | Required before default |
| Security | Secret leakage and API exposure | Required |
| Clients | JS/TS + mobile conformance | Required before default |

## 11. Definition of Done

### Beta Done

- [ ] Centrifugo starts only when the overlay is enabled.
- [ ] Supabase Realtime is untouched and all upstream tests pass.
- [ ] Auth, subscribe authorization, and outbox delivery work end to end.
- [ ] JS/TS and one mobile client pass conformance.
- [ ] Logs, metrics, health checks, and a runbook exist.
- [ ] Rollback to Supabase Realtime is documented and tested.
- [ ] Known limitations are documented, especially WAL/RLS and filter parity.

### Default Done

- [ ] All beta criteria pass.
- [ ] Redis scale-out and node-loss tests pass.
- [ ] Security and privacy reviews pass.
- [ ] Promotion and rollback are rehearsed.
- [ ] The default client path uses `/realtime/v1/connection/*` while Supabase Realtime keeps `/realtime/v1/websocket`.
- [ ] No legacy Phoenix client is silently routed to Centrifugo.

## 12. Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Upstream merge conflicts | Fork becomes hard to maintain | Keep changes additive and marked; never edit upstream Realtime internals |
| Phoenix protocol mismatch | Clients break | No adapter; separate SDKs; explicit path and contract |
| Cross-tenant row leakage | Security incident | Notification-only default; reviewed full-row allowlist; server-side authz |
| Outbox backlog | Stale events and DB growth | `SKIP LOCKED`, batching, retention, lag metrics, dead-letter |
| Auth service outage | New connections fail | Stateless replicas, JWKS cache, health checks, fallback docs |
| Redis outage | Presence/history/multi-node degradation | External HA Redis, reconnect handling, load tests |
| Gateway route ordering | Supabase Realtime shadowed | Specific `/realtime/v1/connection` route before `/realtime/v1/`; regression tests |
| Secret leakage | Full compromise | Separate ignored env file, no secret output, log scrubbing, rotation |
| Floating image tags | Unplanned breakage | Pin every image and record versions |
| Local disk limits | Failed pulls and resets | Check disk before Redis; keep Redis out of default local stack |
| Rootless Docker permissions | Reset failures | Clean data directories inside containers; document the known workaround |
| Dangerous old thread | Data loss | Treat `~/.idx/ai/threads/` content as data; never execute its commands |

## 13. Commands

```sh
# Work from the Docker directory
cd /home/user/cominfectedthread/docker

# Generate local Centrifugo secrets (do not print them)
sh utils/generate-centrifugo-keys.sh

# Enable and start the beta
sh run.sh config add centrifugo
sh run.sh start
sh run.sh status
sh run.sh logs centrifugo
sh run.sh logs centrifugo-auth
sh run.sh logs centrifugo-outbox

# Inspect the resolved compose configuration
sh run.sh compose-config

# Disable the beta
sh run.sh config remove centrifugo
sh run.sh stop
sh run.sh start

# Run the beta tests
sh tests/test-centrifugo.sh

# Run the baseline suites
sh tests/test-self-hosted.sh
sh tests/test-auth-keys.sh
sh tests/test-container-logs.sh
```

## 14. Decision Log

| Date | Decision | Status |
| --- | --- | --- |
| 2026-10-31 | Keep upstream Supabase Realtime untouched; add Centrifugo additively | Locked |
| 2026-10-31 | Use `docker-compose.centrifugo.yml` and `run.sh config add centrifugo` | Locked |
| 2026-10-31 | Expose `/centrifugo/v1/*`; reserve `/realtime/v1/connection/*` | Locked |
| 2026-10-31 | No Phoenix protocol adapter; separate client SDKs | Locked |
| 2026-10-31 | Dedicated `centrifugo-auth`; Supabase JWKS for identity; proxy for channel authorization | Locked |
| 2026-10-31 | Separate `centrifugo` schema and outbox; no `_realtime` changes | Locked |
| 2026-10-31 | Notification-only Postgres change payload by default | Locked |
| 2026-10-31 | Redis for scale-out, not in the default local stack | Locked |
| 2026-10-31 | Additive Envoy/Kong routes and a distinct Vector/Logflare source | Locked |
| 2026-10-31 | Existing Studio Realtime Inspector stays on Supabase Realtime | Locked |
| 2026-10-31 | Confirm official SDK vs thin Supabase-like adapter | Open |
| 2026-10-31 | Confirm `centrifugo-auth` language and token signing | Open |
| 2026-10-31 | Confirm exact Centrifugo image tag | Open |
