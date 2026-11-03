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
for cmd in curl jq node; do
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

if [ -z "$BASE_URL" ] || [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$CENTRIFUGO_HTTP_API_KEY" ]; then
    echo "Error: required keys or URLs are missing from .env or .env.centrifugo."
    exit 1
fi

if ! docker inspect supabase-centrifugo >/dev/null 2>&1; then
    echo "SKIP: supabase-centrifugo is not running."
    exit 0
fi

TMP_DIR=$(mktemp -d)
TEST_PASSWORD="centrifugo-features-password-123456"
TENANT_A="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
TENANT_B="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
USER_A_ID=""
USER_B_ID=""

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

cleanup_users() {
    if [ -n "$USER_A_ID" ]; then
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$USER_A_ID" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    fi
    if [ -n "$USER_B_ID" ]; then
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$USER_B_ID" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    fi
}
trap 'cleanup_users; rm -rf "$TMP_DIR"' EXIT HUP INT TERM

create_user() {
    email="$1"
    tenant="$2"
    curl -s --max-time 10 \
        "$BASE_URL/auth/v1/admin/users" \
        -X POST \
        -H "apikey: $SERVICE_ROLE_KEY" \
        -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$TEST_PASSWORD\",\"email_confirm\":true,\"app_metadata\":{\"tenant_id\":\"$tenant\"}}"
}

login() {
    email="$1"
    curl -s --max-time 10 \
        "$BASE_URL/auth/v1/token?grant_type=password" \
        -H "apikey: $ANON_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$TEST_PASSWORD\"}"
}

connection_token() {
    bearer="${1:-}"
    output_file="$2"
    if [ -n "$bearer" ]; then
        curl -s -o "$output_file" --max-time 10 \
            -X POST \
            -H "apikey: $ANON_KEY" \
            -H "Authorization: Bearer $bearer" \
            "$BASE_URL/centrifugo/v1/auth/token" || true
    else
        curl -s -o "$output_file" --max-time 10 \
            -X POST \
            -H "apikey: $ANON_KEY" \
            "$BASE_URL/centrifugo/v1/auth/token" || true
    fi
    jq -r '.token // empty' "$output_file" 2>/dev/null || true
}

echo ""
echo "=== Centrifugo channel feature tests against $BASE_URL ==="
echo ""

USER_A_EMAIL="centrifugo-features-$$-a@example.com"
USER_B_EMAIL="centrifugo-features-$$-b@example.com"
USER_A_RESPONSE=$(create_user "$USER_A_EMAIL" "$TENANT_A")
USER_B_RESPONSE=$(create_user "$USER_B_EMAIL" "$TENANT_B")
USER_A_ID=$(printf '%s' "$USER_A_RESPONSE" | jq -r '.id // empty' 2>/dev/null)
USER_B_ID=$(printf '%s' "$USER_B_RESPONSE" | jq -r '.id // empty' 2>/dev/null)
check "create user A" "created" "$([ -n "$USER_A_ID" ] && echo created || echo failed)"
check "create user B" "created" "$([ -n "$USER_B_ID" ] && echo created || echo failed)"

SESSION_A=$(login "$USER_A_EMAIL")
SESSION_B=$(login "$USER_B_EMAIL")
ACCESS_A=$(printf '%s' "$SESSION_A" | jq -r '.access_token // empty' 2>/dev/null)
ACCESS_B=$(printf '%s' "$SESSION_B" | jq -r '.access_token // empty' 2>/dev/null)
check "login user A" "session" "$([ -n "$ACCESS_A" ] && echo session || echo failed)"
check "login user B" "session" "$([ -n "$ACCESS_B" ] && echo session || echo failed)"

TOKEN_A=$(connection_token "$ACCESS_A" "$TMP_DIR/token-a.json")
TOKEN_B=$(connection_token "$ACCESS_B" "$TMP_DIR/token-b.json")
ANON_TOKEN=$(connection_token "" "$TMP_DIR/token-anon.json")
check "connection token A" "issued" "$([ -n "$TOKEN_A" ] && echo issued || echo failed)"
check "connection token B" "issued" "$([ -n "$TOKEN_B" ] && echo issued || echo failed)"
check "anonymous token" "issued" "$([ -n "$ANON_TOKEN" ] && echo issued || echo failed)"

if [ -z "$TOKEN_A" ] || [ -z "$TOKEN_B" ] || [ -z "$ANON_TOKEN" ]; then
    echo ""
    echo "=== Results: $pass passed, $fail failed ==="
    exit 1
fi

node_result=$(TOKEN_A="$TOKEN_A" TOKEN_B="$TOKEN_B" ANON_TOKEN="$ANON_TOKEN" \
    USER_A="$USER_A_ID" USER_B="$USER_B_ID" TENANT_A="$TENANT_A" TENANT_B="$TENANT_B" \
    API_KEY="$CENTRIFUGO_HTTP_API_KEY" BASE_URL="$BASE_URL" node - <<'NODE'
const assert = require('node:assert/strict')

const RUN = `${Date.now()}-${process.pid}`
const channels = {
  basic: `public:phase5-${RUN}-basic`,
  server: `public:phase5-${RUN}-server`,
  client: `public:phase5-${RUN}-client`,
  presence: `public:phase5-${RUN}-presence`,
  join: `public:phase5-${RUN}-join`,
  history: `public:phase5-${RUN}-history`,
  recovery: `public:phase5-${RUN}-recovery`,
  anonymous: `public:phase5-${RUN}-anonymous`,
  rate: `public:phase5-${RUN}-rate`,
  tenantA: `tenant:${process.env.TENANT_A}:table:phase5_${RUN.replace(/[^a-z0-9]/gi, '_')}`,
  tenantB: `tenant:${process.env.TENANT_B}:table:phase5_${RUN.replace(/[^a-z0-9]/gi, '_')}`,
  userA: `user:${process.env.USER_A}`,
  userB: `user:${process.env.USER_B}`,
}

const wsUrl = new URL('/centrifugo/v1/connection/websocket', process.env.BASE_URL)
wsUrl.protocol = wsUrl.protocol === 'https:' ? 'wss:' : 'ws:'
const apiUrl = new URL('/centrifugo/v1/api/publish', process.env.BASE_URL)

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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitForPush(client, predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const found = client.pushes.find(predicate)
    if (found) return found
    await sleep(25)
  }
  throw new Error('timed out waiting for push')
}

async function openClient(token) {
  const ws = new WebSocket(wsUrl, 'centrifuge-json')
  let nextId = 1
  const pending = new Map()
  const pushes = []
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve)
    ws.addEventListener('error', reject)
    ws.addEventListener('close', (event) => {
      if (event.code !== 1000) reject(new Error(`websocket closed with ${event.code}`))
    })
  })
  ws.addEventListener('message', (event) => {
    for (const message of parseMessages(String(event.data))) {
      if (message.id && pending.has(message.id)) {
        pending.get(message.id)(message)
        pending.delete(message.id)
      }
      if (message.push) pushes.push(message.push)
    }
  })
  function send(command) {
    const id = nextId++
    ws.send(JSON.stringify({ id, ...command }))
    return new Promise((resolve) => pending.set(id, resolve))
  }
  await ready
  const connect = await send({ connect: { token } })
  assert.ok(connect.connect, 'connect failed')
  return { ws, send, pushes }
}

async function serverPublish(channel, data) {
  const response = await fetch(apiUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': process.env.API_KEY,
    },
    body: JSON.stringify({ channel, data }),
  })
  assert.equal(response.status, 200, 'server publish failed')
  return response.json()
}

async function closeClient(client) {
  client.ws.close()
  await sleep(100)
}

async function main() {
  const result = {}
  const a = await openClient(process.env.TOKEN_A)
  const b = await openClient(process.env.TOKEN_B)
  const anon = await openClient(process.env.ANON_TOKEN)
  result.connectA = true
  result.connectB = true
  result.connectAnon = true

  const subscribe = await a.send({ subscribe: { channel: channels.basic } })
  result.subscribe = Boolean(subscribe.subscribe && !subscribe.error)
  const unsubscribe = await a.send({ unsubscribe: { channel: channels.basic } })
  result.unsubscribe = Boolean(unsubscribe.unsubscribe && !unsubscribe.error)

  await a.send({ subscribe: { channel: channels.server } })
  await serverPublish(channels.server, { source: 'server' })
  const serverPush = await waitForPush(a, (push) => push.pub?.data?.source === 'server')
  result.serverBroadcast = serverPush.pub.data.source === 'server'

  await a.send({ subscribe: { channel: channels.client } })
  const clientPublish = await a.send({
    publish: { channel: channels.client, data: { source: 'client' } },
  })
  result.clientBroadcastReply = Boolean(clientPublish.publish && !clientPublish.error)
  const clientPush = await waitForPush(a, (push) => push.pub?.data?.source === 'client')
  result.clientBroadcast = clientPush.pub.data.source === 'client'

  await a.send({ subscribe: { channel: channels.presence, join_leave: true } })
  await b.send({ subscribe: { channel: channels.presence } })
  await waitForPush(a, (push) => push.channel === channels.presence && push.join?.info?.user === process.env.USER_B)
  const presence = await a.send({ presence: { channel: channels.presence } })
  const presenceUsers = Object.values(presence.presence?.presence || {}).map((entry) => entry.user)
  result.presence = presenceUsers.includes(process.env.USER_A) && presenceUsers.includes(process.env.USER_B)
  await b.send({ unsubscribe: { channel: channels.presence } })
  await sleep(100)
  const presenceAfterLeave = await a.send({ presence: { channel: channels.presence } })
  result.presenceAfterLeave = Object.keys(presenceAfterLeave.presence?.presence || {}).length === 1

  await a.send({ subscribe: { channel: channels.join, join_leave: true } })
  await b.send({ subscribe: { channel: channels.join } })
  const join = await waitForPush(
    a,
    (push) => push.channel === channels.join && push.join?.info?.user === process.env.USER_B
  )
  result.join = Boolean(join.join)
  await b.send({ unsubscribe: { channel: channels.join } })
  const leave = await waitForPush(
    a,
    (push) => push.channel === channels.join && push.leave?.info?.user === process.env.USER_B
  )
  result.leave = Boolean(leave.leave)

  await anon.send({ subscribe: { channel: channels.anonymous } })
  result.anonymousSubscribe = true
  const anonPublish = await anon.send({
    publish: { channel: channels.anonymous, data: { source: 'anon' } },
  })
  result.anonymousPublishDenied = anonPublish.error?.code === 403
  const anonPresence = await anon.send({ presence: { channel: channels.anonymous } })
  result.anonymousPresenceDenied = anonPresence.error?.code === 103
  const anonHistory = await anon.send({ history: { channel: channels.anonymous, limit: 10 } })
  result.anonymousHistoryDenied = anonHistory.error?.code === 103
  const anonTenant = await anon.send({ subscribe: { channel: channels.tenantA } })
  result.anonymousTenantDenied = anonTenant.error?.code === 403
  const anonUser = await anon.send({ subscribe: { channel: channels.userA } })
  result.anonymousUserDenied = anonUser.error?.code === 403

  await a.send({ subscribe: { channel: channels.history } })
  await a.send({ publish: { channel: channels.history, data: { order: 1 } } })
  await a.send({ publish: { channel: channels.history, data: { order: 2 } } })
  await waitForPush(a, (push) => push.pub?.data?.order === 2)
  const history = await a.send({ history: { channel: channels.history, limit: 10 } })
  const historyOrders = (history.history?.publications || []).map((publication) => publication.data.order)
  result.history = JSON.stringify(historyOrders) === JSON.stringify([1, 2])

  const recoveryClient = await openClient(process.env.TOKEN_A)
  const recoverySubscribe = await recoveryClient.send({
    subscribe: { channel: channels.recovery },
  })
  const epoch = recoverySubscribe.subscribe?.epoch
  const firstPublish = await recoveryClient.send({
    publish: { channel: channels.recovery, data: { order: 1 } },
  })
  assert.ok(firstPublish.publish, 'initial recovery publish failed')
  const firstPush = await waitForPush(recoveryClient, (push) => push.pub?.data?.order === 1)
  const offset = firstPush.pub.offset
  await closeClient(recoveryClient)
  await serverPublish(channels.recovery, { order: 2 })
  const recoveredClient = await openClient(process.env.TOKEN_A)
  const recoveredSubscribe = await recoveredClient.send({
    subscribe: { channel: channels.recovery, recover: true, epoch, offset },
  })
  const recoveredOrders = (recoveredSubscribe.subscribe?.publications || []).map(
    (publication) => publication.data.order
  )
  result.recovery = recoveredSubscribe.subscribe?.recovered === true && recoveredOrders.includes(2)
  await closeClient(recoveredClient)

  const userSelf = await a.send({ subscribe: { channel: channels.userA } })
  result.userSelf = Boolean(userSelf.subscribe && !userSelf.error)
  const userOther = await a.send({ subscribe: { channel: channels.userB } })
  result.userOtherDenied = userOther.error?.code === 403
  const userOtherSelf = await b.send({ subscribe: { channel: channels.userB } })
  result.userOtherSelf = Boolean(userOtherSelf.subscribe && !userOtherSelf.error)

  const tenantSelf = await a.send({ subscribe: { channel: channels.tenantA } })
  result.tenantSelf = Boolean(tenantSelf.subscribe && !tenantSelf.error)
  const tenantOther = await b.send({ subscribe: { channel: channels.tenantB } })
  result.tenantOtherSelf = Boolean(tenantOther.subscribe && !tenantOther.error)
  const tenantCross = await a.send({ subscribe: { channel: channels.tenantB } })
  result.tenantCrossDenied = tenantCross.error?.code === 403
  const tenantCrossPublish = await a.send({
    publish: { channel: channels.tenantB, data: { source: 'tenant-a-cross' } },
  })
  result.tenantCrossPublishDenied = tenantCrossPublish.error?.code === 403
  const tenantCrossPresence = await a.send({ presence: { channel: channels.tenantB } })
  result.tenantCrossPresenceDenied = tenantCrossPresence.error?.code === 103
  const tenantCrossHistory = await a.send({ history: { channel: channels.tenantB, limit: 10 } })
  result.tenantCrossHistoryDenied = tenantCrossHistory.error?.code === 103

  await a.send({ publish: { channel: channels.tenantA, data: { source: 'tenant-a' } } })
  await waitForPush(a, (push) => push.pub?.data?.source === 'tenant-a')
  await sleep(500)
  result.tenantIsolationA = !b.pushes.some((push) => push.pub?.data?.source === 'tenant-a')
  await b.send({ publish: { channel: channels.tenantB, data: { source: 'tenant-b' } } })
  await waitForPush(b, (push) => push.pub?.data?.source === 'tenant-b')
  await sleep(500)
  result.tenantIsolationB = !a.pushes.some((push) => push.pub?.data?.source === 'tenant-b')

  result.deniedSubscribeCode = tenantCross.error?.code === 403

  const invalidCloseCode = await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl, 'centrifuge-json')
    const timer = setTimeout(() => reject(new Error('invalid token timeout')), 5000)
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ id: 1, connect: { token: 'not-a-valid-token' } }))
    })
    ws.addEventListener('close', (event) => {
      clearTimeout(timer)
      resolve(event.code)
    })
    ws.addEventListener('error', () => {})
  })
  result.invalidTokenCode = invalidCloseCode === 3500

  let rateLimited = false
  for (let i = 0; i < 40; i += 1) {
    const publish = await b.send({
      publish: { channel: channels.rate, data: { index: i } },
    })
    if (publish.error?.code === 429) {
      rateLimited = true
      break
    }
    assert.ok(publish.publish, 'rate limit publish failed before the limit')
  }
  result.rateLimited = rateLimited

  for (const client of [a, b, anon]) await closeClient(client)
  process.stdout.write(JSON.stringify(result))
}

main().catch((error) => {
  console.error(error.stack || error.message)
  process.exit(1)
})
NODE
) || node_result="failed"

value() {
    printf '%s' "$node_result" | jq -r ".$1 // false" 2>/dev/null || echo false
}

check "user A connects" "true" "$(value connectA)"
check "user B connects" "true" "$(value connectB)"
check "anonymous connects" "true" "$(value connectAnon)"
check "subscribe succeeds" "true" "$(value subscribe)"
check "unsubscribe succeeds" "true" "$(value unsubscribe)"
check "server broadcast delivered" "true" "$(value serverBroadcast)"
check "authorized client publish succeeds" "true" "$(value clientBroadcastReply)"
check "authorized client broadcast delivered" "true" "$(value clientBroadcast)"
check "presence includes both users" "true" "$(value presence)"
check "unsubscribe updates presence" "true" "$(value presenceAfterLeave)"
check "join event delivered" "true" "$(value join)"
check "leave event delivered" "true" "$(value leave)"
check "anonymous public subscribe allowed" "true" "$(value anonymousSubscribe)"
check "anonymous public publish denied" "true" "$(value anonymousPublishDenied)"
check "anonymous presence denied" "true" "$(value anonymousPresenceDenied)"
check "anonymous history denied" "true" "$(value anonymousHistoryDenied)"
check "anonymous tenant subscribe denied" "true" "$(value anonymousTenantDenied)"
check "anonymous user subscribe denied" "true" "$(value anonymousUserDenied)"
check "history returns ordered publications" "true" "$(value history)"
check "recovery replays missed publication" "true" "$(value recovery)"
check "user private channel allowed" "true" "$(value userSelf)"
check "other user private channel denied" "true" "$(value userOtherDenied)"
check "second user private channel allowed" "true" "$(value userOtherSelf)"
check "tenant channel allowed" "true" "$(value tenantSelf)"
check "second tenant channel allowed" "true" "$(value tenantOtherSelf)"
check "cross-tenant subscribe denied" "true" "$(value tenantCrossDenied)"
check "cross-tenant publish denied" "true" "$(value tenantCrossPublishDenied)"
check "cross-tenant presence denied" "true" "$(value tenantCrossPresenceDenied)"
check "cross-tenant history denied" "true" "$(value tenantCrossHistoryDenied)"
check "tenant A publication isolated" "true" "$(value tenantIsolationA)"
check "tenant B publication isolated" "true" "$(value tenantIsolationB)"
check "denied subscription maps to 403" "true" "$(value deniedSubscribeCode)"
check "invalid token maps to 3500" "true" "$(value invalidTokenCode)"
check "publish rate limit maps to 429" "true" "$(value rateLimited)"

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
