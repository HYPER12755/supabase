# Centrifugo Client Contract

This contract applies to applications using the official Centrifugo SDKs. The JavaScript and Kotlin files under `examples/` are reference integrations, not a separately published SDK. There is no Phoenix protocol adapter.

## SDK Boundary

- Use `centrifuge` 5.8.0 for JavaScript/TypeScript and `io.github.centrifugal:centrifuge-java` 0.8.0 for Kotlin/Android. Swift, Dart, Python, and Go use their official Centrifugo SDKs.
- Do not reproduce the Supabase Realtime channel API or the Phoenix wire protocol.
- Let the official SDK own reconnect backoff, token refresh, subscription retry, and recovery positions.
- Accept `message_id` values from the outbox and deduplicate at the application boundary.
- Keep integration helpers local to the application; the examples are copy-paste references, not a supported package.

## Endpoints

| Purpose | Path | Notes |
| --- | --- | --- |
| WebSocket, SDK default | `/realtime/v1/connection/websocket` | Primary client path. Supabase Realtime keeps `/realtime/v1/websocket`. |
| WebSocket, alias | `/centrifugo/v1/connection/websocket` | Equivalent alias for explicit Centrifugo integrations. |
| Connection token | `/centrifugo/v1/auth/token` | `POST` with the anon or publishable key in `apikey`; add `Authorization: Bearer <Supabase access token>` for a user connection. |
| Internal publish API | `/centrifugo/v1/api/publish` | Server-only, `X-API-Key`. Never ship this key in a client. |

Convert the HTTP base URL to `ws://` or `wss://` before constructing the SDK endpoint. Both WebSocket paths return the `centrifuge-json` subprotocol.

## Connection Token

The client must call the token endpoint for the initial connection and whenever the SDK invokes its token callback. A token response contains:

```json
{
  "token": "<jwt>",
  "token_type": "Bearer",
  "expires_in": 900,
  "expires_at": 1793718000
}
```

Rules:

- Send the anon or publishable key, never the service-role key.
- Send the current Supabase access token when the user is signed in.
- Treat `401`, `403`, and `service_key_not_allowed` as terminal for the current credentials. Do not retry with the same key.
- Treat `429` as retryable after `Retry-After`.
- Never log the access token, connection token, API key, or full token response.
- On `109` (token expired), let the SDK call the token callback and reconnect. Do not open a parallel connection.

## Connection States

| State | Meaning | App action |
| --- | --- | --- |
| `disconnected` | No active transport. | Show offline; call `connect()` when the app is active and credentials exist. |
| `connecting` | Initial connect or automatic reconnect. | Keep subscriptions registered; show reconnecting. |
| `connected` | Transport and token accepted. | Expect subscriptions to move to `subscribed`. |
| `closed` | Client was explicitly closed and cannot reconnect. | Create a new client before reconnecting. |

Mobile apps should call `disconnect()` when the app moves to the background and `connect()` when it returns to the foreground. Call `close()` when the screen or session is destroyed.

## Channel Lifecycle

| State | Meaning | App action |
| --- | --- | --- |
| `unsubscribed` | No subscription on the server. | Call `subscribe()` when the screen needs the channel. |
| `subscribing` | Subscribe command in flight, or retrying after an error/reconnect. | Do not issue a second subscribe; wait for `subscribed` or `error`. |
| `subscribed` | Publications are flowing. | Read `recovered`; reload authoritative state if recovery was incomplete. |
| `error` | Subscribe failed. | Map the code; keep the subscription only for retryable errors. |

Subscribe errors are terminal for that attempt but the SDK may retry temporary failures. A `403` is an authorization failure; do not retry it without changing credentials or channel.

## Channel Names

Channel names are constructed by the application; the server validates them.

| Namespace | Format | Access |
| --- | --- | --- |
| `public` | `public:<name>` | Authenticated or anonymous subscribe. Publishing requires an authenticated user. |
| `user` | `user:<user_uuid>` | Only that user. |
| `tenant` | `tenant:<tenant_uuid>[:<segment>...]` | A user whose server-controlled tenant claim matches. At most four segments, each 1-64 characters. |

`public` names cannot contain `:`. `private:` and Supabase Realtime topic names are not translated automatically. Build an explicit mapping in the migration.

## Event Shapes

### Publication

```json
{
  "channel": "tenant:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:table:messages",
  "data": { "event": "insert", "message_id": "..." },
  "offset": 42,
  "tags": {},
  "info": { "client": "...", "user": "..." }
}
```

`data` is application data. Client publishes must be JSON objects and are limited to 16 KiB. `offset`, `tags`, and `info` are present only when the server sends them.

### Postgres Change Event

Notification-only payloads are the default:

```json
{
  "event": "insert",
  "schema": "public",
  "table": "messages",
  "tenant_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "occurred_at": "2026-11-03T12:00:00.000Z",
  "message_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
}
```

Full-row payloads add `record` for inserts/updates and `old_record` for updates when the table is explicitly allowlisted. There is no WAL CDC, no old-record replay, and no exact RLS row filtering. Treat the event as a notification and reload authoritative data when the payload is incomplete.

### Join and Leave

Join and leave pushes carry `channel` and `info` with `client`, `user`, `connInfo`, and `chanInfo`. Join/leave is enabled per subscription with `joinLeave: true` / `setJoinLeave(true)` and is not forced on large channels.

### Presence and History

- Presence returns a map of client IDs to client info.
- History returns ordered publications plus `offset` and `epoch`.
- Anonymous clients cannot read presence or history.
- History is a bounded cache: 100 publications for 300 seconds by default. On Redis restart, subscriptions receive `unsubscribe` code `2500`; resubscribe and recover, or reload state if recovery is unavailable.

## Error Mapping

| Code | Meaning | Action |
| --- | --- | --- |
| `403` | Subscribe or publish denied. | Do not retry without a credentials or channel change. Show an authorization error. |
| `429` | Publish or token endpoint rate limit. | Retry after `Retry-After`; add jitter. |
| `109` | Connection token expired. | Refresh through the token callback. |
| `3500` | Invalid connection token. | Fetch a new token; if it fails, sign the user out or use an anonymous token. |
| `2500` | Server invalidated subscription state, including Redis restart. | Resubscribe; if recovery is unavailable, reload state. |
| `3014` | Server invalidated connection state. | Refresh the token and reconnect. |
| `112` | Unrecoverable history position. | Reload state and subscribe from the new position. |
| `103` | Permission or availability error from the SDK. | Treat like `403` for authorization; check the message. |

## Reconnect and Recovery

- The SDK reconnects automatically with backoff and jitter. Do not add a second reconnect loop.
- Client-side subscriptions retain their stream position across a temporary disconnect. On `subscribed`, check `recovered`.
- If `recovered` is `false` or the subscribe fails with `112`, reload authoritative state before processing new publications.
- Deduplicate by `data.message_id` when present, otherwise by publication `offset` when available. Keep a bounded, time-limited set so reconnects and overlapping recovery do not replay the same event twice.
- Outbox publications carry `message_id`; client publishes may not. A server-side publish can be retried by the outbox with the same `message_id`.

## Security

- Never use the service-role key or the Centrifugo API key in a client.
- Never bypass channel authorization because the UI needs data; load data through the application API instead.
- Do not log tokens or claims. Log channel names, error codes, and retry reasons only.
- Treat full-row change payloads as tenant-visible data. Opt in only after a privacy review.
