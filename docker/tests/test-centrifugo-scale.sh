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
SERVICE_ROLE_KEY=$(unquote "$(read_env SERVICE_ROLE_KEY)")
CENTRIFUGO_HTTP_API_KEY=$(unquote "$(read_centrifugo_env CENTRIFUGO_HTTP_API_KEY)")
GATEWAY_URL="${2:-http://api-gw:8000}"

if [ -z "$BASE_URL" ] || [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ]; then
    echo "Error: required keys or URLs are missing from .env or .env.centrifugo."
    exit 1
fi

for container in supabase-centrifugo supabase-centrifugo-2 supabase-centrifugo-redis supabase-centrifugo-outbox; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "SKIP: $container is not running; enable docker-compose.centrifugo-scale.yml."
        exit 0
    fi
done

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

wait_healthy() {
    container="$1"
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 2
    done
    return 1
}

psql_db() {
    docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -Atq "$@"
}

history_count() {
    curl -s --max-time 5 \
        "$BASE_URL/centrifugo/v1/api/history" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $CENTRIFUGO_HTTP_API_KEY" \
        -d "{\"channel\":\"$1\",\"limit\":100}" \
        | jq -r '.result.publications | length // 0' 2>/dev/null || echo 0
}

outbox_published_total() {
    docker exec "$1" node -e "fetch('http://127.0.0.1:9100/metrics').then((r)=>r.text()).then((text)=>{const match=text.match(/^centrifugo_outbox_published_total (\\d+)$/m); console.log(match ? match[1] : 0)}).catch(()=>{console.log(0)})"
}

TEST_EMAIL="centrifugo-scale-$$@example.com"
TEST_PASSWORD="centrifugo-scale-password-123456"
TEST_TENANT="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
TEST_USER_ID=""

cleanup() {
    if [ -n "$TEST_USER_ID" ]; then
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$TEST_USER_ID" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    fi
}
trap cleanup EXIT HUP INT TERM

echo ""
echo "=== Centrifugo scale tests against $BASE_URL ==="
echo ""

echo "--- Setup ---"
check "redis has no published port" "" "$(docker port supabase-centrifugo-redis 2>/dev/null || true)"
check "node 2 has no published port" "" "$(docker port supabase-centrifugo-2 2>/dev/null || true)"

create_response=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/admin/users" \
    -X POST \
    -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"email_confirm\":true,\"app_metadata\":{\"tenant_id\":\"$TEST_TENANT\"}}")
TEST_USER_ID=$(printf '%s' "$create_response" | jq -r '.id // empty' 2>/dev/null || true)
check "test user created" "created" "$([ -n "$TEST_USER_ID" ] && echo created || echo failed)"

session_response=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
ACCESS_TOKEN=$(printf '%s' "$session_response" | jq -r '.access_token // empty' 2>/dev/null || true)
check "test user session created" "created" "$([ -n "$ACCESS_TOKEN" ] && echo created || echo failed)"

if [ -z "$TEST_USER_ID" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo ""
    echo "=== Results: $pass passed, $fail failed ==="
    exit 1
fi

token_response=$(curl -s --max-time 10 \
    "$BASE_URL/centrifugo/v1/auth/token" \
    -X POST \
    -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $ACCESS_TOKEN")
USER_TOKEN=$(printf '%s' "$token_response" | jq -r '.token // empty' 2>/dev/null || true)
check "connection token issued" "issued" "$([ -n "$USER_TOKEN" ] && echo issued || echo failed)"

if [ -z "$USER_TOKEN" ]; then
    echo ""
    echo "=== Results: $pass passed, $fail failed ==="
    exit 1
fi

echo "--- Cross-node routing and Redis-backed state ---"
node_result=$(docker exec -i supabase-centrifugo-outbox node --input-type=module - \
    "$GATEWAY_URL" "$CENTRIFUGO_HTTP_API_KEY" "$USER_TOKEN" "$TEST_USER_ID" <<'NODE'
import assert from 'node:assert/strict'

const [gatewayUrl, apiKey, token, userId] = process.argv.slice(2)
const gateway = gatewayUrl.replace(/\/$/, '')
const wsGateway = new URL('/centrifugo/v1/connection/websocket', gateway)
wsGateway.protocol = gateway.startsWith('https') ? 'wss:' : 'ws:'
const apiPublish = new URL('/centrifugo/v1/api/publish', gateway)
const apiInfo = new URL('/centrifugo/v1/api/info', gateway)
const wsNode1 = new URL('ws://supabase-centrifugo:8000/connection/websocket')
const wsNode2 = new URL('ws://supabase-centrifugo-2:8000/connection/websocket')

const run = `${Date.now()}-${process.pid}`
const channels = {
  presence: `public:scale-${run}-presence`,
  history: `public:scale-${run}-history`,
  gateway: `public:scale-${run}-gateway`,
  node1: `public:scale-${run}-node1`,
  node2: `public:scale-${run}-node2`,
}

const timer = setTimeout(() => {
  console.error('scale test timed out')
  process.exit(1)
}, 90000)

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

async function openClient(url) {
  const ws = new WebSocket(url, 'centrifuge-json')
  let nextId = 1
  const pending = new Map()
  const pushes = []
  let closeError = null
  let closeResolve
  const closed = new Promise((resolve) => { closeResolve = resolve })

  ws.addEventListener('close', (event) => {
    if (event.code !== 1000 && !closeError) {
      closeError = new Error(`websocket closed with ${event.code}`)
      for (const entry of pending.values()) entry.reject(closeError)
      pending.clear()
    }
    closeResolve()
  })

  const ready = new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true })
    ws.addEventListener('error', () => reject(new Error('websocket error')), { once: true })
    ws.addEventListener('close', (event) => reject(new Error(`websocket closed during connect: ${event.code}`)), { once: true })
  })

  ws.addEventListener('message', (event) => {
    for (const message of parseMessages(String(event.data))) {
      const entry = pending.get(message.id)
      if (entry) {
        pending.delete(message.id)
        entry.resolve(message)
      }
      if (message.push) pushes.push(message.push)
    }
  })

  function send(command) {
    const id = nextId++
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject })
      try {
        ws.send(JSON.stringify({ id, ...command }))
      } catch (error) {
        pending.delete(id)
        reject(error)
      }
    })
  }

  await ready
  const connect = await send({ connect: { token } })
  assert.ok(connect.connect && !connect.error, 'connect failed')
  return { ws, send, pushes, closed }
}

async function closeClient(client) {
  client.ws.close(1000)
  await Promise.race([client.closed, sleep(1000)])
}

async function waitForPush(client, predicate, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const found = client.pushes.find(predicate)
    if (found) return found
    await sleep(25)
  }
  throw new Error('timed out waiting for push')
}

async function publish(channel, data) {
  const response = await fetch(apiPublish, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': apiKey },
    body: JSON.stringify({ channel, data }),
  })
  assert.equal(response.status, 200, 'server publish failed')
  return response.json()
}

async function info() {
  const response = await fetch(apiInfo, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': apiKey },
    body: '{}',
  })
  assert.equal(response.status, 200, 'api info failed')
  return response.json()
}

async function waitForDistribution(timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs
  let nodes = []
  while (Date.now() < deadline) {
    const body = await info()
    nodes = body.result?.nodes || []
    if (nodes.length >= 2 && nodes.every((node) => node.num_clients > 0)) {
      return nodes
    }
    await sleep(250)
  }
  return nodes
}

async function main() {
  const result = {}
  const node1 = await openClient(wsNode1)
  const node2 = await openClient(wsNode2)
  result.connectNode1 = true
  result.connectNode2 = true

  await node1.send({ subscribe: { channel: channels.presence, join_leave: true } })
  await node2.send({ subscribe: { channel: channels.presence } })
  await waitForPush(node1, (push) => push.channel === channels.presence && push.join?.info?.user === userId)
  result.crossNodeJoin = true

  const presence = await node1.send({ presence: { channel: channels.presence } })
  result.crossNodePresence = Object.keys(presence.presence?.presence || {}).length === 2

  await node1.send({ publish: { channel: channels.presence, data: { source: 'node1' } } })
  await waitForPush(node2, (push) => push.pub?.data?.source === 'node1')
  result.crossNodePublishNode1 = true

  await node2.send({ publish: { channel: channels.presence, data: { source: 'node2' } } })
  await waitForPush(node1, (push) => push.pub?.data?.source === 'node2')
  result.crossNodePublishNode2 = true

  await node1.send({ subscribe: { channel: channels.node1 } })
  await node1.send({ publish: { channel: channels.node1, data: { source: 'node1-proxy' } } })
  await waitForPush(node1, (push) => push.pub?.data?.source === 'node1-proxy')
  result.node1SubscribeProxy = true

  await node2.send({ subscribe: { channel: channels.node2 } })
  await node2.send({ publish: { channel: channels.node2, data: { source: 'node2-proxy' } } })
  await waitForPush(node2, (push) => push.pub?.data?.source === 'node2-proxy')
  result.node2SubscribeProxy = true

  const historySubscribe = await node1.send({ subscribe: { channel: channels.history } })
  const epoch = historySubscribe.subscribe?.epoch
  assert.ok(epoch, 'history subscription did not return an epoch')
  await node2.send({ subscribe: { channel: channels.history } })
  await node2.send({ publish: { channel: channels.history, data: { order: 1 } } })
  const firstPush = await waitForPush(node1, (push) => push.pub?.data?.order === 1)
  const offset = firstPush.pub.offset
  assert.ok(offset, 'history publication did not include an offset')
  await closeClient(node1)
  await node2.send({ publish: { channel: channels.history, data: { order: 2 } } })

  const recoveredNode = await openClient(wsNode2)
  const recovered = await recoveredNode.send({
    subscribe: { channel: channels.history, recover: true, epoch, offset },
  })
  const recoveredOrders = (recovered.subscribe?.publications || []).map((item) => item.data.order)
  result.crossNodeHistoryRecovery = recovered.subscribe?.recovered === true && recoveredOrders.includes(2)
  await closeClient(recoveredNode)

  const gatewayClients = []
  for (let i = 0; i < 20; i += 1) {
    gatewayClients.push(await openClient(wsGateway))
  }
  await Promise.all(gatewayClients.map((client) => client.send({ subscribe: { channel: channels.gateway } })))
  const nodes = await waitForDistribution()
  result.gatewayNodeCount = nodes.length >= 2
  result.gatewayDistribution = nodes.length >= 2 && nodes.every((node) => node.num_clients > 0)
  for (const client of gatewayClients) await closeClient(client)

  await closeClient(node2)

  clearTimeout(timer)
  process.stdout.write(JSON.stringify({
    ...result,
    historyChannel: channels.history,
    epoch,
    offset,
  }))
}

main().catch((error) => {
  console.error(error.stack || error.message)
  process.exit(1)
})
NODE
) || node_result="failed"

value() {
    printf '%s' "$node_result" | jq -r ".$1 // false" 2>/dev/null || printf 'false'
}

check "direct connection to node 1" "true" "$(value connectNode1)"
check "direct connection to node 2" "true" "$(value connectNode2)"
check "join event crosses nodes" "true" "$(value crossNodeJoin)"
check "presence includes both node clients" "true" "$(value crossNodePresence)"
check "publish on node 1 reaches node 2" "true" "$(value crossNodePublishNode1)"
check "publish on node 2 reaches node 1" "true" "$(value crossNodePublishNode2)"
check "subscribe proxy works on node 1" "true" "$(value node1SubscribeProxy)"
check "subscribe proxy works on node 2" "true" "$(value node2SubscribeProxy)"
check "history recovery crosses nodes" "true" "$(value crossNodeHistoryRecovery)"
check "gateway reports two nodes" "true" "$(value gatewayNodeCount)"
check "gateway distributes clients across nodes" "true" "$(value gatewayDistribution)"

echo "--- Outbox partition consumers ---"
check "outbox consumer 2 is healthy" "healthy" "$(docker inspect --format '{{.State.Health.Status}}' supabase-centrifugo-outbox-2 2>/dev/null || echo missing)"

outbox_run="$(date +%s)-$$"
partition_channels_ready=false
partition_attempt=0
while [ "$partition_attempt" -lt 20 ]; do
    candidate_a="public:scale-outbox-${outbox_run}-a${partition_attempt}"
    candidate_b="public:scale-outbox-${outbox_run}-b${partition_attempt}"
    candidate_partition_a=$(psql_db -c "SELECT (hashtext('$candidate_a') & 2147483647) % 2")
    candidate_partition_b=$(psql_db -c "SELECT (hashtext('$candidate_b') & 2147483647) % 2")
    if [ "$candidate_partition_a" != "$candidate_partition_b" ]; then
        partition_channels_ready=true
        channel_a="$candidate_a"
        channel_b="$candidate_b"
        break
    fi
    partition_attempt=$((partition_attempt + 1))
done
check "outbox channels map to different partitions" "true" "$partition_channels_ready"

if [ "$partition_channels_ready" = true ]; then
    before_a=$(outbox_published_total supabase-centrifugo-outbox)
    before_b=$(outbox_published_total supabase-centrifugo-outbox-2)
    psql_db -c "SELECT centrifugo.send('$channel_a', jsonb_build_object('source', 'scale', 'index', g), 'test') FROM generate_series(1, 4) g" >/dev/null
    psql_db -c "SELECT centrifugo.send('$channel_b', jsonb_build_object('source', 'scale', 'index', g), 'test') FROM generate_series(1, 4) g" >/dev/null
    outbox_attempts=0
    count_a=0
    count_b=0
    pending=1
    while [ "$outbox_attempts" -lt 40 ]; do
        count_a=$(history_count "$channel_a")
        count_b=$(history_count "$channel_b")
        pending=$(psql_db -c "SELECT count(*) FROM centrifugo.outbox WHERE channel IN ('$channel_a', '$channel_b') AND published_at IS NULL")
        if [ "$count_a" = "4" ] && [ "$count_b" = "4" ] && [ "$pending" = "0" ]; then
            break
        fi
        outbox_attempts=$((outbox_attempts + 1))
        sleep 1
    done
    check "first partition publishes each message once" "4" "$count_a"
    check "second partition publishes each message once" "4" "$count_b"
    check "outbox rows are drained" "0" "$pending"
    after_a=$(outbox_published_total supabase-centrifugo-outbox)
    after_b=$(outbox_published_total supabase-centrifugo-outbox-2)
    check "outbox consumer 1 handled its partition" "true" "$([ "$after_a" -gt "$before_a" ] && echo true || echo false)"
    check "outbox consumer 2 handled its partition" "true" "$([ "$after_b" -gt "$before_b" ] && echo true || echo false)"
    psql_db -c "DELETE FROM centrifugo.outbox WHERE channel IN ('$channel_a', '$channel_b')" >/dev/null 2>&1 || true
fi

HISTORY_CHANNEL=$(printf '%s' "$node_result" | jq -r '.historyChannel // empty' 2>/dev/null || true)
HISTORY_EPOCH=$(printf '%s' "$node_result" | jq -r '.epoch // empty' 2>/dev/null || true)
HISTORY_OFFSET=$(printf '%s' "$node_result" | jq -r '.offset // empty' 2>/dev/null || true)

echo "--- Node restart and reconnect ---"
docker restart supabase-centrifugo-2 >/dev/null
check "node 2 restarted healthy" "healthy" "$(wait_healthy supabase-centrifugo-2 && echo healthy || echo failed)"
sleep 10

restart_result=$(docker exec -i supabase-centrifugo-outbox node --input-type=module - \
    "$GATEWAY_URL" "$CENTRIFUGO_HTTP_API_KEY" "$USER_TOKEN" "$HISTORY_CHANNEL" <<'NODE'
import assert from 'node:assert/strict'

const [gatewayUrl, apiKey, token, historyChannel] = process.argv.slice(2)
const gateway = gatewayUrl.replace(/\/$/, '')
const wsGateway = new URL('/centrifugo/v1/connection/websocket', gateway)
wsGateway.protocol = gateway.startsWith('https') ? 'wss:' : 'ws:'
const apiInfo = new URL('/centrifugo/v1/api/info', gateway)
const wsNode2 = new URL('ws://supabase-centrifugo-2:8000/connection/websocket')

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }

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

async function info() {
  const response = await fetch(apiInfo, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': apiKey },
    body: '{}',
  })
  assert.equal(response.status, 200, 'api info failed')
  return response.json()
}

async function waitForNodes(timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const body = await info()
      const nodes = body.result?.nodes || []
      if (nodes.length >= 2) return nodes
    } catch {
      // Envoy may briefly have no healthy endpoint while a node restarts.
    }
    await sleep(500)
  }
  throw new Error('gateway did not report two nodes')
}

async function openClient(url) {
  const ws = new WebSocket(url, 'centrifuge-json')
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
      const entry = pending.get(message.id)
      if (entry) {
        pending.delete(message.id)
        entry(message)
      }
      if (message.push) pushes.push(message.push)
    }
  })
  function send(command) {
    const id = nextId++
    ws.send(JSON.stringify({ id, ...command }))
    return new Promise((resolve, reject) => {
      pending.set(id, resolve)
      setTimeout(() => reject(new Error('command timeout')), 8000).unref()
    })
  }
  await ready
  const connect = await send({ connect: { token } })
  assert.ok(connect.connect && !connect.error, 'connect failed')
  return { ws, send, pushes }
}

async function waitForPush(client, predicate, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const found = client.pushes.find(predicate)
    if (found) return found
    await sleep(25)
  }
  throw new Error('timed out waiting for push')
}

async function main() {
  const result = {}
  const nodes = await waitForNodes()
  result.nodesAfterRestart = nodes.length >= 2

  const gatewayClient = await openClient(wsGateway)
  const channel = `public:scale-restart-${Date.now()}`
  await gatewayClient.send({ subscribe: { channel } })
  await gatewayClient.send({ publish: { channel, data: { source: 'restart' } } })
  await waitForPush(gatewayClient, (push) => push.pub?.data?.source === 'restart')
  result.gatewayReconnect = true
  gatewayClient.ws.close(1000)

  const node2Client = await openClient(wsNode2)
  const directChannel = `public:scale-restart-direct-${Date.now()}`
  await node2Client.send({ subscribe: { channel: directChannel } })
  await node2Client.send({ publish: { channel: directChannel, data: { source: 'node2-restart' } } })
  await waitForPush(node2Client, (push) => push.pub?.data?.source === 'node2-restart')
  result.node2SubscribeProxyAfterRestart = true
  node2Client.ws.close(1000)

  const historyClient = await openClient(wsGateway)
  await historyClient.send({ subscribe: { channel: historyChannel } })
  const history = await historyClient.send({ history: { channel: historyChannel, limit: 10 } })
  const orders = (history.history?.publications || []).map((item) => item.data.order)
  result.historyAfterNodeRestart = orders.includes(1) && orders.includes(2)
  historyClient.ws.close(1000)

  process.stdout.write(JSON.stringify(result))
}

main().catch((error) => {
  console.error(error.stack || error.message)
  process.exit(1)
})
NODE
) || restart_result="failed"

check "gateway reports two nodes after restart" "true" "$(printf '%s' "$restart_result" | jq -r '.nodesAfterRestart // false' 2>/dev/null || printf 'false')"
check "gateway client reconnects after node restart" "true" "$(printf '%s' "$restart_result" | jq -r '.gatewayReconnect // false' 2>/dev/null || printf 'false')"
check "node 2 subscribe proxy works after restart" "true" "$(printf '%s' "$restart_result" | jq -r '.node2SubscribeProxyAfterRestart // false' 2>/dev/null || printf 'false')"
check "history survives node restart" "true" "$(printf '%s' "$restart_result" | jq -r '.historyAfterNodeRestart // false' 2>/dev/null || printf 'false')"

echo "--- Redis restart and reconnect ---"
docker restart supabase-centrifugo-redis >/dev/null
check "redis restarted healthy" "healthy" "$(wait_healthy supabase-centrifugo-redis && echo healthy || echo failed)"
sleep 5

redis_result=$(docker exec -i supabase-centrifugo-outbox node --input-type=module - \
    "$GATEWAY_URL" "$CENTRIFUGO_HTTP_API_KEY" "$USER_TOKEN" <<'NODE'
import assert from 'node:assert/strict'

const [gatewayUrl, apiKey, token] = process.argv.slice(2)
const gateway = gatewayUrl.replace(/\/$/, '')
const wsGateway = new URL('/centrifugo/v1/connection/websocket', gateway)
wsGateway.protocol = gateway.startsWith('https') ? 'wss:' : 'ws:'
const wsNode1 = new URL('ws://supabase-centrifugo:8000/connection/websocket')
const wsNode2 = new URL('ws://supabase-centrifugo-2:8000/connection/websocket')

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }

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

async function openClient(url) {
  const ws = new WebSocket(url, 'centrifuge-json')
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
      const entry = pending.get(message.id)
      if (entry) {
        pending.delete(message.id)
        entry(message)
      }
      if (message.push) pushes.push(message.push)
    }
  })
  function send(command) {
    const id = nextId++
    ws.send(JSON.stringify({ id, ...command }))
    return new Promise((resolve, reject) => {
      pending.set(id, resolve)
      setTimeout(() => reject(new Error('command timeout')), 8000).unref()
    })
  }
  await ready
  const connect = await send({ connect: { token } })
  assert.ok(connect.connect && !connect.error, 'connect failed')
  return { ws, send, pushes }
}

async function waitForPush(client, predicate, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const found = client.pushes.find(predicate)
    if (found) return found
    await sleep(25)
  }
  throw new Error('timed out waiting for push')
}

async function main() {
  const result = {}
  const gatewayClient = await openClient(wsGateway)
  const gatewayChannel = `public:scale-redis-gateway-${Date.now()}`
  await gatewayClient.send({ subscribe: { channel: gatewayChannel } })
  await gatewayClient.send({ publish: { channel: gatewayChannel, data: { source: 'gateway' } } })
  await waitForPush(gatewayClient, (push) => push.pub?.data?.source === 'gateway')
  result.gatewayAfterRedisRestart = true
  gatewayClient.ws.close(1000)

  const node1 = await openClient(wsNode1)
  const node2 = await openClient(wsNode2)
  const crossChannel = `public:scale-redis-cross-${Date.now()}`
  await node1.send({ subscribe: { channel: crossChannel } })
  await node2.send({ subscribe: { channel: crossChannel } })
  await node1.send({ publish: { channel: crossChannel, data: { source: 'node1' } } })
  await waitForPush(node2, (push) => push.pub?.data?.source === 'node1')
  result.crossNodeAfterRedisRestart = true
  node1.ws.close(1000)
  node2.ws.close(1000)

  process.stdout.write(JSON.stringify(result))
}

main().catch((error) => {
  console.error(error.stack || error.message)
  process.exit(1)
})
NODE
) || redis_result="failed"

check "gateway reconnects after Redis restart" "true" "$(printf '%s' "$redis_result" | jq -r '.gatewayAfterRedisRestart // false' 2>/dev/null || printf 'false')"
check "cross-node routing resumes after Redis restart" "true" "$(printf '%s' "$redis_result" | jq -r '.crossNodeAfterRedisRestart // false' 2>/dev/null || printf 'false')"

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
