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
for cmd in curl jq docker node; do
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
GATEWAY_URL="${2:-$BASE_URL}"

if [ -z "$BASE_URL" ] || [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ]; then
    echo "Error: required keys or URLs are missing from .env or .env.centrifugo."
    exit 1
fi

for container in \
    supabase-centrifugo \
    supabase-centrifugo-2 \
    supabase-centrifugo-redis \
    supabase-centrifugo-redis-replica \
    supabase-centrifugo-redis-sentinel-1 \
    supabase-centrifugo-redis-sentinel-2 \
    supabase-centrifugo-redis-sentinel-3 \
    supabase-centrifugo-redis-proxy; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "SKIP: $container is not running; enable docker-compose.centrifugo-scale-ha.yml."
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

TEST_EMAIL="centrifugo-scale-ha-$$@example.com"
TEST_PASSWORD="centrifugo-scale-ha-password-123456"
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
echo "=== Centrifugo Redis Sentinel failover tests against $BASE_URL ==="
echo ""

echo "--- Setup ---"
check "redis has no published port" "" "$(docker port supabase-centrifugo-redis 2>/dev/null || true)"
check "replica has no published port" "" "$(docker port supabase-centrifugo-redis-replica 2>/dev/null || true)"
check "sentinel 1 has no published port" "" "$(docker port supabase-centrifugo-redis-sentinel-1 2>/dev/null || true)"
check "proxy has no published port" "" "$(docker port supabase-centrifugo-redis-proxy 2>/dev/null || true)"

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

echo "--- Master failover, client continuity, and recovery ---"
node_result=$(GATEWAY_URL="$GATEWAY_URL" API_KEY="$CENTRIFUGO_HTTP_API_KEY" TOKEN="$USER_TOKEN" USER_ID="$TEST_USER_ID" node --input-type=module - <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

const gateway = process.env.GATEWAY_URL.replace(/\/$/, '')
const apiKey = process.env.API_KEY
const token = process.env.TOKEN
const userId = process.env.USER_ID

const wsUrl = new URL('/centrifugo/v1/connection/websocket', gateway)
wsUrl.protocol = gateway.startsWith('https') ? 'wss:' : 'ws:'
const apiPublish = new URL('/centrifugo/v1/api/publish', gateway)
const apiHistory = new URL('/centrifugo/v1/api/history', gateway)
const redisContainer = 'supabase-centrifugo-redis'
const replicasContainer = 'supabase-centrifugo-redis-replica'
const sentinelContainer = 'supabase-centrifugo-redis-sentinel-1'
const masterName = 'mymaster'
const run = `${Date.now()}-${process.pid}`
const channels = {
  presence: `public:ha-${run}-presence`,
  history: `public:ha-${run}-history`,
}
const clients = []
let masterIp = ''
let masterStopped = false

const timer = setTimeout(() => {
  console.error('failover test timed out')
  process.exit(1)
}, 300000)

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function docker(args) {
  return execFileSync('docker', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
}

async function waitFor(label, fn, timeoutMs = 60000, intervalMs = 500) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      if (await fn()) return
    } catch {
      // Retry while the Redis topology settles.
    }
    await sleep(intervalMs)
  }
  throw new Error(`timed out waiting for ${label}`)
}

function inspectIp(container) {
  return docker([
    'inspect',
    '--format',
    '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}',
    container,
  ])
}

function inspectHealth(container) {
  return docker(['inspect', '--format', '{{.State.Health.Status}}', container])
}

function sentinelMasterIp() {
  const output = docker([
    'exec',
    sentinelContainer,
    'redis-cli',
    '-p',
    '26379',
    '--raw',
    'SENTINEL',
    'get-master-addr-by-name',
    masterName,
  ])
  return output.split('\n')[0].trim()
}

function proxyRole() {
  const output = docker([
    'exec',
    sentinelContainer,
    'sh',
    '-c',
    'REDISCLI_AUTH="$CENTRIFUGO_ENGINE_REDIS_PASSWORD" redis-cli --no-auth-warning -h redis-proxy ROLE',
  ])
  return output.split('\n')[0].trim()
}

function sentinelReplicaIps() {
  const output = docker([
    'exec',
    sentinelContainer,
    'redis-cli',
    '-p',
    '26379',
    '--raw',
    'SENTINEL',
    'replicas',
    masterName,
  ])
  const lines = output.split('\n').map((line) => line.trim())
  const ips = []
  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index] === 'ip' && lines[index + 1]) {
      ips.push(lines[index + 1])
    }
  }
  return ips
}

function waitForReplication() {
  const replicas = docker([
    'exec',
    redisContainer,
    'sh',
    '-c',
    'REDISCLI_AUTH="$CENTRIFUGO_ENGINE_REDIS_PASSWORD" redis-cli --no-auth-warning WAIT 1 5000',
  ])
  assert.equal(replicas, '1', 'redis replica did not acknowledge the baseline writes')
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

async function openClient() {
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
      ws.send(JSON.stringify({ id, ...command }))
      setTimeout(() => {
        if (pending.delete(id)) reject(new Error(`command timed out: ${Object.keys(command)[0]}`))
      }, 10000).unref()
    })
  }
  await ready
  const connect = await send({ connect: { token } })
  assert.ok(connect.connect && !connect.error, 'connect failed')
  const client = { ws, send, pushes }
  clients.push(client)
  return client
}

async function waitForPush(client, predicate, timeoutMs = 60000) {
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
  if (response.status !== 200) {
    throw new Error(`publish failed with ${response.status}`)
  }
  return response.json()
}

async function publishUntilPush(client, channel, data, predicate, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs
  let lastError
  while (Date.now() < deadline) {
    try {
      await publish(channel, data)
      return await waitForPush(client, predicate, 2000)
    } catch (error) {
      lastError = error
      await sleep(500)
    }
  }
  throw lastError || new Error('publish did not reach subscriber')
}

async function history(channel) {
  const response = await fetch(apiHistory, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': apiKey },
    body: JSON.stringify({ channel, limit: 100 }),
  })
  assert.equal(response.status, 200, 'history API failed')
  return response.json()
}

async function restoreTopology() {
  for (const client of clients) {
    try { client.ws.close(1000) } catch { /* already closed */ }
  }
  if (!masterStopped) return true

  try { docker(['start', redisContainer]) } catch { /* already running */ }
  await waitFor('redis health after restart', () => inspectHealth(redisContainer) === 'healthy', 60000).catch(() => {})
  masterIp = inspectIp(redisContainer)
  await sleep(1000)

  if (sentinelMasterIp() !== masterIp) {
    try {
      docker([
        'exec',
        redisContainer,
        'sh',
        '-c',
        'REDISCLI_AUTH="$CENTRIFUGO_ENGINE_REDIS_PASSWORD" redis-cli --no-auth-warning REPLICAOF "$1" 6379',
        'sh',
        sentinelMasterIp(),
      ])
    } catch { /* already a replica */ }
    await waitFor('old master to become a replica', () => sentinelReplicaIps().includes(masterIp), 30000).catch(() => {})
    try {
      docker(['exec', sentinelContainer, 'redis-cli', '-p', '26379', 'SENTINEL', 'FAILOVER', masterName])
    } catch { /* no eligible replica */ }
    await waitFor('old master to be promoted back', () => sentinelMasterIp() === masterIp, 90000).catch(() => {})
  }
  await waitFor('proxy to route to the restored master', () => proxyRole() === 'master', 30000).catch(() => {})
  return sentinelMasterIp() === masterIp && proxyRole() === 'master'
}

async function main() {
  const result = {}
  console.error('stage: baseline')
  masterIp = inspectIp(redisContainer)
  const replicaIP = inspectIp(replicasContainer)
  result.initialMaster = sentinelMasterIp() === masterIp
  assert.ok(result.initialMaster, 'sentinel did not start on the redis master')
  assert.ok(replicaIP && replicaIP !== masterIp, 'replica did not get a distinct address')
  result.proxyBefore = proxyRole() === 'master'
  assert.ok(result.proxyBefore, 'redis proxy did not route to the redis master')

  console.error('stage: opening clients')
  const clientA = await openClient()
  const clientB = await openClient()
  await clientA.send({ subscribe: { channel: channels.presence, join_leave: true } })
  await clientB.send({ subscribe: { channel: channels.presence } })
  await waitForPush(clientA, (push) => push.channel === channels.presence && push.join?.info?.user === userId)

  const presenceBefore = await clientA.send({ presence: { channel: channels.presence } })
  result.presenceBefore = Object.keys(presenceBefore.presence?.presence || {}).length === 2

  const historySub = await clientA.send({ subscribe: { channel: channels.history } })
  const epoch = historySub.subscribe?.epoch
  assert.ok(epoch, 'history subscription did not return an epoch')
  await publish(channels.history, { order: 1 })
  const firstPush = await waitForPush(clientA, (push) => push.pub?.data?.order === 1)
  const offset = firstPush.pub.offset
  assert.ok(offset, 'history publication did not include an offset')
  result.historyBefore = (await history(channels.history)).result.publications.length >= 1

  console.error('stage: baseline ready; stopping master')
  waitForReplication()
  masterStopped = true
  docker(['stop', redisContainer])
  await waitFor('sentinel to promote the replica', () => sentinelMasterIp() === replicaIP, 90000)
  result.promoted = true
  console.error('stage: replica promoted; waiting for proxy recovery')
  await waitFor('proxy to route to the promoted master', () => proxyRole() === 'master', 30000)
  result.proxyAfterFailover = true
  console.error('stage: proxy recovered; waiting for publish recovery')

  await publishUntilPush(
    clientA,
    channels.presence,
    { source: 'after-failover' },
    (push) => push.pub?.data?.source === 'after-failover'
  )
  result.clientsConnected = clientA.ws.readyState === WebSocket.OPEN && clientB.ws.readyState === WebSocket.OPEN
  result.publishAfterFailover = true
  console.error('stage: publish recovered; checking presence')

  const presenceAfter = await clientA.send({ presence: { channel: channels.presence } })
  result.presenceAfterFailover = Object.keys(presenceAfter.presence?.presence || {}).length === 2

  await publishUntilPush(
    clientA,
    channels.history,
    { order: 2 },
    (push) => push.pub?.data?.order === 2
  )
  const recoveredClient = await openClient()
  const recovered = await recoveredClient.send({
    subscribe: { channel: channels.history, recover: true, epoch, offset },
  })
  const recoveredOrders = (recovered.subscribe?.publications || []).map((item) => item.data?.order)
  result.historySurvivesFailover = recovered.subscribe?.recovered === true && recoveredOrders.includes(2)
  result.historyRetained = (await history(channels.history)).result.publications.some((item) => item.data?.order === 1)
  console.error('stage: history checked; restoring topology')

  result.masterRestored = await restoreTopology()
  clearTimeout(timer)
  return result
}

main()
  .then((result) => {
    process.stdout.write(JSON.stringify(result))
  })
  .catch((error) => {
    console.error(error.stack || error.message)
    process.exitCode = 1
  })
  .finally(async () => {
    await restoreTopology()
  })
NODE
) || node_result="failed"

value() {
    printf '%s' "$node_result" | jq -r ".$1 // false" 2>/dev/null || printf 'false'
}

check "sentinel initially follows the redis master" "true" "$(value initialMaster)"
check "proxy initially follows the redis master" "true" "$(value proxyBefore)"
check "presence is ready before failover" "true" "$(value presenceBefore)"
check "history is ready before failover" "true" "$(value historyBefore)"
check "sentinel promotes the replica" "true" "$(value promoted)"
check "proxy follows the promoted master" "true" "$(value proxyAfterFailover)"
check "clients stay connected during failover" "true" "$(value clientsConnected)"
check "publish resumes after failover" "true" "$(value publishAfterFailover)"
check "presence survives failover" "true" "$(value presenceAfterFailover)"
check "history recovery survives failover" "true" "$(value historySurvivesFailover)"
check "pre-failover history is retained" "true" "$(value historyRetained)"
check "old master is restored" "true" "$(value masterRestored)"

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
