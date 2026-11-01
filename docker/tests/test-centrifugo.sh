#!/bin/sh
#
# Test the Centrifugo gateway contract against a running self-hosted instance.
#
# Usage:
#   sh test-centrifugo.sh              # Uses http://localhost:8000
#   sh test-centrifugo.sh <base_url>   # Custom URL
#
# Prerequisites:
#   - Running self-hosted Supabase instance with the Centrifugo overlay
#   - Envoy or Kong gateway active
#   - .env and .env.centrifugo in the project directory
#   - curl
#   - node >= 16 (for the Supabase Realtime WebSocket assertion)
#

set -e

BASE_URL="${1:-http://localhost:8000}"

if [ ! -f .env ]; then
    echo "Error: .env file not found. Run from the project directory."
    exit 1
fi

if [ ! -f .env.centrifugo ]; then
    echo "Error: .env.centrifugo file not found. Enable the Centrifugo overlay first."
    exit 1
fi

for cmd in curl node; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found."
        exit 1
    fi
done

ANON_KEY=$(grep '^ANON_KEY=' .env | cut -d= -f2-)
CENTRIFUGO_HTTP_API_KEY=$(grep '^CENTRIFUGO_HTTP_API_KEY=' .env.centrifugo | cut -d= -f2-)
CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY=$(grep '^CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY=' .env.centrifugo | cut -d= -f2-)

if [ -z "$ANON_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ] || [ -z "$CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY" ]; then
    echo "Error: required keys are missing from .env or .env.centrifugo."
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
WS_HEADERS="$TMP_DIR/ws-headers"

pass=0
fail=0

check() {
    test_name="$1"
    expected="$2"
    actual="$3"

    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $test_name ($actual)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $test_name (expected $expected, got ${actual:-empty})"
        fail=$((fail + 1))
    fi
}

http_status() {
    url="$1"
    shift
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$@" "$url" || true
}

ws_status() {
    url="$1"
    origin="$2"
    curl -s -o /dev/null -D "$WS_HEADERS" -w "%{http_code}" --max-time 2 \
        -H "Origin: $origin" \
        -H 'Upgrade: websocket' \
        -H 'Connection: Upgrade' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H 'Sec-WebSocket-Protocol: centrifuge-json' \
        "$url" || true
}

ws_protocol() {
    awk 'tolower($1) == "sec-websocket-protocol:" { gsub("\r", "", $2); print $2 }' "$WS_HEADERS" | tail -n 1
}

check_cors_origin() {
    test_name="$1"
    actual="$2"

    case "$actual" in
        "http://localhost:3000"|"*")
            check "$test_name" "origin or wildcard" "origin or wildcard"
            ;;
        *)
            check "$test_name" "origin or wildcard" "$actual"
            ;;
    esac
}

check_ws() {
    test_name="$1"
    path="$2"
    origin="${3:-http://localhost:3000}"

    code=$(ws_status "$BASE_URL$path" "$origin")
    check "$test_name -> 101" "101" "$code"

    if [ "$code" = "101" ]; then
        check "$test_name protocol" "centrifuge-json" "$(ws_protocol)"
    fi
}

echo ""
echo "=== Centrifugo gateway tests against $BASE_URL ==="
echo ""

echo "--- Health ---"
check "health without basic auth -> 200" "200" \
    "$(http_status "$BASE_URL/centrifugo/v1/health")"
check "health body" "{}" \
    "$(curl -s --max-time 5 "$BASE_URL/centrifugo/v1/health")"

echo ""
echo "--- WebSocket routes ---"
check_ws "primary WebSocket" "/centrifugo/v1/connection/websocket"
check_ws "WebSocket alias" "/centrifugo/v1/websocket"
check_ws "reserved Realtime alias" "/realtime/v1/connection/websocket"
check "disallowed WebSocket origin -> 403" "403" \
    "$(ws_status "$BASE_URL/centrifugo/v1/websocket" "https://evil.example")"

echo ""
echo "--- Centrifugo connect ---"
connect_result=$(BASE_URL="$BASE_URL" TOKEN_SECRET="$CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY" node - <<'NODE'
const crypto = require('crypto')

const base = new URL(process.env.BASE_URL)
const url = new URL('/centrifugo/v1/connection/websocket', base)
url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'

const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
const header = encode({ alg: 'HS256', typ: 'JWT' })
const payload = encode({
  sub: 'centrifugo-gateway-test',
  exp: Math.floor(Date.now() / 1000) + 60,
})
const unsigned = `${header}.${payload}`
const signature = crypto
  .createHmac('sha256', process.env.TOKEN_SECRET)
  .update(unsigned)
  .digest('base64url')
const token = `${unsigned}.${signature}`

const ws = new WebSocket(url, 'centrifuge-json')
const timer = setTimeout(() => process.exit(1), 5000)

ws.addEventListener('open', () => {
  ws.send(JSON.stringify({ id: 1, connect: { token } }))
})

ws.addEventListener('message', (event) => {
  const message = JSON.parse(String(event.data))
  if (message.id === 1 && message.connect && message.connect.client) {
    clearTimeout(timer)
    console.log('connected')
    ws.close()
    process.exit(0)
  }
  if (message.id === 1 && message.error) {
    clearTimeout(timer)
    process.exit(1)
  }
})

ws.addEventListener('error', () => process.exit(1))
NODE
) || connect_result="connect-failed"
check "WebSocket connect -> connect result" "connected" "$connect_result"

echo ""
echo "--- Supabase Realtime regression ---"
check "/realtime/v1/websocket without key -> 401" "401" \
    "$(http_status "$BASE_URL/realtime/v1/websocket")"
check "/realtime/v1/api/ping with key -> 200" "200" \
    "$(http_status "$BASE_URL/realtime/v1/api/ping" -H "apikey: $ANON_KEY")"
check "/realtime/v1/api/tenants blocked -> 403" "403" \
    "$(http_status "$BASE_URL/realtime/v1/api/tenants" -H "apikey: $ANON_KEY")"
check "/realtime/v1/api/openapi blocked -> 403" "403" \
    "$(http_status "$BASE_URL/realtime/v1/api/openapi" -H "apikey: $ANON_KEY")"

realtime_result=$(BASE_URL="$BASE_URL" ANON_KEY="$ANON_KEY" node - <<'NODE'
const base = new URL(process.env.BASE_URL)
const url = new URL('/realtime/v1/websocket', base)
url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
url.searchParams.set('apikey', process.env.ANON_KEY)
url.searchParams.set('vsn', '1.0.0')

const ws = new WebSocket(url)
const timer = setTimeout(() => process.exit(1), 5000)

ws.addEventListener('open', () => {
  ws.send(JSON.stringify({
    topic: 'realtime:centrifugo-gateway-test',
    event: 'phx_join',
    payload: {},
    ref: '1',
  }))
})

ws.addEventListener('message', (event) => {
  if (String(event.data).includes('phx_reply')) {
    clearTimeout(timer)
    console.log('phx_reply')
    ws.close()
    process.exit(0)
  }
})

ws.addEventListener('error', () => process.exit(1))
NODE
) || realtime_result="node-failed"
check "/realtime/v1/websocket remains Supabase Realtime" "phx_reply" "$realtime_result"

echo ""
echo "--- Centrifugo HTTP API ---"
check "API without key -> 401" "401" \
    "$(http_status "$BASE_URL/centrifugo/v1/api/publish" \
        -X POST -H 'Content-Type: application/json' -d '{}')"
check "API with invalid key -> 401" "401" \
    "$(http_status "$BASE_URL/centrifugo/v1/api/publish" \
        -X POST -H 'X-API-Key: invalid-key' -H 'Content-Type: application/json' -d '{}')"

api_result=$(curl -s -w '\n%{http_code}' --max-time 5 \
    -X POST \
    -H "X-API-Key: $CENTRIFUGO_HTTP_API_KEY" \
    -H 'Content-Type: application/json' \
    -d '{"channel":"tenant:centrifugo-gateway-test","data":{"ok":true}}' \
    "$BASE_URL/centrifugo/v1/api/publish" || true)
api_code=$(printf '%s\n' "$api_result" | tail -n 1)
api_body=$(printf '%s\n' "$api_result" | sed '$d')
check "API with key -> 200" "200" "$api_code"
check "API publish result" '{"result":{}}' "$api_body"

echo ""
echo "--- Auth token CORS ---"
check "token preflight -> 200" "200" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token" \
        -X OPTIONS \
        -H 'Origin: http://localhost:3000' \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: authorization,apikey,content-type')"
cors_origin=$(curl -s -D - -o /dev/null --max-time 5 \
    -X OPTIONS \
    -H 'Origin: http://localhost:3000' \
    -H 'Access-Control-Request-Method: POST' \
    "$BASE_URL/centrifugo/v1/auth/token" \
    | awk 'tolower($1) == "access-control-allow-origin:" { gsub("\r", "", $2); print $2 }' | tail -n 1 || true)
check_cors_origin "token allow-origin" "$cors_origin"
check "token service pending -> 503" "503" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token")"

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
