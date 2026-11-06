# Centrifugo Realtime Beta — End-to-End TODO

Status: Phase 1 is accepted on Envoy only. Phase 2 gateway routes are implemented and verified on Envoy. Phase 3 `centrifugo-auth` is implemented and verified end-to-end on Envoy (48/48 auth, 30/30 gateway). Kong is intentionally out of scope: Envoy is the only supported gateway for this beta, consistent with Supabase's move to Envoy. Baseline suites pass (39/39 self-hosted, 56/56 auth keys, 13/13 container logs). Phase 4 is implemented and verified: idempotent migration and least-privilege roles, outbox consumer, notification-only default with a reviewed full-row allowlist, strict/partitioned ordering, and 11/11 integration tests plus 18/18 outbox unit tests. The change plane does not modify `_realtime`. Phase 5 is implemented and verified: namespace presence, opt-in join/leave, bounded history with recovery, authenticated presence/history, public-only anonymous subscribe, and proxy-authorized server/client broadcast; `test-centrifugo-features.sh` passes 41/41, including two-user/two-tenant isolation and error mapping. `COMPATIBILITY.md` records the supported, partial, and unsupported parity matrix, including the absence of WAL CDC, exact RLS row filtering, and server-side filter parity. Phase 6 is committed as `9f37c2fd`: scale/HA overlays, partitioned outbox consumers, load results, and the HAProxy session-drain fix pass 33/33 scale, 10/10 load, and 19/19 HA checks. Phase 7 is implemented: Vector routes Centrifugo/auth/outbox logs to `centrifugo.logs.prod`, auth exposes Prometheus metrics and audit fields, and [OPERATIONS.md](docker/volumes/centrifugo/OPERATIONS.md) documents alerts, dashboards, health checks, and failure procedures. Gateway checks pass 30/30, auth 48/48, auth unit 15/15, and Vector pipeline tests 4/4. The battle test on 2026-11-03 confirmed auth-outage socket continuity and single-worker outbox failover, found Envoy's ~15-second node-ejection window can return transient API 503s, and confirmed a Redis restart sends existing subscribers `unsubscribe` code 2500 so clients must resubscribe before delivery resumes. Post-battle suites still pass 30/30 gateway, 48/48 auth, 41/41 features, 11/11 outbox, and 33/33 scale.
Last updated: 2026-11-03
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
| Gateway | Additive Envoy routes only | Envoy is the only supported gateway for this beta; Kong is out of scope |
| Logging | Add a Vector route and a distinct Logflare source, e.g. `centrifugo.logs.prod` | Keeps Realtime log expectations unchanged |
| HTTP API | Internal-only by default; if exposed, require the Centrifugo API key and explicit opt-in | Server-to-server API must not become a public surface |
| Admin UI | Disabled by default; if enabled, internal-only | Avoid a new public admin surface |
| Studio | Existing Realtime Inspector stays on Supabase Realtime; Centrifugo Studio work is out of beta scope | Avoid upstream Studio coupling |

## 5. Open Decisions

Resolve these before the phase that depends on them.

1. SDK boundary (before Phase 8)
   - Resolved on 2026-11-03: Option A, official Centrifugo SDKs only with documented native APIs and copy-paste examples. No separate Supabase-like client SDK is published; no Phoenix wire adapter is built.
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
   - Resolved locally: `redis:7.4.2-alpine` behind `docker-compose.centrifugo-scale.yml`; production remains external.
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
Envoy api-gw :8000
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
| `docker/tests/test-centrifugo.sh` | End-to-end gateway and Realtime regression tests |
| `docker/tests/test-centrifugo-auth.sh` | Auth service and proxy integration tests |
| `docker/tests/test-centrifugo-features.sh` | Channel behavior, presence, history, and isolation tests |
| `docker/tests/test-centrifugo-outbox.sh` | Outbox and change-plane integration tests |

### 8.2 Existing Files

| Path | Change |
| --- | --- |
| `docker/docker-compose.yml` | Do not modify for Centrifugo. Preserve the existing JWKS setup edits. |
| `docker/volumes/api/envoy/cds.yaml` | Add a Centrifugo cluster in a marked block |
| `docker/volumes/api/envoy/lds.template.yaml` | Add Centrifugo routes in a marked block |
| `docker/volumes/api/kong.yml` | Out of scope; do not modify for Centrifugo |
| `docker/volumes/api/kong-entrypoint.sh` | Out of scope; do not modify for Centrifugo |
| `docker/volumes/logs/vector.yml` | Add a Centrifugo router, parser, and sink |
| `docker/volumes/logs/centrifugo-tests.yml` | Vector unit tests for routing, filtering, parsing, and audit fields |
| `docker/volumes/centrifugo/OPERATIONS.md` | Runbook, scrape config, alert rules, and dashboard queries |
| `docker/tests/test-centrifugo-logs.sh` | Validate the Vector config and run Centrifugo pipeline tests |
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
- [x] Map every Supabase Realtime touchpoint: compose, Envoy, Vector, DB init, tests, Studio, env scripts. Kong is out of scope for this beta.
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
- [x] Gateway support is Envoy-only; Kong verification is intentionally out of scope by user decision on 2026-11-03.
- [x] Verify the base stack still starts with the overlay disabled and no Centrifugo env file.
- [x] Verify `sh run.sh config add centrifugo` detects the overlay and `config remove` removes it.
- [x] Document the enable/disable commands in the Centrifugo README.

Acceptance: With the overlay enabled, Centrifugo is healthy and reachable only inside the Compose network; with it disabled, the base stack is unchanged.

Verification on 2026-10-31 and 2026-11-01:

- `checkconfig --strict` and `checktoken` passed.
- Envoy overlay: 12/12 containers healthy; internal health returned `{}`; no published port.
- Kong was intentionally excluded; Envoy is the only supported gateway for this beta.
- Overlay disabled with `.env.centrifugo` absent: base 11/11 containers healthy; no `supabase-centrifugo` container.
- Internal `/api/publish` succeeded with `X-API-Key`; request without a key was rejected.
- Allowed WebSocket origin returned 101; a disallowed origin returned 403.
- Health and metrics returned 200; admin returned 404; config mount is read-only.
- Host `/centrifugo/v1/health` still returns the gateway basic-auth 401, not Centrifugo.
- Baseline suites re-ran after Phase 1: 39/39, 56/56, 13/13.
- Phase 1 is signed off on Envoy only. Kong is intentionally out of scope by user decision on 2026-11-03.
- Final stack after review: Envoy restored, 12/12 containers healthy, no Kong container, `COMPOSE_FILE=docker-compose.yml:docker-compose.centrifugo.yml`.
- Final Envoy/Centrifugo recheck: internal health `{}`, metrics non-empty, `X-API-Key` publish `{"result":{}}`, missing key `401`, host `/centrifugo/v1/health` `401`, no published port.
- Re-verified on 2026-11-01: generator strength/mode-600/no-echo/overwrite-guard/force-backup/atomic cleanup; base disabled stack 11/11 with no Centrifugo env file; restored overlay 12/12; Phase 0 DB login, Studio 200, JWKS EC key, `hello` function, and four JWKS lines; baseline suites 39/39, 56/56, 13/13; `test-update.sh` 71/7.

### Phase 2 — Gateway Contract

Description: Expose Centrifugo through Envoy without touching Supabase Realtime routes.

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
- [x] Kong mirroring intentionally skipped; Envoy is the only supported gateway for this beta.
- [x] Verify WebSocket upgrade through Envoy.
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
- Kong was intentionally excluded from this verification; Envoy is the only supported gateway. The Phase 3 auth service enforces the final allowed-origin policy.
- Disabled the Centrifugo overlay and restarted the base stack: 11/11 healthy. Envoy started with the Centrifugo clusters unresolved; the Centrifugo and reserved alias paths returned 503, and `/realtime/v1/api/ping` remained 200. Restored the overlay to 12/12 healthy.
- Post-Phase 2 baselines: 39/39 self-hosted, 56/56 auth keys, 13/13 container logs.
- Node 22.23.4 was installed locally at `/home/user/.local/node-v22.23.4` and used for the test run. Prettier 3.8.0 check passed for the changed YAML and README; `TODO.md` is outside the repo Prettier glob and its existing tables would be reformatted.

Acceptance: The full path table in section 6.1 behaves as documented on Envoy; existing Realtime tests still pass. Kong is out of scope for this beta.

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
- Kong was intentionally excluded from this verification; Envoy is the only supported gateway.
- The test scripts derive the gateway from `API_EXTERNAL_URL` or `SUPABASE_PUBLIC_URL`, the allowed CORS origin from `SITE_URL`, and the disallowed CORS origin from `SITE_URL` with a non-production host; they do not hardcode an environment URL. An explicit base URL argument still overrides the gateway.
- Compose healthchecks contain no URL literal: the auth probe uses Node `http.get` host/port/path options and Centrifugo uses `nc -z` against its internal port.
- CORS is handled by `centrifugo-auth`; the Envoy token route disables the virtual-host CORS filter. `service_role` and unknown roles are rejected before token signing. `SUPABASE_JWKS_URL` has no default and must be supplied explicitly; the unit suite covers the missing-value failure and JWKS cache refresh.
- Key rotation was verified live: a disposable Centrifugo v6.10.2 accepted a connection token signed with the previous HMAC secret while the current secret remained active, and `checkconfig` accepted the rotation environment. Current tokens use HS256 until Ed25519 is revisited.
- The local `API_EXTERNAL_URL` already includes `/auth/v1`; the auth config no longer appends a second `/auth/v1`, and the compose issuer list was cleaned to `${API_EXTERNAL_URL} supabase`.
- Final re-run after the last auth image rebuild (2026-11-01): unit 12/12; Envoy auth 39/39 and gateway 22/22; key rotation accepted the previous-secret token. Baselines: 39/39 self-hosted, 56/56 auth keys, 13/13 container logs. `test-update.sh` remains 71 passed, 7 pre-existing failures.
- Node 22.23.4 (local install) and `supabase/centrifugo-auth:0.1.0` are recorded in `docker/versions.md`; the image runs as `node`, read-only, with no published port.

Acceptance: Valid users and anonymous clients connect; invalid, expired, cross-tenant, and service-role attempts are rejected; no auth secrets appear in logs.

### Phase 4 — Postgres Outbox and Change Notifications

Description: Add the separate change plane without touching `_realtime`.

- [x] Create `docker/volumes/centrifugo/sql/centrifugo.sql`:
  - [x] `CREATE SCHEMA IF NOT EXISTS centrifugo`.
  - [x] Roles and grants.
  - [x] Outbox and dead-letter tables.
  - [x] `centrifugo.send`.
  - [x] `centrifugo.broadcast_changes`.
  - [x] `centrifugo.broadcast_changes_trigger`.
  - [x] `centrifugo.authorize`.
  - [x] Idempotent `CREATE OR REPLACE` statements.
- [x] Ensure all functions use a fixed `search_path` and do not accept raw SQL.
- [x] Create a migration path:
  - [x] Idempotent SQL that can run on fresh and existing databases.
  - [x] A migration service or `run.sh` subcommand that waits for Postgres.
  - [x] Verify `docker compose up --wait` behavior for one-shot services; if it fails, run migrations from the auth/outbox entrypoint or an explicit command.
- [x] Build `centrifugo-outbox`:
  - [x] Connect with the least-privilege role.
  - [x] `LISTEN` for low-latency wake-ups.
  - [x] Poll as a fallback.
  - [x] Claim rows with `FOR UPDATE SKIP LOCKED`.
  - [x] Publish through the internal Centrifugo HTTP API.
  - [x] Mark published rows and retry transient failures.
  - [x] Move poison messages to dead-letter.
  - [x] Clean up published rows on retention.
  - [x] Expose metrics for lag, batch size, retries, and failures.
- [x] Define ordering semantics:
  - [x] Single-consumer mode for strict ordering.
  - [x] Partitioned mode for scale; one worker per hash partition.
- [x] Implement notification-only payloads by default.
- [x] Implement full-row payloads only for an explicit allowlist of tables.
- [x] Add a reviewed table opt-in example:
  - [x] Trigger creation SQL.
  - [x] Tenant key argument.
  - [x] Channel naming.
  - [x] RLS/privacy note.
- [x] Add tests:
  - [x] Insert/update/delete triggers create outbox rows.
  - [x] Consumer publishes to Centrifugo.
  - [x] Consumer restart does not lose rows.
  - [x] Duplicate publish is safe for clients via `message_id`.
  - [x] Poison messages land in dead-letter.
  - [x] Notification-only mode contains no row data.
  - [x] Cross-tenant payloads are never published to a tenant channel.

Verification (2026-11-02):
- `sql/centrifugo.sql` was applied twice to a disposable `supabase/postgres:17.6.1.136` database and re-run repeatedly on the local stack, including after the final grant changes; re-running is idempotent. Functions all set a fixed `search_path` and use static SQL only. A fresh-database reverify passed 37/37 checks for migration idempotency, grants, auth semantics, trigger/allowlist behavior, and privilege denials.
- The migration service is behind the `centrifugo-migrate` profile and runs as `supabase_admin` with `POSTGRES_PASSWORD`; application containers use only the `centrifugo_auth` and `centrifugo_outbox` roles. A direct check confirmed the outbox role cannot insert into `centrifugo.outbox` and the auth role cannot read it, while `centrifugo.authorize` and outbox reads/updates succeed. A reviewed trigger was created successfully as `postgres`, validating the narrow migration-role grants. The migration revokes legacy table/function grants before reapplying the intended set; dead-letter access is `SELECT, INSERT` only. Supabase's `postgres` role retains platform-level read-all membership, so it is trusted; it has no explicit outbox write or send/broadcast execute privileges.
- `docker compose up -d --wait centrifugo-migrate` returns 1 when the one-shot container exits 0, so migrations are not part of `up --wait`. `run.sh migrate` and `run.sh start` run the migration before `up --wait`; the migration service is profile-isolated.
- `centrifugo-outbox` unit tests: 18/18 (config validation, retry policy, dead-letter transitions, idempotency key, ordered batches including failure head-of-line blocking). Live integration: 11/11 (insert/update/delete delivery, restart durability, full-row allowlist, duplicate `message_id`, dead-letter, notification-only privacy, cross-tenant isolation).
- `test-centrifugo.sh` remains 22/22, including the Supabase Realtime regression checks; `test-centrifugo-auth.sh` remains 39/39 with the database authorizer active; auth unit tests are now 13/13. Baselines re-ran at 39/39 self-hosted, 56/56 auth keys, 13/13 container logs, and 11/11 upgrades manifest. `test-update.sh` reran at the known baseline of 71 passed / 7 pre-existing failures.
- Security hardening: `user_metadata` is user-editable and is no longer trusted for tenant authorization in the auth service or `centrifugo.authorize`; the SQL and unit suite default-deny a token whose only tenant claim is `user_metadata.tenant_id`. Live `psql` check returned `false` for a user_metadata-only claim and `true` for the equivalent app_metadata claim. Token and channel tests still pass.
- The live worker uses `LISTEN centrifugo_outbox` plus polling, `FOR UPDATE SKIP LOCKED`, lock renewal, exponential retry, DLQ, retention cleanup, and Prometheus metrics. Strict mode is documented as single-consumer; a transient failure pauses and releases the remaining claimed batch, and the delayed row blocks later rows across polls until it succeeds or dead-letters. Partitioned mode filters by `hashtext(channel) % partition_count`.

Acceptance: A reviewed table change reaches a subscribed client; no rows are lost or leaked; `_realtime` is untouched.

### Phase 5 — Channel Behavior and Feature Parity

Description: Define and test the behavior our SDKs expose.

- [x] Configure namespaces:
  - [x] `tenant` for tenant-scoped table changes.
  - [x] `user` for private user channels.
  - [x] `public` for explicitly public broadcast channels.
- [x] Enable and test:
  - [x] Subscribe/unsubscribe.
  - [x] Broadcast from server and authorized client.
  - [x] Presence (`presence`; automatic connection presence; `track`/`untrack` documented as partial).
  - [x] Join/leave events.
  - [x] History and recovery.
  - [x] Private channel authorization.
  - [x] Anonymous access only where explicitly allowed.
  - [x] Error mapping for denied subscription, invalid token, and rate limit.
- [x] Document mapping from Supabase Realtime concepts:
  - [x] `channel.subscribe()` -> Centrifugo subscription.
  - [x] `channel.send()` -> publish proxy or server API.
  - [x] `presence` -> Centrifugo presence.
  - [x] `postgres_changes` -> outbox change events.
  - [x] `private` -> subscribe proxy.
  - [x] `system` events -> connection/error events.
  - [x] `filters` -> client-side filtering in beta; no server-side filter parity.
- [x] Write `COMPATIBILITY.md` with supported, partial, and unsupported features.
- [x] Explicitly document the beta limitation: no WAL CDC and no exact Postgres RLS row filtering.
- [x] Test multi-tenant isolation with two users and two tenants.

Acceptance: The compatibility matrix is accurate and covered by tests; no channel leaks data across tenants.

### Phase 6 — Scale and Resilience

Description: Make Centrifugo horizontally scalable without changing the public contract.

- [x] Add a Redis scale overlay or environment profile.
- [x] Configure Centrifugo engine/broker/presence manager for Redis.
- [x] Pin the Redis image if bundled; prefer external Redis for production.
- [x] Add Redis authentication and TLS options.
- [x] Run at least two Centrifugo nodes behind Envoy.
- [x] Verify no sticky sessions are required.
- [x] Verify WebSocket connections survive a node restart via reconnect.
- [x] Verify history/recovery across nodes.
- [x] Verify subscribe proxy calls work from every node.
- [x] Verify outbox consumers do not duplicate work.
- [x] Test Redis reconnect behavior after a local Redis restart.
- [x] Test local Redis Sentinel failover with a master/replica/Sentinel topology and a master-only proxy.
- [ ] Test external Redis HA failover with a production-like topology.
- [x] Run load tests:
  - [x] Reconnect storm.
  - [x] Fan-out to many subscribers.
  - [x] Large channel count per user.
  - [x] Outbox throughput.
- [x] Record capacity limits and recommended node sizing.
- [x] Document local vs production topology.

Acceptance: Losing one Centrifugo node does not lose data or permanently disconnect clients; load targets are documented and met.

Status: local acceptance met on 2026-11-03 (33 scale checks, 10 load checks, 19 HA checks; gateway/auth/features/outbox suites also pass). The HA reference uses a master-only HAProxy that closes sessions to a demoted backend; a publish during the promotion window can still be lost and the HA test retries until delivery. External Redis HA failover remains an operational validation.

### Phase 7 — Observability and Operations

Description: Make the beta operable without reading source code.

- [x] Add Docker log routing:
  - [x] `supabase-centrifugo` -> `centrifugo` route.
  - [x] `supabase-centrifugo-auth` -> `centrifugo` route with a service field.
  - [x] `supabase-centrifugo-outbox` and `supabase-centrifugo-outbox-2` -> `centrifugo` route.
  - [x] Parse JSON or text as appropriate.
  - [x] Filter health-check noise.
  - [x] Sink to a distinct Logflare source (`centrifugo.logs.prod`).
- [x] Expose Prometheus metrics on internal endpoints: Centrifugo native metrics, plus auth HTTP, token, authorization, rate-limit, and process metrics.
- [x] Add health checks for Centrifugo, auth, and outbox.
- [x] Add alerts/dashboards for:
  - [x] Connection count.
  - [x] Subscribe denials.
  - [x] Auth latency and errors.
  - [x] Token refresh failures.
  - [x] Outbox lag and dead letters.
  - [x] Redis errors.
  - [x] Node restarts.
- [x] Add an audit trail for authorization denials without logging tokens.
- [x] Add a runbook:
  - [x] WebSocket 401/403.
  - [x] Auth service down.
  - [x] Outbox lag.
  - [x] Redis down.
  - [x] Gateway route mismatch.
  - [x] Secret rotation.
  - [x] Rollback.
- [x] Add log tests in `docker/tests/test-centrifugo-logs.sh` and metrics/audit checks to `docker/tests/test-centrifugo.sh` and `docker/tests/test-centrifugo-auth.sh`.

Acceptance: An operator can diagnose the common failures from logs, metrics, and the runbook.

Status: implemented on 2026-11-03. `test-centrifugo.sh` passes 30/30, `test-centrifugo-auth.sh` 48/48, auth unit tests 15/15, and `test-centrifugo-logs.sh` validates the Vector config plus 4/4 pipeline tests. Auth metrics cover HTTP requests and latency, token issuance/failures, authorization decisions and latency, rate limits, publish rejections, and process start time. Audit logs include action, reason, channel, and user without tokens. Vector routes Centrifugo, auth, outbox, and outbox-2 logs, filters `/health`, and sends to `centrifugo.logs.prod`. The `logs-source-init` service provisions the source before Vector starts because Logflare only seeds built-in Supabase sources. Live delivery and health-log filtering are verified when the analytics and auth containers are running.

Battle test status: passed on 2026-11-03 against the scale-only stack. Auth stop kept existing WebSockets connected and receiving API publications while token issuance returned 503; auth restart restored token issuance without disconnecting them. Stopping node 2 left the surviving node and its subscribers healthy, but gateway API publishes returned intermittent 503s until Envoy ejected the failed endpoint after three 5-second health checks. Stopping outbox consumer 0 left consumer 1 to publish the pending row. Envoy restart dropped WebSockets with 1006 and new clients reconnected after health. Redis restart sent existing subscribers `unsubscribe` code 2500 (`insufficient state`); a client that resubscribed recovered and received later publications. New clients worked after Redis recovered. `test-centrifugo-scale.sh` now covers this path: it restarts Redis under an existing subscriber, asserts the `2500` unsubscribe, resubscribes, and verifies delivery. All post-battle suites passed.

### Phase 8 — Client SDKs and Migration

Description: Provide client support on every target platform without a Phoenix adapter.

- [x] Confirm the SDK boundary decision (Open Decision 1: official SDKs only, no separate client SDK).
- [x] Write a shared contract:
  - [x] Connection states.
  - [x] Channel lifecycle.
  - [x] Broadcast, presence, and postgres-change event shapes.
  - [x] Error codes.
  - [x] Token refresh.
  - [x] Reconnect and recovery.
- [x] Adopt official clients:
  - [x] JavaScript/TypeScript with `centrifuge@5.8.0`.
  - [x] Kotlin/Android with `io.github.centrifugal:centrifuge-java:0.8.0`.
  - [x] Swift/iOS, Flutter/Dart, Python, and Go use their official SDKs; install commands are documented, with JS and Kotlin as the tested integrations.
- [x] Use official Centrifugo SDKs as the transport.
- [x] Do not build a Supabase-like SDK or emulate the Phoenix wire protocol; keep the JS and Kotlin integrations as examples.
- [x] Implement `getToken` against `/centrifugo/v1/auth/token`.
- [x] Map channel authorization and connection errors to actionable messages.
- [x] Implement reconnect, history recovery, and duplicate-event handling.
- [x] Add reference integrations for JS and Kotlin/Android.
- [x] Add cross-SDK conformance tests against the same server.
- [x] Write `CLIENT_MIGRATION.md`:
  - [x] Base URL changes.
  - [x] Auth changes.
  - [x] Event mapping.
  - [x] Unsupported behavior.
  - [x] Rollback to Supabase Realtime.
- [x] Verify `/realtime/v1/connection/websocket` and `/centrifugo/v1/connection/websocket` both work with the clients.

Acceptance: At least JS/TS and one mobile client pass the shared conformance suite; migration and rollback are documented.

Status: implemented on 2026-11-03. Official `centrifuge-js` 5.8.0 and the Android-compatible `centrifuge-java` 0.8.0 client pass `tests/test-centrifugo-clients.sh` against both client WebSocket routes: token exchange, subscribe, presence, history, reconnect, recovery, and duplicate suppression all pass. The examples are reference integrations, not a published SDK.

### Phase 9 — Test Suite and CI

Description: Make the beta safe to merge and maintain.

- [x] Create `docker/tests/test-centrifugo.sh`:
  - [x] Health endpoint.
  - [x] WebSocket upgrade through Envoy.
  - [x] Valid user token connects.
  - [x] Anonymous publishable key connects.
  - [x] Missing/invalid token is rejected (also covered by `test-centrifugo-security.sh`).
  - [x] Expired token is rejected (also covered by `test-centrifugo-security.sh`).
  - [x] Cross-tenant subscribe is denied.
  - [x] Allowed subscribe succeeds.
  - [x] Broadcast publish succeeds.
  - [x] Unauthorized publish is denied.
  - [x] Outbox trigger -> consumer -> client delivery.
  - [x] Notification-only payload contains no row data.
  - [x] `/realtime/v1/websocket` still reaches Supabase Realtime.
  - [x] `/realtime/v1/connection/websocket` reaches Centrifugo.
  - [x] Centrifugo logs reach the expected source (`test-centrifugo-logs.sh`, including live delivery when analytics runs).
- [x] Add unit tests for:
  - [x] Secret generation (no secret output).
  - [x] Token claims and expiry.
  - [x] Subscribe channel parsing.
  - [x] SQL helper validation.
  - [x] Outbox retry/backoff.
- [x] Add integration tests for auth + Centrifugo + Postgres + outbox.
- [x] Add security tests:
  - [x] Service-role token cannot connect as a client.
  - [x] API key cannot be used as a client token.
  - [x] Cross-tenant channel access is denied.
  - [x] Outbox functions are not callable by `anon`/`authenticated`.
  - [x] Secrets are not present in logs.
- [x] Add load/soak tests or documented manual load-test procedures.
- [x] Add a path-filtered CI workflow for Centrifugo files.
- [x] Do not alter existing required CI checks.
- [x] Ensure tests skip cleanly when the overlay is disabled.
- [x] Ensure no test prints `.env` values.

Status: implemented on 2026-11-06. The suite passes locally with the scale overlay and the logs overlay enabled, including live Logflare delivery and health-log filtering. `logs-source-init` provisions `centrifugo.logs.prod` before Vector starts because Logflare only seeds built-in Supabase sources. CI runs gateway, auth, security, SQL, features, outbox, client, secret, and log checks on Centrifugo path changes; scale, load, and HA suites remain manual. Existing required workflows are unchanged.

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
- [ ] Write `CLIENT_MIGRATION.md`.
- [x] Write `COMPATIBILITY.md`.
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
- [x] JS/TS and one mobile client pass conformance.
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
sh tests/test-centrifugo-auth.sh
sh tests/test-centrifugo-features.sh
sh tests/test-centrifugo-outbox.sh

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
| 2026-10-31 | Additive Envoy/Kong routes and a distinct Vector/Logflare source | Superseded: Envoy only |
| 2026-10-31 | Existing Studio Realtime Inspector stays on Supabase Realtime | Locked |
| 2026-10-31 | Confirm official SDK vs thin Supabase-like adapter | Open |
| 2026-10-31 | Confirm `centrifugo-auth` language and token signing | Resolved: Node.js 22.23.4 ESM, HMAC-SHA256 with previous-key rotation; Ed25519 deferred |
| 2026-10-31 | Pin `centrifugo/centrifugo:v6.10.2` | Resolved |
| 2026-11-01 | Enforce final CORS policy in `centrifugo-auth`; disable per-route Envoy CORS and remove Kong `cors` | Locked |
| 2026-11-01 | Phase 3 uses a local default-deny fallback until the Phase 4 `centrifugo.authorize` migration is applied | Locked |
| 2026-11-01 | Rotate connection-token keys through Centrifugo previous-secret env vars; keep Ed25519 as a future option | Locked |
| 2026-11-02 | Enable presence, opt-in join/leave, bounded history/recovery, and JSON-object publishes for all channel namespaces; keep proxy authorization authoritative | Locked |
| 2026-11-03 | Gateway support is Envoy-only; skip Kong because Supabase is standardizing on Envoy | Locked |
