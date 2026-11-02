# Centrifugo Realtime Beta — End-to-End TODO

Status: Phase 1 is accepted on Envoy only. Phase 2 gateway routes are implemented and verified on Envoy; Kong is mirrored and config-validated in a disposable root container, but the actual Kong override remains blocked by a pre-existing image permission failure and is deferred. Phase 3 `centrifugo-auth` is implemented and verified end-to-end on Envoy (39/39 auth, 22/22 gateway); the Kong mirror passes the same 39/39 auth and 22/22 gateway suites in a disposable root container. Baseline suites pass (39/39 self-hosted, 56/56 auth keys, 13/13 container logs). Phase 4 Postgres outbox and the authoritative `centrifugo.authorize` migration have not started.
Last updated: 2026-11-01
Repository root: this checkout (use relative paths)
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
- On 2026-11-01 the `supabase_db-config` volume key became unreadable by the `postgres` user, causing a DB restart loop and cascading failures. Fixed by chowning `/etc/postgresql-custom/pgsodium_root.key` to `postgres:postgres`. If the DB logs `invalid secret key`, check that file's owner and mode before rebuilding the stack.
- Full baseline runs were repeated after the clean reset and after Phase 1: 39/39, 56/56, 13/13. `test-update.sh` remains 71 passed, 7 failed.
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
   - Phase 1 uses HS256 so the service can be stood up and verified before the auth service exists. Revisit Ed25519 in Phase 3.
4. Redis deployment (before Phase 6)
   - Recommendation: external Redis for production; no Redis in the default local overlay.
   - If bundled for local testing, pin the image and keep it behind a separate scale overlay.
5. Postgres change payload mode (before Phase 4)
   - Recommendation: notification-only by default. Full row payload is opt-in per table after a privacy review.
6. `/realtime/v1/connection/*` timing (before Phase 2)
   - Resolved in Phase 2: the route is in the beta overlay and points to Centrifugo. `/realtime/v1/websocket` remains on Supabase Realtime.
7. Exact Centrifugo image tag (before Phase 1)
   - Resolved: pinned `centrifugo/centrifugo:v6.10.2` and verified with the local stack.
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
- [x] Run `docker/tests/test-self-hosted.sh` after the clean reset and record the baseline. Result: 39/39.
- [x] Run `docker/tests/test-auth-keys.sh` after the clean reset and record the baseline. Result: 56/56.
- [x] Run `docker/tests/test-container-logs.sh` after the clean reset and record the baseline. Result: 13/13.
- [x] Record the known `test-update.sh` failures and confirm they are unchanged before/after Centrifugo work. Baseline: 71 passed, 7 failed (gitignored hello function and stamp advancement).
- [x] Confirm the four JWKS lines in `docker/docker-compose.yml` are intentional and preserved.
- [ ] Create a feature branch from `_nazmiforreal`.
- [ ] Resolve Open Decisions 1-4 and 6-7.

Acceptance: Base stack passes the same tests it passed before; no Centrifugo changes exist yet.

### Phase 1 — Additive Service and Secrets

Description: Add Centrifugo as a standalone service with a pinned image, config, health check, and local secret generation. No gateway or database changes yet.

- [x] Pin the Centrifugo image and record the version in `docker/versions.md`.
- [x] Create `docker/volumes/centrifugo/config.json` with:
  - [x] `http_server.port: 8000`.
  - [x] `health.enabled: true`.
  - [x] `prometheus.enabled: true` if supported by the pinned OSS build.
  - [x] Allowed origins derived from the deployment's existing `SITE_URL` and `SUPABASE_PUBLIC_URL` via `CENTRIFUGO_CLIENT_ALLOWED_ORIGINS`; `config.json` stays deployment-neutral with no hardcoded origins.
  - [x] Token signing configuration (Ed25519 public key or HMAC secret; Phase 1 uses HMAC until the auth service exists).
  - [x] `http_api.key` from the Centrifugo environment.
  - [x] Namespace placeholders for `tenant`, `user`, and `public`.
  - [x] Admin UI disabled by default.
- [x] Ensure no deployment-specific URLs, hosts, ports, credentials, or usernames are committed in the overlay, config, example env, or docs. Use existing deployment env vars or placeholders.
- [x] Create `docker/.env.centrifugo.example` with placeholders for:
  - [x] Centrifugo HTTP API key.
  - [x] Connection-token signing key/secret.
  - [x] Admin credentials (only if the admin UI is enabled).
  - [x] Auth database URL/password.
  - [x] Outbox database URL/password.
  - [x] Redis settings (commented out by default).
- [x] Create `docker/utils/generate-centrifugo-keys.sh`:
  - [x] Generate strong random values.
  - [x] Write `.env.centrifugo` with restrictive permissions.
  - [x] Do not echo secret values.
  - [x] Support a `--force` or explicit overwrite guard.
- [x] Add `.env.centrifugo` and backup variants to `docker/.gitignore`.
- [x] Create `docker/docker-compose.centrifugo.yml`:
  - [x] Centrifugo service named `centrifugo`, container `supabase-centrifugo`.
  - [x] No public host port; internal `expose` only.
  - [x] Read-only config mount.
  - [x] `env_file: .env.centrifugo`.
  - [x] Health check against `/health`.
  - [x] `restart: unless-stopped`.
  - [x] Depends only on what it truly needs; do not make it a dependency of upstream services.
- [x] Verify the overlay works with Envoy.
- [ ] Verify the overlay works with the Kong override. Deferred by user decision: this is a pre-existing Kong image permission issue, not caused by Centrifugo. `kong/kong:3.9.3` runs as UID 1001, while `/usr/local/kong` is root-owned, so the custom entrypoint cannot write its config or sockets. A temporary `user: "0:0"` override made the stack 12/12 healthy, but that fix was not applied. Kong is excluded from Phase 1 sign-off and tracked as a separate issue.
- [x] Verify the base stack still starts with the overlay disabled and no Centrifugo env file.
- [x] Verify `sh run.sh config add centrifugo` detects the overlay and `config remove` removes it.
- [x] Document the enable/disable commands in the Centrifugo README.

Acceptance: With the overlay enabled, Centrifugo is healthy and reachable only inside the Compose network; with it disabled, the base stack is unchanged.

Verification on 2026-10-31 and 2026-11-01:

- `checkconfig --strict` and `checktoken` passed.
- Envoy overlay: 12/12 containers healthy; internal health returned `{}`; no published port.
- The earlier Kong 12/12 result was not reproducible. The final repeated run fails because the custom entrypoint cannot write `/usr/local/kong` as UID 1001.
- Kong failure is independent of Centrifugo: the image runs as `kong` while `/usr/local/kong` is root-owned. With a temporary test-only `user: "0:0"` override, Kong startup returned 12/12 healthy and Centrifugo health stayed internal-only; this fix is not applied.
- Overlay disabled with `.env.centrifugo` absent: base 11/11 containers healthy; no `supabase-centrifugo` container.
- Internal `/api/publish` succeeded with `X-API-Key`; request without a key was rejected.
- Allowed WebSocket origin returned 101; a disallowed origin returned 403.
- Health and metrics returned 200; admin returned 404; config mount is read-only.
- Host `/centrifugo/v1/health` still returns the gateway basic-auth 401, not Centrifugo.
- Baseline suites re-ran after Phase 1: 39/39, 56/56, 13/13.
- Phase 1 is signed off on Envoy only by user decision on 2026-11-01. The Kong override is excluded and tracked as a separate pre-existing issue.
- Final stack after review: Envoy restored, 12/12 containers healthy, no Kong container, `COMPOSE_FILE=docker-compose.yml:docker-compose.centrifugo.yml`.
- Final Envoy/Centrifugo recheck: internal health `{}`, metrics non-empty, `X-API-Key` publish `{"result":{}}`, missing key `401`, host `/centrifugo/v1/health` `401`, no published port.
- Re-verified on 2026-11-01: generator strength/mode-600/no-echo/overwrite-guard/force-backup/atomic cleanup; base disabled stack 11/11 with no Centrifugo env file; restored overlay 12/12; Phase 0 DB login, Studio 200, JWKS EC key, `hello` function, and four JWKS lines; baseline suites 39/39, 56/56, 13/13; `test-update.sh` 71/7.

### Phase 2 — Gateway Contract

Description: Expose Centrifugo through Envoy and Kong without touching Supabase Realtime routes.

- [x] Add a `centrifugo` cluster to `docker/volumes/api/envoy/cds.yaml`:
  - [x] `STRICT_DNS` to `centrifugo:8000`.
  - [x] HTTP health check on `/health`.
  - [x] Circuit breakers matching the Realtime cluster.
- [x] Add Envoy routes in a marked block:
  - [x] `/centrifugo/v1/connection/websocket` to the Centrifugo cluster.
  - [x] `/centrifugo/v1/websocket` alias rewrite to `/connection/websocket`.
  - [x] `/centrifugo/v1/health` rewrite to `/health`.
  - [x] `/centrifugo/v1/auth/token` to `centrifugo-auth:8090/auth/token`.
  - [x] `/centrifugo/v1/api` rewrite to `/api`, internal-only by default.
  - [x] `/realtime/v1/connection/` rewrite to `/connection/`, ordered before the existing `/realtime/v1/` route.
- [x] Ensure `/realtime/v1/websocket` still goes to `realtime-dev.supabase-realtime:4000`.
- [x] Ensure `/realtime/v1/api/tenants` and `/realtime/v1/api/openapi` remain blocked.
- [x] Disable basic auth on the Centrifugo routes as appropriate; do not inherit Supabase gateway restrictions that break WebSocket upgrades.
- [x] Configure CORS for the token endpoint.
- [x] Mirror the routes in `docker/volumes/api/kong.yml`:
  - [x] WebSocket service with `protocol: ws`.
  - [x] Health service with `protocol: http`.
  - [x] Auth token service with `protocol: http`.
  - [x] API service with `protocol: http`, internal-only by default.
  - [x] `/realtime/v1/connection/websocket` route ordered before the existing `/realtime/v1/` route.
- [x] Verify WebSocket upgrade through Envoy and through Kong.
- [x] Verify `/centrifugo/v1/websocket` and `/centrifugo/v1/connection/websocket` both reach Centrifugo.
- [x] Verify `/realtime/v1/websocket` still reaches Supabase Realtime.
- [x] Verify the HTTP API is not reachable without the Centrifugo API key.
- [x] Add gateway tests to `docker/tests/test-centrifugo.sh`.


Verification (2026-11-01):

- Recreated only `api-gw`; Envoy accepted the new clusters/routes, the unresolved `centrifugo-auth` host did not block startup, and the stack remained 12/12 healthy.
- `docker/tests/test-centrifugo.sh` passed 22/22 against Envoy:
  - health 200 with `{}` and no dashboard basic auth;
  - primary, alias, and reserved `/realtime/v1/connection/websocket` upgrades returned 101 with `centrifuge-json`; a signed Centrifugo connect returned a client ID;
  - an unapproved WebSocket origin returned 403;
  - `/realtime/v1/websocket` still reached Supabase Realtime (Phoenix `phx_reply`);
  - `/realtime/v1/api/ping` stayed 200; `/api/tenants` and `/api/openapi` stayed 403;
  - API returned 401 without/with an invalid key and 200 with `X-API-Key`;
  - token CORS preflight returned 200; token endpoint returned 503 because `centrifugo-auth` is Phase 3.
- Kong `kong.yml` loaded in a disposable root container on `supabase_default`; the same gateway test passed 22/22 against its proxy port. No root workaround was applied to the real Kong override, and its pre-existing permission blocker remains.
- Kong CORS returns `*` for the token origin while Envoy echoes the request origin; the test accepts either. The Phase 3 auth service should enforce the final allowed-origin policy.
- Disabled the Centrifugo overlay and restarted the base stack: 11/11 healthy. Envoy started with the Centrifugo clusters unresolved; the Centrifugo and reserved alias paths returned 503, and `/realtime/v1/api/ping` remained 200. Restored the overlay to 12/12 healthy.
- Post-Phase 2 baselines: 39/39 self-hosted, 56/56 auth keys, 13/13 container logs.
- Node 22.23.4 was installed locally at `/home/user/.local/node-v22.23.4` and used for the test run. Prettier 3.8.0 check passed for the changed YAML and README; `TODO.md` is outside the repo Prettier glob and its existing tables would be reformatted.

Acceptance: The full path table in section 6.1 behaves as documented on Envoy; existing Realtime tests still pass. The Kong mirror is config-validated, but runtime acceptance of the real Kong override remains blocked by the pre-existing image permission issue.

### Phase 3 — Auth and Authorization

Description: Build `centrifugo-auth` as the only bridge between Supabase Auth, Centrifugo, and Postgres channel authorization.

- [x] Implement the service skeleton and health endpoint.
- [x] Implement Supabase JWT validation:
  - [x] Fetch and cache Supabase Auth JWKS.
  - [x] Verify signature, expiry, issuer, and audience.
  - [x] Support legacy HS256 only if required; otherwise document the limitation.
  - [x] Reject `service_role` and unknown roles for client connections.
- [x] Implement token issuance:
  - [x] Authenticated user: `sub` = Supabase user UUID.
  - [x] Anonymous: `sub` = empty string, only with a valid publishable key.
  - [x] Include short `exp`, `iat`, `aud`, `iss`, `info`, and `meta`.
  - [x] Never include secrets or service-role claims.
- [x] Implement `POST /auth/token`:
  - [x] Accept `apikey` for publishable/legacy anon keys.
  - [x] Accept `Authorization: Bearer` for user sessions.
  - [x] Set CORS headers for allowed origins.
  - [x] Rate-limit by IP and user.
- [x] Implement token refresh behavior compatible with Centrifugo SDK `getToken`.
- [x] Implement `POST /auth/subscribe`:
  - [x] Parse and validate the channel.
  - [x] Reject unknown namespaces and malformed IDs.
  - [x] Check user/tenant ownership.
  - [x] Call `centrifugo.authorize(channel, claims)`; the live function ships with the Phase 4 migration, so Phase 3 uses the documented local fallback until `CENTRIFUGO_AUTH_DATABASE_URL` is set.
  - [x] Default deny; return a clean Centrifugo error on denial.
- [x] Implement `POST /auth/publish` for client broadcasts:
  - [x] Apply the same channel checks.
  - [x] Add payload size and rate limits.
  - [x] Prefer server-side publish via the HTTP API for trusted services.
- [x] Implement short-lived authorization caching:
  - [x] Key by user, channel, and a claims/role version.
  - [x] TTL measured in seconds, not minutes.
  - [x] Clear or bypass on role changes.
- [x] Implement key rotation for the connection-token signing material.
- [x] Add unit tests for claims, expiry, anonymous access, cross-tenant denial, and malformed input.
- [x] Add integration tests against the live auth service.
- [x] Ensure logs never contain tokens, publishable keys, or full claims.

Verification (2026-11-01):

- `docker/volumes/centrifugo/auth/test/unit.test.js`: 12/12 passed (ES256/HS256 validation, expiry, audience, service-role and unknown-role rejection, channel parsing, default-deny authorization, DB fallback, token claims, JWKS cache/refresh, required JWKS URL, cache/rate limits, constant-time keys).
- `docker/tests/test-centrifugo-auth.sh`: 39/39 passed against Envoy:
  - legacy anon and publishable keys issue tokens; no key and invalid key return 401; service-role `apikey` and Bearer return 403; expired HS256 returns 401.
  - user session issues a token with the Supabase `sub`, `authenticated` role, and `app_metadata.tenant_id`; token refresh returns a new token.
  - allowed preflight returns 204 with the exact `SITE_URL` origin; a disallowed origin returns 403.
  - user connects; matching tenant and `user:<self>` subscribe; cross-tenant and other-user subscribe, malformed tenant ID, cross-tenant publish, oversized publish, and anonymous publish are denied with 403; authenticated `public` publish succeeds.
  - token IP and user rate limits return 429 after their configured windows; auth logs contain neither the session token nor the publishable key.
- `docker/tests/test-centrifugo.sh`: 22/22 passed against Envoy after the CORS changes; token preflight is now 204, the origin is exact, and token without `apikey` is 401.
- Kong: the disposable root container loaded `kong.yml` on `supabase_default`; the auth and gateway suites passed 39/39 and 22/22 against port 18000, including token CORS, rate limits, oversized publish rejection, and channel authorization. No root workaround was applied to the real Kong override.
- The test scripts derive the gateway from `API_EXTERNAL_URL` or `SUPABASE_PUBLIC_URL`, the allowed CORS origin from `SITE_URL`, and the disallowed CORS origin from `SITE_URL` with a non-production host; they do not hardcode an environment URL. An explicit base URL argument still overrides the gateway.
- Compose healthchecks contain no URL literal: the auth probe uses Node `http.get` host/port/path options and Centrifugo uses `nc -z` against its internal port.
- CORS is handled by `centrifugo-auth`; the Envoy token route disables the virtual-host CORS filter, and the Kong `cors` plugin is removed. `service_role` and unknown roles are rejected before token signing. `SUPABASE_JWKS_URL` has no default and must be supplied explicitly; the unit suite covers the missing-value failure and JWKS cache refresh.
- Key rotation was verified live: a disposable Centrifugo v6.10.2 accepted a connection token signed with the previous HMAC secret while the current secret remained active, and `checkconfig` accepted the rotation environment. Current tokens use HS256 until Ed25519 is revisited.
- The local `API_EXTERNAL_URL` already includes `/auth/v1`; the auth config no longer appends a second `/auth/v1`, and the compose issuer list was cleaned to `${API_EXTERNAL_URL} supabase`.
- Final re-run after the last auth image rebuild (2026-11-01): unit 12/12; Envoy auth 39/39 and gateway 22/22; disposable Kong auth 39/39 and gateway 22/22; key rotation accepted the previous-secret token. Baselines: 39/39 self-hosted, 56/56 auth keys, 13/13 container logs. `test-update.sh` remains 71 passed, 7 pre-existing failures.
- Node 22.23.4 (local install) and `supabase/centrifugo-auth:0.1.0` are recorded in `docker/versions.md`; the image runs as `node`, read-only, with no published port.

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
# Work from the Docker directory (from the repository root)
cd docker

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
| 2026-10-31 | Confirm `centrifugo-auth` language and token signing | Resolved: Node.js 22.23.4 ESM, HMAC-SHA256 with previous-key rotation; Ed25519 deferred |
| 2026-10-31 | Pin `centrifugo/centrifugo:v6.10.2` | Resolved |
| 2026-11-01 | Enforce final CORS policy in `centrifugo-auth`; disable per-route Envoy CORS and remove Kong `cors` | Locked |
| 2026-11-01 | Phase 3 uses a local default-deny fallback until the Phase 4 `centrifugo.authorize` migration is applied | Locked |
| 2026-11-01 | Rotate connection-token keys through Centrifugo previous-secret env vars; keep Ed25519 as a future option | Locked |
