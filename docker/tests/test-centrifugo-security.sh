#!/bin/sh
set -eu

DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
AUTH_CONTAINER="supabase-centrifugo-auth"
CENTRIFUGO_CONTAINER="supabase-centrifugo"
OUTBOX_CONTAINER="supabase-centrifugo-outbox"
OUTBOX_CONTAINER_2="supabase-centrifugo-outbox-2"
USER_ID="123e4567-e89b-42d3-a456-426614174000"

if [ ! -f .env ]; then
    echo "Error: .env file not found. Run from the project directory."
    exit 1
fi
if [ ! -f .env.centrifugo ]; then
    echo "Error: .env.centrifugo file not found. Enable the Centrifugo overlay first."
    exit 1
fi
for cmd in docker node; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found."
        exit 1
    fi
done

read_env() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2- | tr -d '\r'
}

read_centrifugo_env() {
    grep "^$1=" .env.centrifugo | head -n 1 | cut -d= -f2- | tr -d '\r'
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
SERVICE_ROLE_KEY=$(unquote "$(read_env SERVICE_ROLE_KEY)")
CENTRIFUGO_HTTP_API_KEY=$(unquote "$(read_centrifugo_env CENTRIFUGO_HTTP_API_KEY)")
CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY=$(unquote "$(read_centrifugo_env CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY)")

if [ -z "$BASE_URL" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ] || [ -z "$CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY" ]; then
    echo "Error: required keys or URLs are missing from .env or .env.centrifugo."
    exit 1
fi

for container in "$AUTH_CONTAINER" "$CENTRIFUGO_CONTAINER" "$OUTBOX_CONTAINER"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "SKIP: $container is not running."
        exit 0
    fi
done
if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
    echo "SKIP: $DB_CONTAINER is not running."
    exit 0
fi

psql_db() {
    docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -Atq "$@"
}

psql_scalar() {
    psql_db -c "$1"
}

if [ "$(psql_scalar "SELECT to_regprocedure('centrifugo.channel_is_valid(text)') IS NOT NULL")" != "t" ]; then
    echo "SKIP: Centrifugo SQL helpers are not installed; enable the Centrifugo overlay."
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
SECRET_FILE="$TMP_DIR/secrets"

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

connect_result() {
    token="$1"
    BASE_URL="$BASE_URL" TOKEN="$token" node - <<'NODE' || printf 'failed'
const url = new URL('/centrifugo/v1/connection/websocket', process.env.BASE_URL)
url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
const token = process.env.TOKEN || ''
const ws = new WebSocket(url, 'centrifuge-json')
const timer = setTimeout(() => {
  console.log('timeout')
  process.exit(0)
}, 5000)

function finish(result) {
  clearTimeout(timer)
  console.log(result)
  try { ws.close() } catch {}
  process.exit(0)
}

ws.addEventListener('open', () => {
  ws.send(JSON.stringify({ id: 1, connect: token ? { token } : {} }))
})

ws.addEventListener('message', (event) => {
  let message
  try {
    message = JSON.parse(String(event.data))
  } catch {
    return
  }
  if (message.id !== 1) return
  if (message.connect && message.connect.client) finish('connected')
  else if (message.error) finish('rejected')
  else finish('unexpected')
})

ws.addEventListener('close', (event) => {
  finish(event.code >= 3500 ? 'rejected' : `closed-${event.code}`)
})

ws.addEventListener('error', () => finish('failed'))
NODE
}

sign_token() {
    TOKEN_SECRET="$CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY" USER_ID="$USER_ID" OFFSET="$1" node -e '
      const crypto = require("crypto");
      const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
      const now = Math.floor(Date.now() / 1000);
      const unsigned = encode({ alg: "HS256", typ: "JWT" }) + "." + encode({
        sub: process.env.USER_ID,
        exp: now + Number(process.env.OFFSET),
      });
      process.stdout.write(unsigned + "." + crypto.createHmac("sha256", process.env.TOKEN_SECRET).update(unsigned).digest("base64url"));
    '
}

expect_denied() {
    test_name="$1"
    statement="$2"

    if psql_db -c "$statement" >/dev/null 2>&1; then
        check "$test_name" "denied" "allowed"
    else
        check "$test_name" "denied" "denied"
    fi
}

echo ""
echo "=== Centrifugo security tests ==="
echo ""

echo "--- Client token rejection ---"
valid_token=$(sign_token 60)
expired_token=$(sign_token -60)
check "valid control token connects" "connected" "$(connect_result "$valid_token")"
check "missing token is rejected" "rejected" "$(connect_result "")"
check "invalid token is rejected" "rejected" "$(connect_result "not-a-token")"
check "expired token is rejected" "rejected" "$(connect_result "$expired_token")"
check "service-role token cannot connect as a client" "rejected" "$(connect_result "$SERVICE_ROLE_KEY")"
check "API key cannot be used as a client token" "rejected" "$(connect_result "$CENTRIFUGO_HTTP_API_KEY")"

echo ""
echo "--- Outbox privileges ---"
for role in anon authenticated; do
    check "role $role exists" "t" "$(psql_scalar "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role')")"
    expect_denied "$role cannot call centrifugo.send" "SET ROLE $role; SELECT centrifugo.send('public:security-test', '{}'::jsonb)"
    expect_denied "$role cannot call centrifugo.broadcast_changes" "SET ROLE $role; SELECT centrifugo.broadcast_changes('public', 'security_test', 'INSERT', jsonb_build_object('tenant_id', '$USER_ID'), 'tenant_id')"
    expect_denied "$role cannot call centrifugo.broadcast_changes_trigger" "SET ROLE $role; SELECT centrifugo.broadcast_changes_trigger()"
    expect_denied "$role cannot read centrifugo.outbox" "SET ROLE $role; SELECT count(*) FROM centrifugo.outbox"
done

echo ""
echo "--- Log safety ---"
: > "$SECRET_FILE"
for file in .env .env.centrifugo .env.centrifugo-scale; do
    [ -f "$file" ] || continue
    while IFS='=' read -r key value; do
        case "$key" in
            ""|\#*) continue ;;
            *SECRET*|*KEY*|*PASSWORD*|*TOKEN*|*DATABASE_URL*) ;;
            *) continue ;;
        esac
        value=$(printf '%s' "$value" | tr -d '\r' | sed 's/^"//; s/"$//')
        if [ "${#value}" -ge 16 ]; then
            printf '%s\n' "$value" >> "$SECRET_FILE"
        fi
    done < "$file"
done
check "secret scan collected values" "true" "$([ -s "$SECRET_FILE" ] && echo true || echo false)"

for container in "$AUTH_CONTAINER" "$CENTRIFUGO_CONTAINER" "$OUTBOX_CONTAINER" "$OUTBOX_CONTAINER_2"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        continue
    fi
    if docker logs "$container" 2>&1 | grep -Fq -f "$SECRET_FILE"; then
        check "$container logs exclude secrets" "clean" "leaked"
    else
        check "$container logs exclude secrets" "clean" "clean"
    fi
done

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
