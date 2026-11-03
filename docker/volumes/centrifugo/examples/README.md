# Client Examples

These are reference integrations for the official Centrifugo SDKs. They are not published packages and do not define a Supabase-compatible SDK.

- `js/` uses `centrifuge@5.8.0`.
- `kotlin/` uses `io.github.centrifugal:centrifuge-java:0.8.0`.

Both examples implement the shared behavior in [../CLIENT_CONTRACT.md](../CLIENT_CONTRACT.md) and the migration mapping in [../CLIENT_MIGRATION.md](../CLIENT_MIGRATION.md): token retrieval, channel construction, reconnect/recovery handling, and `message_id` deduplication.

## JavaScript

```sh
cd examples/js
npm ci
SUPABASE_URL=https://PROJECT.supabase.co \
SUPABASE_ANON_KEY=... \
SUPABASE_ACCESS_TOKEN=... \
CENTRIFUGO_TENANT_ID=... \
node basic.mjs
```

The conformance runner uses a server API publication so it can be run without enabling client publish:

```sh
SUPABASE_URL=https://PROJECT.supabase.co \
SUPABASE_ANON_KEY=... \
SUPABASE_ACCESS_TOKEN=... \
CENTRIFUGO_API_KEY=... \
CENTRIFUGO_TEST_CHANNEL=tenant:...:table:conformance \
node conformance.mjs
```

## Kotlin/Android

The example targets the JVM for local verification and uses Android-compatible dependencies. In an Android app, add the official dependency and use the same token callback and subscription options:

```kotlin
implementation("io.github.centrifugal:centrifuge-java:0.8.0")
```

Build and run the local conformance example with the JDK and Kotlin from Nix:

```sh
nix shell nixpkgs#jdk21 nixpkgs#kotlin -c bash examples/kotlin/build.sh
java -cp examples/kotlin/build/conformance.jar:examples/kotlin/build/deps/* \
  io.supabase.centrifugo.examples.ConformanceKt
```

Set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_ACCESS_TOKEN`, `CENTRIFUGO_API_KEY`, `CENTRIFUGO_TEST_CHANNEL`, and optionally `CENTRIFUGO_WS_PATH` before running.

## Cross-SDK test

From `docker/`:

```sh
sh tests/test-centrifugo-clients.sh
```

The test runs both SDKs against `/realtime/v1/connection/websocket` and `/centrifugo/v1/connection/websocket`. It skips when the Centrifugo container is not running.
