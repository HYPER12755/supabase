# Supabase Realtime Compatibility

This matrix describes what the Centrifugo beta exposes relative to Supabase Realtime. Compatibility is at the feature and SDK layer; Centrifugo uses its native protocol, not the Phoenix protocol.

## Feature Matrix

| Supabase Realtime | Centrifugo beta | Status | Notes |
| --- | --- | --- | --- |
| `channel.subscribe()` | `subscribe` command through the subscribe proxy | Supported | `tenant`, `user`, and `public` namespaces; the database authorizer is authoritative when configured. |
| `channel.unsubscribe()` | `unsubscribe` command | Supported | Removes connection presence and stops publications for that subscription. |
| `channel.send({ type: 'broadcast' })` | Client publish through the publish proxy | Supported | Authenticated clients only where authorized. Payloads must be JSON objects. Anonymous clients cannot publish. |
| Server-side broadcast | Internal Centrifugo HTTP API | Supported | Use `POST /centrifugo/v1/api/publish` with `X-API-Key`. The API must remain internal. |
| `presence` read | `presence` command | Supported | Authenticated subscribers can read presence for their channels. Anonymous clients are denied. |
| `channel.track(state)` / `channel.untrack()` | Automatic connection presence | Partial | Centrifugo presence is connection-scoped. A client is present while subscribed. There is no API for arbitrary per-client presence state; connection and subscription metadata come from the auth service, not the client. |
| Join/leave events | `join` / `leave` pushes | Supported | Enable per subscription with `join_leave: true`; clients must also have presence permission. Join/leave is not forced on large channels. |
| History / reconnect recovery | `history` command and recoverable subscriptions | Supported | Beta defaults: 100 publications, 300-second retention, forced recovery. History is bounded and memory-backed; it is lost on a Centrifugo restart. |
| Private channel authorization | `user:<user_id>` namespace through the subscribe proxy | Supported | A user can subscribe only to their own `user:<uuid>` channel. Supabase's `private:` prefix is not translated automatically. |
| Tenant channel authorization | `tenant:<tenant_id>:...` namespace through the subscribe proxy | Supported | Tenant membership comes from server-controlled claims; `user_metadata` is not trusted. Cross-tenant subscribe and publish are denied. |
| `postgres_changes` | Outbox change events | Partial | Notification-only payloads by default. Full rows require an explicit reviewed allowlist. No WAL CDC, no exact RLS row filtering, and no old-record replay. |
| `postgres_changes` filters | Client-side filtering | Partial | There is no server-side equality/in-filter parity. Clients receive the channel's change events and filter locally. |
| `private` channel naming | Namespaced channels plus subscribe proxy | Partial | Existing `private:` topic names need an explicit mapping. Beta channels are `tenant:`, `user:`, or `public:` and are validated server-side. |
| `system` events | Connection/error events | Partial | Centrifugo exposes connect, disconnect, unsubscribe, and error codes; these are not the same payloads as Supabase `system` events. |
| Phoenix protocol | Native Centrifugo protocol | Unsupported | No adapter. Clients use Centrifugo SDKs or the documented native protocol. |

## Anonymous Access

- Anonymous clients may subscribe to `public:*` channels only.
- Anonymous clients cannot publish, read presence, or read history.
- `user:*` and `tenant:*` subscriptions require an authenticated Supabase user.

## Error Mapping

| Condition | Client-visible result |
| --- | --- |
| Denied subscribe or publish | Subscribe/publish error code `403` |
| Malformed or unsupported channel | Subscribe/publish error code `403` from the proxy |
| Invalid connection token | WebSocket close code `3500` |
| Expired connection token | Token error `109`; reconnect with a token from `/centrifugo/v1/auth/token` |
| Publish rate limit | Publish error code `429` |
| Token endpoint rate limit | HTTP `429` with `Retry-After` |
| Authorization database unavailable | Proxy error `503`; access is denied |

## Current Limits

- Channel names are limited to 255 characters. `public` names are at most 128 characters and cannot contain `:`. IDs in `user` and `tenant` namespaces must be UUIDs, followed by at most four segments of up to 64 characters.
- Client publish payloads are limited to 16 KiB and rate-limited per user. Trusted server-side broadcasts should use the HTTP API.
- History and presence are per-namespace settings and apply to all channels in that namespace.
- History is a bounded cache, not a durable event log. Do not use it as the source of truth.
- Row-level policies are not evaluated for change events. Every subscriber to a tenant channel receives the event, including notification-only metadata; opt in only when every tenant member may know the change occurred.
- The beta does not provide Redis scale-out, multi-node presence/history, or durable history. Those belong to the scale phase.
- Full-row change payloads bypass table RLS because the trigger runs as its owner. Review the allowlist entry before enabling it.

## Test Evidence

| Behavior | Test |
| --- | --- |
| Subscribe, unsubscribe, server/client broadcast, presence, join/leave, history/recovery, anonymous access, anonymous tenant/user denial, private and tenant authorization, cross-tenant live/presence/history isolation, error mapping | `docker/tests/test-centrifugo-features.sh` |
| Token issuance, JWKS verification, CORS, proxy authorization, publishing limits, rate limits | `docker/tests/test-centrifugo-auth.sh` |
| Outbox delivery, notification-only privacy, restart durability, dead letters, cross-tenant isolation | `docker/tests/test-centrifugo-outbox.sh` |
| Gateway routes and Supabase Realtime regression | `docker/tests/test-centrifugo.sh` |
