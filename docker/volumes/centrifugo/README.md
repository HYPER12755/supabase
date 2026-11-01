# Centrifugo Beta

Centrifugo runs as an additive, opt-in realtime backend alongside Supabase Realtime.

Phase 1 status: the Centrifugo service, config, local secrets, and health check exist. Gateway routes, auth, and Postgres changes are not implemented yet. Centrifugo is reachable only from the Compose network.

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
docker exec supabase-auth wget -qO- http://centrifugo:8000/health
```

`docker port supabase-centrifugo` should print nothing.

## Endpoints

These paths are reserved by the beta contract but are not routed through the gateway until Phase 2:

- `/centrifugo/v1/connection/websocket`
- `/centrifugo/v1/websocket`
- `/centrifugo/v1/auth/token`
- `/centrifugo/v1/health`
- `/centrifugo/v1/api/*`
- `/realtime/v1/connection/*`

Supabase Realtime keeps `/realtime/v1/websocket` and `/realtime/v1/api/*`.

## Configuration

- `config.json` contains non-secret server defaults and namespace placeholders.
- `.env.centrifugo` contains local secrets and is loaded by the overlay.
- `CENTRIFUGO_CLIENT_ALLOWED_ORIGINS` is derived from the deployment's `SITE_URL` and `SUPABASE_PUBLIC_URL`; no environment-specific origins are committed.
- The HTTP API is internal-only. Do not publish port 8000 or the API key.
- Internal HTTP API requests use the `X-API-Key` header; `Authorization: Bearer` is not accepted.
- The admin UI is disabled by default.

## Notes

- The image is pinned to `centrifugo/centrifugo:v6.10.2`.
- Phase 1 uses the HMAC secret in `.env.centrifugo`. Phase 3 will choose between HMAC and Ed25519 per the open decision.
- `--force` keeps the previous generated file as `.env.centrifugo.old`; both files are ignored by git.
- Redis is not part of the default overlay. It belongs to the Phase 6 scale-out work.
