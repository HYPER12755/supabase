#!/bin/sh
set -eu

DOCKER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$DOCKER_DIR/.." && pwd)"

if [ ! -f "$DOCKER_DIR/.env" ]; then
    echo "Error: .env file not found. Run from the project directory."
    exit 1
fi
if [ ! -f "$DOCKER_DIR/.env.centrifugo" ]; then
    echo "Error: .env.centrifugo file not found. Enable the Centrifugo overlay first."
    exit 1
fi
for cmd in curl jq node npm docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found."
        exit 1
    fi
done

read_env() {
    grep "^$1=" "$DOCKER_DIR/.env" | head -n 1 | cut -d= -f2- | tr -d '\r'
}

read_centrifugo_env() {
    grep "^$1=" "$DOCKER_DIR/.env.centrifugo" | head -n 1 | cut -d= -f2- | tr -d '\r'
}

unquote() {
    value="$1"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
    esac
    printf '%s' "$value"
}

BASE_URL="${1:-}"
if [ -z "$BASE_URL" ]; then
    api_external_url=$(unquote "$(read_env API_EXTERNAL_URL)")
    api_external_url="${api_external_url%/}"
    BASE_URL="${api_external_url%/auth/v1}"
fi
if [ -z "$BASE_URL" ]; then
    BASE_URL=$(unquote "$(read_env SUPABASE_PUBLIC_URL)")
    BASE_URL="${BASE_URL%/}"
fi
ANON_KEY=$(unquote "$(read_env ANON_KEY)")
SERVICE_ROLE_KEY=$(unquote "$(read_env SERVICE_ROLE_KEY)")
CENTRIFUGO_HTTP_API_KEY=$(unquote "$(read_centrifugo_env CENTRIFUGO_HTTP_API_KEY)")

if [ -z "$BASE_URL" ] || [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ]; then
    echo "Error: required keys or URLs are missing from .env or .env.centrifugo."
    exit 1
fi

if ! docker inspect supabase-centrifugo >/dev/null 2>&1; then
    echo "SKIP: supabase-centrifugo is not running."
    exit 0
fi

TEST_PASSWORD="centrifugo-clients-password-123456"
TENANT_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
USER_ID=""
RUN="$$-$(date +%s)"
CHANNEL_PREFIX="tenant:$TENANT_ID:table:clients-$RUN"
JS_DIR="$REPO_ROOT/docker/volumes/centrifugo/examples/js"
KOTLIN_DIR="$REPO_ROOT/docker/volumes/centrifugo/examples/kotlin"
KOTLIN_JAR="$KOTLIN_DIR/build/conformance.jar"
KOTLIN_DEPS="$KOTLIN_DIR/build/deps"

pass=0
fail=0

check() {
    test_name="$1"
    expected="$2"
    actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $test_name"
        pass=$((pass + 1))
    else
        echo "  FAIL: $test_name (expected $expected, got ${actual:-empty})"
        fail=$((fail + 1))
    fi
}

cleanup() {
    if [ -n "$USER_ID" ]; then
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$USER_ID" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    fi
}
trap cleanup EXIT HUP INT TERM

USER_RESPONSE=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/admin/users" \
    -X POST \
    -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"centrifugo-clients-$RUN@example.com\",\"password\":\"$TEST_PASSWORD\",\"email_confirm\":true,\"app_metadata\":{\"tenant_id\":\"$TENANT_ID\"}}")
USER_ID=$(printf '%s' "$USER_RESPONSE" | jq -r '.id // empty' 2>/dev/null || true)
if [ -z "$USER_ID" ]; then
    echo "Error: could not create test user."
    printf '%s\n' "$USER_RESPONSE"
    exit 1
fi

SESSION=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"centrifugo-clients-$RUN@example.com\",\"password\":\"$TEST_PASSWORD\"}")
ACCESS_TOKEN=$(printf '%s' "$SESSION" | jq -r '.access_token // empty' 2>/dev/null || true)
if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: could not log in test user."
    printf '%s\n' "$SESSION"
    exit 1
fi

echo ""
echo "=== Centrifugo client conformance against $BASE_URL ==="
echo ""

if [ ! -d "$JS_DIR/node_modules" ]; then
    (cd "$JS_DIR" && npm ci --no-audit --no-fund >/dev/null)
fi

if (cd "$JS_DIR" && npm test >/dev/null 2>&1); then
    check "JS client unit tests" "ok" "ok"
else
    check "JS client unit tests" "ok" "failed"
    (cd "$JS_DIR" && npm test) || true
fi

run_js() {
    path="$1"
    channel="$CHANNEL_PREFIX-js-$2"
    output=$(cd "$JS_DIR" && \
        SUPABASE_URL="$BASE_URL" \
        SUPABASE_ANON_KEY="$ANON_KEY" \
        SUPABASE_ACCESS_TOKEN="$ACCESS_TOKEN" \
        CENTRIFUGO_API_KEY="$CENTRIFUGO_HTTP_API_KEY" \
        CENTRIFUGO_TEST_CHANNEL="$channel" \
        CENTRIFUGO_WS_PATH="$path" \
        node conformance.mjs 2>&1) || true
    if printf '%s' "$output" | grep -q '^CONFORMANCE_OK '; then
        check "JS $path" "ok" "ok"
        printf '%s\n' "$output" | grep '^CONFORMANCE_OK ' || true
    else
        check "JS $path" "ok" "failed"
        printf '%s\n' "$output"
    fi
}

build_kotlin() {
    if command -v kotlinc >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
        bash "$KOTLIN_DIR/build.sh" >/dev/null
    elif command -v nix >/dev/null 2>&1; then
        nix shell nixpkgs#jdk21 nixpkgs#kotlin -c bash "$KOTLIN_DIR/build.sh" >/dev/null
    else
        return 1
    fi
}

run_kotlin_self_test() {
    if command -v java >/dev/null 2>&1; then
        output=$(java -cp "$KOTLIN_JAR:$KOTLIN_DEPS/*" io.supabase.centrifugo.examples.SelfTestKt 2>&1) || true
    else
        output=$(nix shell nixpkgs#jdk21 -c env java -cp "$KOTLIN_JAR:$KOTLIN_DEPS/*" io.supabase.centrifugo.examples.SelfTestKt 2>&1) || true
    fi
    if printf '%s' "$output" | grep -q '^KOTLIN_CLIENT_SELF_TEST_OK$'; then
        check "Kotlin client self-test" "ok" "ok"
    else
        check "Kotlin client self-test" "ok" "failed"
        printf '%s\n' "$output"
    fi
}

run_kotlin() {
    path="$1"
    channel="$CHANNEL_PREFIX-kotlin-$2"
    if command -v java >/dev/null 2>&1; then
        output=$(env \
            SUPABASE_URL="$BASE_URL" \
            SUPABASE_ANON_KEY="$ANON_KEY" \
            SUPABASE_ACCESS_TOKEN="$ACCESS_TOKEN" \
            CENTRIFUGO_API_KEY="$CENTRIFUGO_HTTP_API_KEY" \
            CENTRIFUGO_TEST_CHANNEL="$channel" \
            CENTRIFUGO_WS_PATH="$path" \
            java -cp "$KOTLIN_JAR:$KOTLIN_DEPS/*" io.supabase.centrifugo.examples.ConformanceKt 2>&1) || true
    else
        output=$(nix shell nixpkgs#jdk21 -c env \
            SUPABASE_URL="$BASE_URL" \
            SUPABASE_ANON_KEY="$ANON_KEY" \
            SUPABASE_ACCESS_TOKEN="$ACCESS_TOKEN" \
            CENTRIFUGO_API_KEY="$CENTRIFUGO_HTTP_API_KEY" \
            CENTRIFUGO_TEST_CHANNEL="$channel" \
            CENTRIFUGO_WS_PATH="$path" \
            java -cp "$KOTLIN_JAR:$KOTLIN_DEPS/*" io.supabase.centrifugo.examples.ConformanceKt 2>&1) || true
    fi
    if printf '%s' "$output" | grep -q '^CONFORMANCE_OK '; then
        check "Kotlin $path" "ok" "ok"
        printf '%s\n' "$output" | grep '^CONFORMANCE_OK ' || true
    else
        check "Kotlin $path" "ok" "failed"
        printf '%s\n' "$output"
    fi
}

kotlin_built=0
if build_kotlin; then
    check "Kotlin client builds" "ok" "ok"
    kotlin_built=1
else
    check "Kotlin client builds" "ok" "toolchain unavailable"
fi

run_js "/realtime/v1/connection/websocket" "realtime"
run_js "/centrifugo/v1/connection/websocket" "centrifugo"

if [ "$kotlin_built" -eq 1 ]; then
    run_kotlin_self_test
    run_kotlin "/realtime/v1/connection/websocket" "realtime"
    run_kotlin "/centrifugo/v1/connection/websocket" "centrifugo"
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
