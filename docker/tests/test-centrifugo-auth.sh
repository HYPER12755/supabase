#!/bin/sh
set -eu

AUTH_CONTAINER="supabase-centrifugo-auth"

if [ ! -f .env ]; then
    echo "Error: .env file not found. Run from the project directory."
    exit 1
fi
if [ ! -f .env.centrifugo ]; then
    echo "Error: .env.centrifugo file not found. Enable the Centrifugo overlay first."
    exit 1
fi
for cmd in curl jq node docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found."
        exit 1
    fi
done

read_env() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2- | tr -d '\r'
}

unquote() {
    value="$1"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
    esac
    printf '%s' "$value"
}

BASE_URL="${1:-}"
SITE_URL=$(unquote "$(read_env SITE_URL)")
SITE_URL="${SITE_URL%/}"
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
SUPABASE_PUBLISHABLE_KEY=$(unquote "$(read_env SUPABASE_PUBLISHABLE_KEY)")
SERVICE_ROLE_KEY=$(unquote "$(read_env SERVICE_ROLE_KEY)")
JWT_SECRET=$(unquote "$(read_env JWT_SECRET)")

if [ -z "$ANON_KEY" ] || [ -z "$SUPABASE_PUBLISHABLE_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$JWT_SECRET" ]; then
    echo "Error: required keys are missing from .env."
    exit 1
fi
if [ -z "$BASE_URL" ] || [ -z "$SITE_URL" ]; then
    echo "Error: set API_EXTERNAL_URL or SUPABASE_PUBLIC_URL, and SITE_URL, in .env or pass a base URL."
    exit 1
fi
DISALLOWED_ORIGIN=$(SITE_URL="$SITE_URL" node -e 'const url = new URL(process.env.SITE_URL); url.host = "disallowed.invalid"; process.stdout.write(url.origin)')

if ! docker inspect "$AUTH_CONTAINER" >/dev/null 2>&1; then
    echo "SKIP: $AUTH_CONTAINER is not running."
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
TEST_EMAIL="centrifugo-auth-$$@example.com"
TEST_PASSWORD="centrifugo-auth-password-123456"
TENANT_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER_TENANT_ID="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
OTHER_USER_ID="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
TEST_USER_ID=""

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
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$@" "$url" || true
}

token_request() {
    api_key="$1"
    bearer="${2:-}"
    output_file="$3"

    if [ -n "$bearer" ]; then
        curl -s -o "$output_file" -w "%{http_code}" --max-time 10 \
            -X POST \
            -H "apikey: $api_key" \
            -H "Authorization: Bearer $bearer" \
            "$BASE_URL/centrifugo/v1/auth/token" || true
    else
        curl -s -o "$output_file" -w "%{http_code}" --max-time 10 \
            -X POST \
            -H "apikey: $api_key" \
            "$BASE_URL/centrifugo/v1/auth/token" || true
    fi
}

cleanup_user() {
    if [ -n "$TEST_USER_ID" ]; then
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$TEST_USER_ID" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    fi
}
trap 'cleanup_user; rm -rf "$TMP_DIR"' EXIT HUP INT TERM

echo ""
echo "=== Centrifugo auth tests against $BASE_URL ==="
echo ""

echo "--- Container health ---"
check "auth container health" "healthy" \
    "$(docker inspect --format '{{.State.Health.Status}}' "$AUTH_CONTAINER" 2>/dev/null || echo missing)"

echo ""
echo "--- Token endpoint ---"
anon_code=$(token_request "$ANON_KEY" "" "$TMP_DIR/anon.json")
check "legacy anon key -> 200" "200" "$anon_code"
anon_token=$(jq -r '.token // empty' "$TMP_DIR/anon.json" 2>/dev/null)
check "anonymous token has empty sub" "" \
    "$(TOKEN="$anon_token" node -e 'const p=JSON.parse(Buffer.from(process.env.TOKEN.split(".")[1],"base64url"));process.stdout.write(p.sub)' 2>/dev/null || echo missing)"
check "anonymous token has short expiry" "true" \
    "$(TOKEN="$anon_token" node -e 'const p=JSON.parse(Buffer.from(process.env.TOKEN.split(".")[1],"base64url"));process.stdout.write(String(p.exp>p.iat&&p.exp-p.iat<=3600))' 2>/dev/null || echo false)"

sleep 1
refresh_code=$(token_request "$ANON_KEY" "" "$TMP_DIR/anon-refresh.json")
anon_refresh_token=$(jq -r '.token // empty' "$TMP_DIR/anon-refresh.json" 2>/dev/null)
check "token refresh -> 200" "200" "$refresh_code"
check "token refresh issues a new token" "true" \
    "$([ -n "$anon_refresh_token" ] && [ "$anon_refresh_token" != "$anon_token" ] && echo true || echo false)"

publishable_code=$(token_request "$SUPABASE_PUBLISHABLE_KEY" "" "$TMP_DIR/publishable.json")
check "publishable key -> 200" "200" "$publishable_code"
check "no apikey -> 401" "401" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X POST)"
check "invalid apikey -> 401" "401" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X POST -H 'apikey: invalid-key')"
check "service-role apikey -> 403" "403" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X POST -H "apikey: $SERVICE_ROLE_KEY")"
check "anon bearer with anon apikey -> 200" "200" \
    "$(token_request "$ANON_KEY" "$ANON_KEY" "$TMP_DIR/anon-bearer.json")"

echo ""
echo "--- User session ---"
create_response=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/admin/users" \
    -X POST \
    -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"email_confirm\":true,\"app_metadata\":{\"tenant_id\":\"$TENANT_ID\"}}")
TEST_USER_ID=$(printf '%s' "$create_response" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$TEST_USER_ID" ]; then
    check "create test user" "created" "failed"
else
    check "create test user" "created" "created"
fi

session_response=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
ACCESS_TOKEN=$(printf '%s' "$session_response" | jq -r '.access_token // empty' 2>/dev/null)

if [ -n "$ACCESS_TOKEN" ] && [ -n "$TEST_USER_ID" ]; then
    user_code=$(token_request "$ANON_KEY" "$ACCESS_TOKEN" "$TMP_DIR/user.json")
    check "user session -> 200" "200" "$user_code"
    user_token=$(jq -r '.token // empty' "$TMP_DIR/user.json" 2>/dev/null)
    check "user token sub" "$TEST_USER_ID" \
        "$(TOKEN="$user_token" node -e 'const p=JSON.parse(Buffer.from(process.env.TOKEN.split(".")[1],"base64url"));process.stdout.write(p.sub)' 2>/dev/null || echo missing)"
    check "user token role" "authenticated" \
        "$(TOKEN="$user_token" node -e 'const p=JSON.parse(Buffer.from(process.env.TOKEN.split(".")[1],"base64url"));process.stdout.write(p.info.role)' 2>/dev/null || echo missing)"
    check "user token tenant" "$TENANT_ID" \
        "$(TOKEN="$user_token" node -e 'const p=JSON.parse(Buffer.from(process.env.TOKEN.split(".")[1],"base64url"));process.stdout.write(p.meta.tenant_id||"")' 2>/dev/null || echo missing)"

    publishable_user_code=$(token_request "$SUPABASE_PUBLISHABLE_KEY" "$ACCESS_TOKEN" "$TMP_DIR/publishable-user.json")
    check "publishable + user session -> 200" "200" "$publishable_user_code"

    check "service-role bearer -> 403" "403" \
        "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X POST \
            -H "apikey: $ANON_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY")"
    check "user bearer without apikey -> 401" "401" \
        "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X POST \
            -H "Authorization: Bearer $ACCESS_TOKEN")"

    expired_token=$(JWT_SECRET="$JWT_SECRET" USER_ID="$TEST_USER_ID" node -e '
      const crypto = require("crypto");
      const enc = (v) => Buffer.from(JSON.stringify(v)).toString("base64url");
      const now = Math.floor(Date.now()/1000);
      const unsigned = enc({alg:"HS256",typ:"JWT"}) + "." + enc({iss:"supabase",aud:"authenticated",role:"authenticated",sub:process.env.USER_ID,iat:now-240,exp:now-120});
      process.stdout.write(unsigned + "." + crypto.createHmac("sha256", process.env.JWT_SECRET).update(unsigned).digest("base64url"));
    ' 2>/dev/null || true)
    check "expired HS256 token -> 401" "401" \
        "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X POST \
            -H "apikey: $ANON_KEY" \
            -H "Authorization: Bearer $expired_token")"
else
    check "user session setup" "complete" "failed"
    user_token=""
fi

echo ""
echo "--- CORS ---"
check "allowed preflight -> 204" "204" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X OPTIONS \
        -H "Origin: $SITE_URL" \
        -H 'Access-Control-Request-Method: POST')"
check "allowed origin header" "$SITE_URL" \
    "$(curl -s -D - -o /dev/null --max-time 10 \
        -X OPTIONS \
        -H "Origin: $SITE_URL" \
        -H 'Access-Control-Request-Method: POST' \
        "$BASE_URL/centrifugo/v1/auth/token" \
        | awk 'tolower($1) == "access-control-allow-origin:" { gsub("\r", "", $2); print $2 }' | tail -n 1 || true)"
check "disallowed preflight -> 403" "403" \
    "$(http_status "$BASE_URL/centrifugo/v1/auth/token" -X OPTIONS \
        -H "Origin: $DISALLOWED_ORIGIN" \
        -H 'Access-Control-Request-Method: POST')"

echo ""
echo "--- Channel authorization ---"
if [ -n "$user_token" ] && [ -n "$ACCESS_TOKEN" ]; then
    user_ws=$(TOKEN="$user_token" BASE_URL="$BASE_URL" TENANT="$TENANT_ID" OTHER_TENANT="$OTHER_TENANT_ID" USER_ID="$TEST_USER_ID" OTHER_USER="$OTHER_USER_ID" node - <<'NODE'
const wsUrl = new URL('/centrifugo/v1/connection/websocket', process.env.BASE_URL)
wsUrl.protocol = wsUrl.protocol === 'https:' ? 'wss:' : 'ws:'
const ws = new WebSocket(wsUrl, 'centrifuge-json')
const timer = setTimeout(() => process.exit(1), 10000)
let nextId = 1
const pending = new Map()

function parseMessages(raw) {
  const messages = []
  let depth = 0
  let start = -1
  let inString = false
  let escaped = false
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i]
    if (inString) {
      if (escaped) escaped = false
      else if (ch === '\\') escaped = true
      else if (ch === '"') inString = false
      continue
    }
    if (ch === '"') { inString = true; continue }
    if (ch === '{') { if (depth === 0) start = i; depth += 1 }
    if (ch === '}') {
      depth -= 1
      if (depth === 0 && start >= 0) {
        messages.push(JSON.parse(raw.slice(start, i + 1)))
        start = -1
      }
    }
  }
  return messages
}

function send(command) {
  const id = nextId++
  ws.send(JSON.stringify({ id, ...command }))
  return new Promise((resolve) => pending.set(id, resolve))
}

ws.addEventListener('message', (event) => {
  for (const message of parseMessages(String(event.data))) {
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message)
      pending.delete(message.id)
    }
  }
})

ws.addEventListener('open', async () => {
  const result = {}
  const connect = await send({ connect: { token: process.env.TOKEN } })
  result.connect = Boolean(connect.connect)
  if (!result.connect) { clearTimeout(timer); process.stdout.write(JSON.stringify(result)); process.exit(0) }
  const tenant = await send({ subscribe: { channel: `tenant:${process.env.TENANT}:table:messages` } })
  result.tenant = Boolean(tenant.subscribe && !tenant.error)
  const tenantDenied = await send({ subscribe: { channel: `tenant:${process.env.OTHER_TENANT}:table:messages` } })
  result.tenantDenied = Boolean(tenantDenied.error && tenantDenied.error.code === 403)
  const userSelf = await send({ subscribe: { channel: `user:${process.env.USER_ID}` } })
  result.userSelf = Boolean(userSelf.subscribe && !userSelf.error)
  const userDenied = await send({ subscribe: { channel: `user:${process.env.OTHER_USER}` } })
  result.userDenied = Boolean(userDenied.error && userDenied.error.code === 403)
  const malformed = await send({ subscribe: { channel: 'tenant:not-a-uuid' } })
  result.malformed = Boolean(malformed.error && malformed.error.code === 403)
  const publish = await send({ publish: { channel: 'public:phase3-publish', data: { ok: true } } })
  result.publish = Boolean(publish.publish && !publish.error)
  const publishDenied = await send({ publish: { channel: `tenant:${process.env.OTHER_TENANT}:table:messages`, data: { ok: true } } })
  result.publishDenied = Boolean(publishDenied.error && publishDenied.error.code === 403)
  const oversizedPublish = await send({ publish: { channel: 'public:phase3-publish', data: { value: 'x'.repeat(17000) } } })
  result.oversizedPublish = Boolean(oversizedPublish.error && oversizedPublish.error.code === 413)
  clearTimeout(timer)
  process.stdout.write(JSON.stringify(result))
  ws.close()
  process.exit(0)
})

ws.addEventListener('error', () => process.exit(1))
NODE
) || user_ws="failed"
    check "user connects" "true" "$(printf '%s' "$user_ws" | jq -r '.connect // false' 2>/dev/null || echo false)"
    check "tenant subscribe allowed" "true" "$(printf '%s' "$user_ws" | jq -r '.tenant // false' 2>/dev/null || echo false)"
    check "cross-tenant subscribe denied" "true" "$(printf '%s' "$user_ws" | jq -r '.tenantDenied // false' 2>/dev/null || echo false)"
    check "user self subscribe allowed" "true" "$(printf '%s' "$user_ws" | jq -r '.userSelf // false' 2>/dev/null || echo false)"
    check "other user subscribe denied" "true" "$(printf '%s' "$user_ws" | jq -r '.userDenied // false' 2>/dev/null || echo false)"
    check "malformed channel denied" "true" "$(printf '%s' "$user_ws" | jq -r '.malformed // false' 2>/dev/null || echo false)"
    check "authenticated public publish allowed" "true" "$(printf '%s' "$user_ws" | jq -r '.publish // false' 2>/dev/null || echo false)"
    check "cross-tenant publish denied" "true" "$(printf '%s' "$user_ws" | jq -r '.publishDenied // false' 2>/dev/null || echo false)"
    check "oversized publish denied" "true" "$(printf '%s' "$user_ws" | jq -r '.oversizedPublish // false' 2>/dev/null || echo false)"
else
    check "user channel authorization setup" "complete" "failed"
fi

anon_ws=$(TOKEN="$anon_token" BASE_URL="$BASE_URL" node - <<'NODE'
const wsUrl = new URL('/centrifugo/v1/connection/websocket', process.env.BASE_URL)
wsUrl.protocol = wsUrl.protocol === 'https:' ? 'wss:' : 'ws:'
const ws = new WebSocket(wsUrl, 'centrifuge-json')
const timer = setTimeout(() => process.exit(1), 10000)
let nextId = 1
const pending = new Map()

function send(command) {
  const id = nextId++
  ws.send(JSON.stringify({ id, ...command }))
  return new Promise((resolve) => pending.set(id, resolve))
}

function parseMessages(raw) {
  const messages = []
  let depth = 0
  let start = -1
  let inString = false
  let escaped = false
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i]
    if (inString) {
      if (escaped) escaped = false
      else if (ch === '\\') escaped = true
      else if (ch === '"') inString = false
      continue
    }
    if (ch === '"') { inString = true; continue }
    if (ch === '{') { if (depth === 0) start = i; depth += 1 }
    if (ch === '}') {
      depth -= 1
      if (depth === 0 && start >= 0) {
        messages.push(JSON.parse(raw.slice(start, i + 1)))
        start = -1
      }
    }
  }
  return messages
}

ws.addEventListener('message', (event) => {
  for (const message of parseMessages(String(event.data))) {
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message)
      pending.delete(message.id)
    }
  }
})

ws.addEventListener('open', async () => {
  const result = {}
  const connect = await send({ connect: { token: process.env.TOKEN } })
  result.connect = Boolean(connect.connect)
  const publicSubscribe = await send({ subscribe: { channel: 'public:phase3-anon' } })
  result.publicSubscribe = Boolean(publicSubscribe.subscribe && !publicSubscribe.error)
  const publicPublish = await send({ publish: { channel: 'public:phase3-anon', data: { ok: true } } })
  result.publicPublishDenied = Boolean(publicPublish.error && publicPublish.error.code === 403)
  clearTimeout(timer)
  process.stdout.write(JSON.stringify(result))
  ws.close()
  process.exit(0)
})

ws.addEventListener('error', () => process.exit(1))
NODE
) || anon_ws="failed"
check "anonymous connects" "true" "$(printf '%s' "$anon_ws" | jq -r '.connect // false' 2>/dev/null || echo false)"
check "anonymous public subscribe allowed" "true" "$(printf '%s' "$anon_ws" | jq -r '.publicSubscribe // false' 2>/dev/null || echo false)"
check "anonymous public publish denied" "true" "$(printf '%s' "$anon_ws" | jq -r '.publicPublishDenied // false' 2>/dev/null || echo false)"

echo ""
echo "--- Rate limits ---"
if [ -n "$user_token" ] && [ -n "$ACCESS_TOKEN" ]; then
    ip_code=""
    i=0
    while [ "$i" -lt 61 ]; do
        ip_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST \
            -H "apikey: $ANON_KEY" \
            -H "X-Forwarded-For: 198.51.100.10" \
            "$BASE_URL/centrifugo/v1/auth/token" || true)
        i=$((i + 1))
    done
    check "token IP rate limit -> 429" "429" "$ip_code"

    user_code=""
    i=0
    while [ "$i" -lt 31 ]; do
        user_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST \
            -H "apikey: $ANON_KEY" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "X-Forwarded-For: 198.51.100.11" \
            "$BASE_URL/centrifugo/v1/auth/token" || true)
        i=$((i + 1))
    done
    check "token user rate limit -> 429" "429" "$user_code"
else
    check "token rate limit setup" "complete" "failed"
fi

echo ""
echo "--- Log safety ---"
printf '%s\n' "$ACCESS_TOKEN" > "$TMP_DIR/session-secret"
printf '%s\n' "$SUPABASE_PUBLISHABLE_KEY" > "$TMP_DIR/publishable-secret"
if docker logs "$AUTH_CONTAINER" 2>&1 | grep -Fq -f "$TMP_DIR/session-secret"; then
    check "auth logs do not contain session token" "clean" "leaked"
else
    check "auth logs do not contain session token" "clean" "clean"
fi
if docker logs "$AUTH_CONTAINER" 2>&1 | grep -Fq -f "$TMP_DIR/publishable-secret"; then
    check "auth logs do not contain publishable key" "clean" "leaked"
else
    check "auth logs do not contain publishable key" "clean" "clean"
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
