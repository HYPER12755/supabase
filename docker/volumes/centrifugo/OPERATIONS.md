# Centrifugo Operations

This runbook covers the self-hosted Centrifugo beta. Envoy is the only supported gateway. Metrics and health endpoints are internal to the Compose network.

## Topology

```
client -> Envoy :8000 -> centrifugo :8000 (WebSocket, API, /health, /metrics)
                      -> centrifugo-auth :8090 (/auth/*, /health, /metrics)
centrifugo -> Redis -> centrifugo-outbox :9100 (/health, /metrics)
Centrifugo/auth/outbox logs -> Vector -> Logflare source centrifugo.logs.prod
```

Do not publish the metrics or health ports. Scrape them from a private network or a sidecar.

## Prometheus scrape configuration

```yaml
scrape_configs:
  - job_name: centrifugo
    metrics_path: /metrics
    static_configs:
      - targets: ["centrifugo:8000"]

  - job_name: centrifugo-auth
    metrics_path: /metrics
    static_configs:
      - targets: ["centrifugo-auth:8090"]

  - job_name: centrifugo-outbox
    metrics_path: /metrics
    static_configs:
      - targets: ["centrifugo-outbox:9100"]
```

## Key metrics

| Area | Metric | Use |
| --- | --- | --- |
| Connections | `centrifugo_node_num_clients` | Per-node connected clients. Alert on a sudden drop to zero or a large imbalance. |
| Subscriptions | `centrifugo_node_num_subscriptions`, `centrifugo_node_num_channels` | Fan-out and channel growth. |
| Redis | `centrifugo_broker_redis_pub_sub_errors` | Any sustained increase means broker connectivity or failover trouble. |
| Redis | `centrifugo_broker_redis_pub_sub_dropped_messages` | Application-level dropped messages. Any increase is actionable. |
| Redis | `centrifugo_node_pub_sub_lag_seconds` | Cross-node delivery delay. |
| Proxy | `centrifugo_proxy_errors` | Auth/publish proxy failures. Correlate with auth logs. |
| Proxy | `centrifugo_proxy_duration_seconds_histogram` | p95/p99 proxy latency. |
| Restarts | `process_start_time_seconds` | Alert when the value changes within a short window. |
| Auth HTTP | `centrifugo_auth_http_requests_total` | Requests by route and status. |
| Auth latency | `centrifugo_auth_http_request_duration_seconds` | HTTP p95/p99 by route. |
| Auth tokens | `centrifugo_auth_token_issued_total` | Issued tokens by role. |
| Auth tokens | `centrifugo_auth_token_failures_total` | Token failures by reason. |
| Authorization | `centrifugo_auth_authorization_decisions_total` | Allowed, denied, and error decisions by action. |
| Authorization | `centrifugo_auth_authorization_duration_seconds` | Database/cache authorization latency. |
| Rate limits | `centrifugo_auth_rate_limited_total` | Throttling by scope. |
| Publish rejects | `centrifugo_auth_publish_rejected_total` | Oversized or invalid client publishes. |
| Outbox | `centrifugo_outbox_worker_up` | Must stay `1`. |
| Outbox | `centrifugo_outbox_pending`, `centrifugo_outbox_lag_seconds` | Backlog size and age. |
| Outbox | `centrifugo_outbox_dead_letter_total` | Any increase requires investigation. |
| Outbox | `centrifugo_outbox_retries_total`, `centrifugo_outbox_failures_total` | Retry pressure and publish failures. |

## Alert examples

Tune thresholds to the deployment. These are starting points, not universal limits.

```yaml
groups:
  - name: centrifugo
    rules:
      - alert: CentrifugoNodeDown
        expr: up{job="centrifugo"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Centrifugo node is not scrapeable"

      - alert: CentrifugoNoClients
        expr: sum(centrifugo_node_num_clients) == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "All Centrifugo clients disconnected"

      - alert: CentrifugoConnectionDrop
        expr: |
          sum(centrifugo_node_num_clients)
            < 0.5 * sum(centrifugo_node_num_clients offset 1h)
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Centrifugo connections dropped by more than half"

      - alert: CentrifugoRedisErrors
        expr: increase(centrifugo_broker_redis_pub_sub_errors[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Centrifugo is seeing Redis PUB/SUB errors"

      - alert: CentrifugoProxyErrors
        expr: increase(centrifugo_proxy_errors[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Centrifugo proxy calls are failing"

      - alert: CentrifugoRestarted
        expr: changes(process_start_time_seconds{job="centrifugo"}[15m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Centrifugo restarted"

      - alert: CentrifugoAuthDown
        expr: up{job="centrifugo-auth"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Centrifugo auth service is not scrapeable"

      - alert: CentrifugoAuthTokenFailures
        expr: |
          sum(rate(centrifugo_auth_token_failures_total[5m])) > 0.1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Elevated token issuance failures"

      - alert: CentrifugoAuthLatency
        expr: |
          histogram_quantile(
            0.95,
            sum by (le) (rate(centrifugo_auth_http_request_duration_seconds_bucket[5m]))
          ) > 0.25
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Centrifugo auth p95 latency is above 250 ms"

      - alert: CentrifugoAuthorizationErrors
        expr: |
          sum(rate(centrifugo_auth_authorization_decisions_total{decision="error"}[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Authorization errors are elevated"

      - alert: CentrifugoOutboxDown
        expr: centrifugo_outbox_worker_up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Centrifugo outbox worker is down"

      - alert: CentrifugoOutboxLag
        expr: centrifugo_outbox_lag_seconds > 60
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Centrifugo outbox is more than 60 seconds behind"

      - alert: CentrifugoOutboxDeadLetters
        expr: increase(centrifugo_outbox_dead_letter_total[10m]) > 0
        labels:
          severity: critical
        annotations:
          summary: "Centrifugo outbox moved rows to the dead-letter table"
```

## Dashboard queries

```promql
# Connected clients by node
sum by (instance) (centrifugo_node_num_clients)

# Subscriptions and channels
sum(centrifugo_node_num_subscriptions)
sum(centrifugo_node_num_channels)

# Authorization decisions per second
sum by (action, decision) (rate(centrifugo_auth_authorization_decisions_total[5m]))

# Auth HTTP p95 by route
histogram_quantile(
  0.95,
  sum by (le, path) (rate(centrifugo_auth_http_request_duration_seconds_bucket[5m]))
)

# Token failures by reason
sum by (reason) (rate(centrifugo_auth_token_failures_total[5m]))

# Outbox backlog and age
centrifugo_outbox_pending
centrifugo_outbox_lag_seconds

# Redis and proxy error rates
sum(rate(centrifugo_broker_redis_pub_sub_errors[5m]))
sum(rate(centrifugo_proxy_errors[5m]))
```

## Health checks

```bash
docker exec supabase-centrifugo wget -qO- http://127.0.0.1:8000/health
docker exec supabase-centrifugo-auth wget -qO- http://127.0.0.1:8090/health
docker exec supabase-centrifugo-outbox wget -qO- http://127.0.0.1:9100/health
docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo supabase-centrifugo-auth supabase-centrifugo-outbox
```

Centrifugo returns `{}` from `/health`. Auth returns `{"status":"ok"}`. Outbox returns `{"status":"ok","lastPollAgeSeconds":...}`. `centrifugo_outbox_worker_up` must be `1`; a healthy HTTP process with a stopped worker is not healthy.

## Logs

These routes are active when `docker-compose.logs.yml` is enabled. Vector routes these containers:

- `supabase-centrifugo`
- `supabase-centrifugo-auth`
- `supabase-centrifugo-outbox`
- `supabase-centrifugo-outbox-2`

All events go to the `centrifugo.logs.prod` Logflare source. Logflare only seeds its built-in Supabase sources, so `run.sh start` runs the `logs-source-init` service before bringing up the stack; it creates `centrifugo.logs.prod` in `_analytics.sources` and confirms ingestion before Vector starts. If you use raw `docker compose up` instead, run `docker compose run --rm logs-source-init` first. If the source is missing, Vector receives `401 Unauthorized` and drops events. Events carry `metadata.service` (`centrifugo`, `auth`, or `outbox`) and `metadata.instance` (the Compose container name). JSON logs are parsed; outbox text logs stay as text. Request logs for `/health` are dropped.

Authorization denials and rate limits include `action`, `reason`, `channel`, and `user` where available. Tokens, API keys, and full claims are never written to logs.

If the log pipeline is down, Docker still holds local container logs. The pipeline does not buffer indefinitely and does not guarantee delivery to Logflare during an outage.

## Failure procedures

### WebSocket 401 or 403

1. Check `centrifugo_auth_token_failures_total` by reason.
2. Check auth logs for `origin_not_allowed`, `invalid_apikey`, `token_expired`, or `invalid_authorization`.
3. Confirm the client sends the Supabase anon or publishable key in `apikey`, and a valid user token in `Authorization: Bearer` when required.
4. Confirm the client origin matches `SITE_URL` or the configured allowed origins.
5. Confirm the auth host clock is synchronized; token validation has a small clock tolerance.
6. Confirm JWKS is reachable from `centrifugo-auth` and the signing key has not rotated without refreshing JWKS.
7. Do not bypass auth to restore service. Fix the key, origin, clock, or JWKS path.

### Auth service down

1. Check `up{job="centrifugo-auth"}` and `centrifugo-auth` health.
2. Read auth container logs for startup, database, or JWKS errors.
3. Confirm Postgres is reachable and the authorizer role can execute its function.
4. Restart only `centrifugo-auth`; Centrifugo reconnects proxied calls after the service returns.
5. Existing WebSocket connections stay open and continue to receive server API publications, but new connections, token refreshes, and proxy-authorized actions fail until auth recovers.

### Outbox lag or dead letters

1. Check `centrifugo_outbox_worker_up`, `centrifugo_outbox_pending`, and `centrifugo_outbox_lag_seconds`.
2. Check `centrifugo_outbox_retries_total` and `centrifugo_outbox_failures_total` for the failure reason.
3. Confirm Redis is reachable from both outbox consumers.
4. Confirm the outbox table is not blocked by a long transaction or lock.
5. Inspect dead-letter rows before retrying. Do not delete rows to clear lag.
6. Restart one outbox consumer at a time. Ordering is partitioned, so the other consumer continues.

### Redis down or failover

1. Check `centrifugo_broker_redis_pub_sub_errors` and `centrifugo_broker_redis_pub_sub_dropped_messages`.
2. Check Redis, Sentinel, and HAProxy health and logs.
3. Existing subscribers receive `unsubscribe` code `2500` (`insufficient state`) after the broker recovers. The client must resubscribe and use history recovery to fill the gap; do not assume an open WebSocket still has its subscriptions.
4. New clients connect normally after the broker recovers.
5. In the local HA reference, HAProxy closes sessions to a demoted master. A publish during the promotion window can still be lost; retry or recover from history.

### Gateway restart

1. Expect active WebSockets to close with code `1006` while Envoy is down.
2. Restart Envoy and wait for its health check to pass.
3. Verify token issuance, a new WebSocket, and an API publish through the gateway.
4. Check that `centrifugo_client_connections_accepted` resumes increasing on both nodes.

### Gateway route mismatch

1. Run `sh docker/tests/test-centrifugo.sh` from `docker/`.
2. Confirm Envoy routes for WebSocket, health, API, and auth.
3. Confirm `/realtime/v1/websocket` still reaches Supabase Realtime.
4. Confirm DNS resolves `centrifugo` and `centrifugo-auth` inside the Compose network.
5. Do not add a public route for `/metrics`.

### Secret rotation

1. Generate new values with `docker/volumes/centrifugo/generate-centrifugo-keys.sh`.
2. Update `.env.centrifugo`; keep the previous secret available during the overlap window.
3. Restart `centrifugo-auth` and then Centrifugo.
4. Verify token issuance, WebSocket connect, and channel authorization.
5. Remove the previous secret after all clients have refreshed.

### Rollback

1. Remove the Centrifugo overlay from `.env`.
2. Stop the overlay services: `docker compose -f docker-compose.yml -f docker-compose.centrifugo.yml down`.
3. Restart the base stack.
4. Verify `/realtime/v1/websocket` and the Supabase Realtime API still work.
5. Keep the outbox tables and functions; disable the overlay rather than deleting data.

### Node restart

1. Check `changes(process_start_time_seconds[15m])` and container health.
2. Confirm the node rejoined the cluster and clients rebalanced.
3. Check `centrifugo_node_num_nodes` and per-node client counts.
4. Check Redis errors and proxy errors around the restart.
5. Expect Envoy to keep sending a share of requests to the failed node until three 5-second health checks mark it unhealthy. API publishes can return `503` during that window; retry with application-level idempotency. Clients on the failed node reconnect to the surviving node; clients on the surviving node stay connected.
6. If clients do not recover, follow the gateway and Redis procedures.

## Local verification

From `docker/`:

```bash
sh tests/test-centrifugo.sh
sh tests/test-centrifugo-auth.sh
sh tests/test-centrifugo-security.sh
sh tests/test-centrifugo-sql.sh
sh tests/test-centrifugo-secrets.sh
sh tests/test-centrifugo-logs.sh
```

The log test validates the Vector config, runs Vector unit tests for routing, health filtering, JSON parsing, audit fields, and outbox text logs, and checks the Logflare source name. When the analytics and auth containers are running, it also generates an auth log and verifies live delivery to `centrifugo.logs.prod`; otherwise that portion is skipped. The security and SQL tests skip when the database or Centrifugo containers are not running. The secret-generation test does not require the stack.
