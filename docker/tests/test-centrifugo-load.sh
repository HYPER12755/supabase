#!/bin/sh
set -eu

if [ ! -f .env ]; then
    echo "Error: .env file not found. Run from the project directory."
    exit 1
fi
if [ ! -f .env.centrifugo ]; then
    echo "Error: .env.centrifugo file not found. Enable the Centrifugo overlay first."
    exit 1
fi
if [ ! -f .env.centrifugo-scale ]; then
    echo "Error: .env.centrifugo-scale file not found. Enable the scale overlay first."
    exit 1
fi
for cmd in curl jq docker; do
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

BASE_URL=$(unquote "$(read_env SUPABASE_PUBLIC_URL)")
BASE_URL="${BASE_URL%/}"
ANON_KEY=$(unquote "$(read_env ANON_KEY)")
SERVICE_ROLE_KEY=$(unquote "$(read_env SERVICE_ROLE_KEY)")
CENTRIFUGO_HTTP_API_KEY=$(unquote "$(read_centrifugo_env CENTRIFUGO_HTTP_API_KEY)")
GATEWAY_URL="${1:-http://api-gw:8000}"

if [ -z "$BASE_URL" ] || [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ]; then
    echo "Error: required keys or URLs are missing from .env or .env.centrifugo."
    exit 1
fi

for container in supabase-centrifugo supabase-centrifugo-2 supabase-centrifugo-redis supabase-centrifugo-outbox supabase-centrifugo-outbox-2; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "SKIP: $container is not running; enable docker-compose.centrifugo-scale.yml."
        exit 0
    fi
done

LOAD_USERS="${LOAD_USERS:-10}"
RECONNECT_CLIENTS="${LOAD_RECONNECT_CLIENTS:-100}"
RECONNECT_WAVES="${LOAD_RECONNECT_WAVES:-3}"
FANOUT_CLIENTS="${LOAD_FANOUT_CLIENTS:-100}"
FANOUT_MESSAGES="${LOAD_FANOUT_MESSAGES:-10}"
CHANNEL_COUNT="${LOAD_CHANNEL_COUNT:-100}"
OUTBOX_ROWS="${LOAD_OUTBOX_ROWS:-200}"

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

psql_db() {
    docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -Atq "$@"
}

outbox_published_total() {
    docker exec "$1" node -e "fetch('http://127.0.0.1:9100/metrics').then((r)=>r.text()).then((text)=>{const match=text.match(/^centrifugo_outbox_published_total (\\d+)$/m); console.log(match ? match[1] : 0)}).catch(()=>{console.log(0)})"
}

TEST_PASSWORD="centrifugo-load-password-123456"
TEST_TENANT="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
TEST_USER_IDS=""
OUTBOX_CHANNEL_PREFIX="public:load-outbox-$$"

cleanup() {
    psql_db -c "DELETE FROM centrifugo.outbox WHERE channel LIKE '${OUTBOX_CHANNEL_PREFIX}-%'" >/dev/null 2>&1 || true
    for user_id in $TEST_USER_IDS; do
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$user_id" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    done
}
trap cleanup EXIT HUP INT TERM

echo ""
echo "=== Centrifugo load tests against $BASE_URL ==="
echo "config: reconnect=${RECONNECT_CLIENTS}x${RECONNECT_WAVES}, fanout=${FANOUT_CLIENTS}x${FANOUT_MESSAGES}, channels=${CHANNEL_COUNT}, outbox=${OUTBOX_ROWS}"
echo ""

echo "--- Setup ---"
USER_TOKEN_LIST=""
user_index=1
while [ "$user_index" -le "$LOAD_USERS" ]; do
    user_email="centrifugo-load-$$-${user_index}@example.com"
    create_response=$(curl -s --max-time 10 \
        "$BASE_URL/auth/v1/admin/users" \
        -X POST \
        -H "apikey: $SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$user_email\",\"password\":\"$TEST_PASSWORD\",\"email_confirm\":true,\"app_metadata\":{\"tenant_id\":\"$TEST_TENANT\"}}")
    user_id=$(printf '%s' "$create_response" | jq -r '.id // empty' 2>/dev/null || true)
    if [ -z "$user_id" ]; then
        break
    fi
    TEST_USER_IDS="$TEST_USER_IDS $user_id"

    session_response=$(curl -s --max-time 10 \
        "$BASE_URL/auth/v1/token?grant_type=password" \
        -H "apikey: $ANON_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$user_email\",\"password\":\"$TEST_PASSWORD\"}")
    access_token=$(printf '%s' "$session_response" | jq -r '.access_token // empty' 2>/dev/null || true)
    if [ -z "$access_token" ]; then
        break
    fi

    token_response=$(curl -s --max-time 10 \
        "$BASE_URL/centrifugo/v1/auth/token" \
        -X POST \
        -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $access_token")
    user_token=$(printf '%s' "$token_response" | jq -r '.token // empty' 2>/dev/null || true)
    if [ -z "$user_token" ]; then
        break
    fi
    USER_TOKEN_LIST="$USER_TOKEN_LIST $user_token"
    user_index=$((user_index + 1))
done
USER_TOKEN_LIST=$(printf '%s' "$USER_TOKEN_LIST" | sed 's/^ *//')
user_count=$(printf '%s' "$TEST_USER_IDS" | wc -w | tr -d ' ')
token_count=$(printf '%s' "$USER_TOKEN_LIST" | wc -w | tr -d ' ')
check "test users created" "$LOAD_USERS" "$user_count"
check "connection tokens issued" "$LOAD_USERS" "$token_count"

if [ "$user_count" != "$LOAD_USERS" ] || [ "$token_count" != "$LOAD_USERS" ]; then
    echo ""
    echo "=== Results: $pass passed, $fail failed ==="
    exit 1
fi

echo "--- Reconnect, fan-out, and channel load ---"
node_result=$(docker exec -i supabase-centrifugo-outbox node --input-type=module - \
    "$GATEWAY_URL" "$CENTRIFUGO_HTTP_API_KEY" "$USER_TOKEN_LIST" \
    "$RECONNECT_CLIENTS" "$RECONNECT_WAVES" "$FANOUT_CLIENTS" "$FANOUT_MESSAGES" "$CHANNEL_COUNT" <<'NODE'
import assert from 'node:assert/strict'

const [
  gatewayUrl,
  apiKey,
  tokenList,
  reconnectClients,
  reconnectWaves,
  fanoutClients,
  fanoutMessages,
  channelCount,
] = process.argv.slice(2)
const tokens = tokenList.split(/\s+/).filter(Boolean)
assert.ok(tokens.length > 0, 'no connection tokens provided')

const gateway = gatewayUrl.replace(/\/$/, '')
const wsUrl = new URL('/centrifugo/v1/connection/websocket', gateway)
wsUrl.protocol = gateway.startsWith('https') ? 'wss:' : 'ws:'
const apiPublish = new URL('/centrifugo/v1/api/publish', gateway)
const run = `${Date.now()}-${process.pid}`
const timer = setTimeout(() => {
  console.error('load test timed out')
  process.exit(1)
}, 180000)

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
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

async function openClient(token) {
  const ws = new WebSocket(wsUrl, 'centrifuge-json')
  let nextId = 1
  const pending = new Map()
  const pushes = []
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true })
    ws.addEventListener('error', () => reject(new Error('websocket error')), { once: true })
    ws.addEventListener('close', (event) => reject(new Error(`websocket closed: ${event.code}`)), { once: true })
  })
  ws.addEventListener('message', (event) => {
    for (const message of parseMessages(String(event.data))) {
      const resolve = pending.get(message.id)
      if (resolve) {
        pending.delete(message.id)
        resolve(message)
      }
      if (message.push) pushes.push(message.push)
    }
  })
  function send(command) {
    const id = nextId++
    ws.send(JSON.stringify({ id, ...command }))
    return new Promise((resolve, reject) => {
      pending.set(id, resolve)
      setTimeout(() => reject(new Error('command timeout')), 15000).unref()
    })
  }
  await ready
  const connect = await send({ connect: { token } })
  assert.ok(connect.connect && !connect.error, 'connect failed')
  return { ws, send, pushes }
}

async function openClients(count) {
  const clients = []
  for (let i = 0; i < count; i += 1) {
    clients.push(await openClient(tokens[i % tokens.length]))
  }
  return clients
}

function closeClients(clients) {
  for (const client of clients) client.ws.close(1000)
}

async function publish(channel, data) {
  const response = await fetch(apiPublish, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': apiKey },
    body: JSON.stringify({ channel, data }),
  })
  assert.equal(response.status, 200, 'publish failed')
}

async function waitForPushCount(client, count, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (client.pushes.length >= count) return client.pushes.length
    await sleep(20)
  }
  throw new Error(`timed out waiting for ${count} pushes; got ${client.pushes.length}`)
}

async function main() {
  const result = {}

  const reconnectStart = performance.now()
  for (let wave = 0; wave < Number(reconnectWaves); wave += 1) {
    const clients = await openClients(Number(reconnectClients))
    for (const client of clients) {
      const response = await client.send({ subscribe: { channel: `public:load-reconnect-${run}-${wave}` } })
      assert.ok(response.subscribe && !response.error, 'reconnect subscribe failed')
    }
    closeClients(clients)
    await sleep(100)
  }
  result.reconnectMs = Math.round(performance.now() - reconnectStart)

  const fanoutChannel = `public:load-fanout-${run}`
  const fanout = await openClients(Number(fanoutClients))
  await Promise.all(fanout.map((client) => client.send({ subscribe: { channel: fanoutChannel } })))
  await sleep(500)
  const fanoutStart = performance.now()
  for (let i = 0; i < Number(fanoutMessages); i += 1) {
    await publish(fanoutChannel, { index: i })
  }
  await Promise.all(fanout.map((client) => waitForPushCount(client, Number(fanoutMessages))))
  result.fanoutMs = Math.round(performance.now() - fanoutStart)
  result.fanoutDeliveries = fanout.length * Number(fanoutMessages)
  closeClients(fanout)

  const channelClient = await openClient(tokens[0])
  const channels = Array.from({ length: Number(channelCount) }, (_, index) => `public:load-channels-${run}-${index}`)
  await Promise.all(channels.map((channel) => channelClient.send({ subscribe: { channel } })))
  await sleep(500)
  const channelStart = performance.now()
  await Promise.all(channels.map((channel, index) => publish(channel, { index })))
  await waitForPushCount(channelClient, channels.length)
  result.channelsMs = Math.round(performance.now() - channelStart)
  result.channelDeliveries = channelClient.pushes.length
  channelClient.ws.close(1000)

  clearTimeout(timer)
  process.stdout.write(JSON.stringify(result))
}

main().catch((error) => {
  console.error(error.stack || error.message)
  process.exit(1)
})
NODE
) || node_result="failed"

value() {
    printf '%s' "$node_result" | jq -r ".$1 // 0" 2>/dev/null || printf '0'
}

reconnect_ms=$(value reconnectMs)
fanout_ms=$(value fanoutMs)
channels_ms=$(value channelsMs)
fanout_deliveries=$(value fanoutDeliveries)
channel_deliveries=$(value channelDeliveries)

echo "  reconnect storm: ${reconnect_ms}ms"
echo "  fan-out: ${fanout_ms}ms (${fanout_deliveries} deliveries)"
echo "  channel load: ${channels_ms}ms (${channel_deliveries} deliveries)"
check "reconnect storm completes" "true" "$([ "$reconnect_ms" -gt 0 ] && [ "$reconnect_ms" -lt 30000 ] && echo true || echo false)"
check "fan-out delivers every message" "true" "$([ "$fanout_deliveries" -eq $((FANOUT_CLIENTS * FANOUT_MESSAGES)) ] && echo true || echo false)"
check "fan-out completes" "true" "$([ "$fanout_ms" -gt 0 ] && [ "$fanout_ms" -lt 30000 ] && echo true || echo false)"
check "large channel set delivers every message" "true" "$([ "$channel_deliveries" -eq "$CHANNEL_COUNT" ] && echo true || echo false)"
check "large channel set completes" "true" "$([ "$channels_ms" -gt 0 ] && [ "$channels_ms" -lt 30000 ] && echo true || echo false)"

echo "--- Outbox throughput ---"
before_a=$(outbox_published_total supabase-centrifugo-outbox)
before_b=$(outbox_published_total supabase-centrifugo-outbox-2)
start_ms=$(date +%s%3N)
psql_db -c "SELECT centrifugo.send('${OUTBOX_CHANNEL_PREFIX}-' || g, jsonb_build_object('index', g), 'test') FROM generate_series(1, ${OUTBOX_ROWS}) g" >/dev/null
outbox_attempts=0
pending=1
published_delta=0
while [ "$outbox_attempts" -lt 60 ]; do
    pending=$(psql_db -c "SELECT count(*) FROM centrifugo.outbox WHERE published_at IS NULL AND channel LIKE '${OUTBOX_CHANNEL_PREFIX}-%'")
    after_a=$(outbox_published_total supabase-centrifugo-outbox)
    after_b=$(outbox_published_total supabase-centrifugo-outbox-2)
    published_delta=$((after_a + after_b - before_a - before_b))
    if [ "$pending" = "0" ] && [ "$published_delta" -ge "$OUTBOX_ROWS" ]; then
        break
    fi
    outbox_attempts=$((outbox_attempts + 1))
    sleep 1
done
outbox_ms=$(( $(date +%s%3N) - start_ms ))
echo "  outbox: ${outbox_ms}ms (${published_delta} published)"
check "outbox rows are drained" "0" "$pending"
check "outbox publishes every row" "true" "$([ "$published_delta" -ge "$OUTBOX_ROWS" ] && echo true || echo false)"
check "outbox throughput completes" "true" "$([ "$outbox_ms" -gt 0 ] && [ "$outbox_ms" -lt 60000 ] && echo true || echo false)"

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
