# Centrifugo Beta

Centrifugo runs as an additive, opt-in realtime backend alongside Supabase Realtime.

Phase 3 status: `centrifugo-auth` issues short-lived Centrifugo connection tokens, validates Supabase JWTs/JWKS, and runs subscribe/publish authorization through Centrifugo proxies. Postgres migration, outbox, and the authoritative `centrifugo.authorize` function are Phase 4 work; until `CENTRIFUGO_AUTH_DATABASE_URL` is set, the service uses a local default-deny fallback for `public`, `user`, and `tenant` channels. Kong mirrors the routes and passes the gateway suite in a disposable root container; the Kong override itself remains blocked by a pre-existing image permission issue.

## Enable

From `docker/`:

```sh
sh utils/generate-centrifugo-keys.sh
sh run.sh config add centrifugo
sh run.sh start
sh run.sh status
```

The generated `docker/.env.centrifugo` is ignored by git and must not be committed.

## Disable

```sh
sh run.sh stop
sh run.sh config remove centrifugo
sh run.sh start
```

Stop before removing the overlay so Compose can remove the Centrifugo container. The base stack does not reference `.env.centrifugo`, so it starts normally with the overlay disabled.

## Verify

```sh
docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo
docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo-auth
docker exec supabase-auth wget -qO- http://centrifugo:8000/health
sh tests/test-centrifugo.sh
sh tests/test-centrifugo-auth.sh
```

`docker port supabase-centrifugo` and `docker port supabase-centrifugo-auth` should print nothing. `test-centrifugo.sh` checks the gateway contract, including that `/realtime/v1/websocket` still reaches Supabase Realtime. `test-centrifugo-auth.sh` checks token issuance, CORS, user/anonymous access, service-role rejection, and channel authorization through the live proxies.

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
- Channel rules are default deny. Without `CENTRIFUGO_AUTH_DATABASE_URL`, `public:*` subscribe is open, public publish requires a user, `user:<uuid>` requires the matching user, and `tenant:<uuid>` requires a matching `app_metadata.tenant_id` or `user_metadata.tenant_id`. With the database URL, `centrifugo.authorize(channel, claims)` is authoritative.
- Authorization decisions are cached for a few seconds keyed by action, user, channel, and `CENTRIFUGO_AUTHZ_CACHE_VERSION`. Bump the version or wait for the TTL after a role change.
- Publish requests are size-limited and rate-limited. Prefer Centrifugo's internal HTTP API for trusted server-side broadcasts.
- Logs contain request metadata and denial reasons only; tokens, API keys, and full claims are never logged.

## Configuration

- `config.json` contains non-secret server defaults, channel proxies, and namespace configuration.
- `.env.centrifugo` contains local secrets and is loaded by the overlay.
- `CENTRIFUGO_CLIENT_ALLOWED_ORIGINS` is derived from the deployment's `SITE_URL` and `SUPABASE_PUBLIC_URL`; the auth service enforces the same origins for token CORS.
- The HTTP API requires the Centrifugo API key and must not be exposed to clients. Do not publish port 8000 or the API key.
- Internal HTTP API requests use the `X-API-Key` header; `Authorization: Bearer` is not accepted.
- The admin UI is disabled by default.
- `CENTRIFUGO_AUTH_DATABASE_URL` is optional until Phase 4; when set, the service uses the least-privilege `centrifugo_auth` role and calls `centrifugo.authorize`.

## Token rotation

1. Set `CENTRIFUGO_CLIENT_TOKEN_HMAC_PREVIOUS_SECRET_KEY` to the current secret and `CENTRIFUGO_CLIENT_TOKEN_HMAC_PREVIOUS_SECRET_KEY_VALID_UNTIL` to a Unix timestamp at least one token TTL plus clock skew in the future.
2. Replace `CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY` with the new secret and restart `centrifugo-auth` and `centrifugo`.
3. After the expiry timestamp, clear both previous-secret variables and restart again.

Centrifugo accepts the previous key until the timestamp; new tokens are always signed with the current key.

## Notes

- The images are pinned to `centrifugo/centrifugo:v6.10.2` and `node:22.23.4-alpine` (auth build base).
- Phase 3 uses HMAC-SHA256 with the previous-key rotation above; Ed25519 remains a future option.
- `--force` keeps the previous generated file as `.env.centrifugo.old`; both files are ignored by git.
- Redis is not part of the default overlay. It belongs to the Phase 6 scale-out work.
