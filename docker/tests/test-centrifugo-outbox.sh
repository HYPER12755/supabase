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
SERVICE_ROLE_KEY=$(unquote "$(read_env SERVICE_ROLE_KEY)")

if [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ] || [ -z "$BASE_URL" ]; then
    echo "Error: required keys or base URL are missing."
    exit 1
fi

OUTBOX_CONTAINER="supabase-centrifugo-outbox"
OUTBOX_CONTAINER_2="supabase-centrifugo-outbox-2"
OUTBOX_CONTAINERS="$OUTBOX_CONTAINER"
DB_CONTAINER="supabase-db"
TEST_TABLE="centrifugo_outbox_test"
TEST_TENANT_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER_TENANT_ID="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
TEST_EMAIL="centrifugo-outbox-$$@example.com"
TEST_PASSWORD="centrifugo-outbox-password-123456"
TEST_USER_ID=""

if ! docker inspect "$OUTBOX_CONTAINER" >/dev/null 2>&1; then
    echo "SKIP: $OUTBOX_CONTAINER is not running."
    exit 0
fi
if docker inspect "$OUTBOX_CONTAINER_2" >/dev/null 2>&1; then
    OUTBOX_CONTAINERS="$OUTBOX_CONTAINERS $OUTBOX_CONTAINER_2"
fi

start_outboxes() {
    for container in $OUTBOX_CONTAINERS; do
        docker start "$container" >/dev/null 2>&1 || true
    done
}

stop_outboxes() {
    for container in $OUTBOX_CONTAINERS; do
        docker stop "$container" >/dev/null 2>&1 || true
    done
}

psql_db() {
    docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -Atq "$@"
}

clean_test_rows() {
    psql_db -c "DELETE FROM centrifugo.outbox WHERE channel LIKE 'tenant:${TEST_TENANT_ID}:%' OR channel LIKE 'tenant:${OTHER_TENANT_ID}:%' OR channel LIKE 'public:outbox-%'" >/dev/null 2>&1 || true
    psql_db -c "DELETE FROM centrifugo.dead_letter WHERE tenant_id IN ('${TEST_TENANT_ID}', '${OTHER_TENANT_ID}') OR channel LIKE 'public:outbox-%'" >/dev/null 2>&1 || true
}

cleanup() {
    start_outboxes
    psql_db -c "DROP TRIGGER IF EXISTS ${TEST_TABLE}_changes ON public.${TEST_TABLE}" >/dev/null 2>&1 || true
    psql_db -c "DROP TABLE IF EXISTS public.${TEST_TABLE}" >/dev/null 2>&1 || true
    psql_db -c "DELETE FROM centrifugo.full_payload_tables WHERE schema_name = 'public' AND table_name = '${TEST_TABLE}'" >/dev/null 2>&1 || true
    clean_test_rows
    if [ -n "$TEST_USER_ID" ]; then
        curl -s -o /dev/null -X DELETE \
            "$BASE_URL/auth/v1/admin/users/$TEST_USER_ID" \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" || true
    fi
}
trap cleanup EXIT HUP INT TERM

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

echo ""
echo "=== Centrifugo outbox tests against $BASE_URL ==="
echo ""

echo "--- Setup ---"
psql_db -c "DROP TRIGGER IF EXISTS ${TEST_TABLE}_changes ON public.${TEST_TABLE}" >/dev/null 2>&1 || true
psql_db -c "DROP TABLE IF EXISTS public.${TEST_TABLE}" >/dev/null 2>&1 || true
psql_db -c "SET ROLE postgres; CREATE TABLE public.${TEST_TABLE} (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tenant_id uuid NOT NULL, body text NOT NULL); CREATE TRIGGER ${TEST_TABLE}_changes AFTER INSERT OR UPDATE OR DELETE ON public.${TEST_TABLE} FOR EACH ROW EXECUTE FUNCTION centrifugo.broadcast_changes_trigger('tenant_id')" >/dev/null
clean_test_rows
check "test table and trigger created" "created" "created"

create_response=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/admin/users" \
    -X POST \
    -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"email_confirm\":true,\"app_metadata\":{\"tenant_id\":\"$TEST_TENANT_ID\"}}")
TEST_USER_ID=$(printf '%s' "$create_response" | jq -r '.id // empty' 2>/dev/null || true)
check "test user created" "created" "$([ -n "$TEST_USER_ID" ] && echo created || echo failed)"

session_response=$(curl -s --max-time 10 \
    "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
ACCESS_TOKEN=$(printf '%s' "$session_response" | jq -r '.access_token // empty' 2>/dev/null || true)
check "test user session created" "created" "$([ -n "$ACCESS_TOKEN" ] && echo created || echo failed)"

if [ -z "$ACCESS_TOKEN" ]; then
    echo "=== Results: $pass passed, $fail failed ==="
    exit 1
fi

token_response=$(curl -s --max-time 10 \
    "$BASE_URL/centrifugo/v1/auth/token" \
    -X POST \
    -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $ACCESS_TOKEN")
USER_TOKEN=$(printf '%s' "$token_response" | jq -r '.token // empty' 2>/dev/null || true)
check "centrifugo token issued" "issued" "$([ -n "$USER_TOKEN" ] && echo issued || echo failed)"

if [ -z "$USER_TOKEN" ]; then
    echo "=== Results: $pass passed, $fail failed ==="
    exit 1
fi

node_result=$(TOKEN="$USER_TOKEN" BASE_URL="$BASE_URL" TENANT="$TEST_TENANT_ID" OTHER_TENANT="$OTHER_TENANT_ID" TABLE="$TEST_TABLE" OUTBOX_CONTAINERS="$OUTBOX_CONTAINERS" node - <<'NODE'
const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')

function sql(statement) {
  return execFileSync(
    'docker',
    [
      'exec',
      '-i',
      'supabase-db',
      'psql',
      '-U',
      'supabase_admin',
      '-d',
      'postgres',
      '-v',
      'ON_ERROR_STOP=1',
      '-Atq',
      '-c',
      statement,
    ],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
  ).trim()
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

const outboxContainers = process.env.OUTBOX_CONTAINERS.split(' ').filter(Boolean)

function stopOutboxes() {
  for (const container of outboxContainers) {
    execFileSync('docker', ['stop', container], { stdio: 'ignore' })
  }
}

function startOutboxes() {
  for (const container of outboxContainers) {
    execFileSync('docker', ['start', container], { stdio: 'ignore' })
  }
}

const channel = `tenant:${process.env.TENANT}:table:${process.env.TABLE}`
const wsUrl = new URL('/centrifugo/v1/connection/websocket', process.env.BASE_URL)
wsUrl.protocol = wsUrl.protocol === 'https:' ? 'wss:' : 'ws:'

const ws = new WebSocket(wsUrl, 'centrifuge-json')
const timer = setTimeout(() => process.exit(1), 30000)
let nextId = 1
const pending = new Map()
const publications = []
let publicationWaiter = null

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

function waitForPublications(count, timeoutMs = 12000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs
    const check = () => {
      if (publications.length >= count) {
        publicationWaiter = null
        resolve()
        return
      }
      if (Date.now() > deadline) {
        publicationWaiter = null
        reject(new Error(`timed out waiting for ${count} publications`))
        return
      }
      publicationWaiter = check
      setTimeout(check, 100)
    }
    check()
  })
}

ws.addEventListener('message', (event) => {
  for (const message of parseMessages(String(event.data))) {
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message)
      pending.delete(message.id)
    }
    if (message.push && message.push.pub && message.push.pub.data) {
      publications.push(message.push.pub.data)
      if (publicationWaiter) publicationWaiter()
    }
  }
})

ws.addEventListener('error', () => process.exit(1))

ws.addEventListener('open', async () => {
  try {
    const connect = await send({ connect: { token: process.env.TOKEN } })
    assert.ok(connect.connect, 'connect failed')

    const subscribe = await send({ subscribe: { channel } })
    assert.ok(subscribe.subscribe && !subscribe.error, 'subscribe failed')

    sql(`INSERT INTO public.${process.env.TABLE} (tenant_id, body) VALUES ('${process.env.TENANT}', 'insert-body')`)
    await waitForPublications(1)
    assert.equal(publications[0].event, 'insert')
    assert.equal(publications[0].record, undefined)
    assert.equal(publications[0].old_record, undefined)
    assert.ok(publications[0].message_id)
    const insertMessageId = publications[0].message_id

    stopOutboxes()
    sql(`UPDATE public.${process.env.TABLE} SET body = 'update-body' WHERE tenant_id = '${process.env.TENANT}'`)
    await sleep(500)
    const pendingAfterStop = Number(
      sql(`SELECT count(*) FROM centrifugo.outbox WHERE published_at IS NULL AND channel = '${channel}'`)
    )
    assert.equal(pendingAfterStop, 1, 'pending row was not preserved while stopped')
    startOutboxes()
    await waitForPublications(2)
    assert.equal(publications[1].event, 'update')
    assert.equal(publications[1].record, undefined)
    assert.equal(publications[1].old_record, undefined)

    sql(`DELETE FROM public.${process.env.TABLE} WHERE tenant_id = '${process.env.TENANT}'`)
    await waitForPublications(3)
    assert.equal(publications[2].event, 'delete')
    assert.equal(publications[2].record, undefined)

    sql(`INSERT INTO centrifugo.full_payload_tables (schema_name, table_name) VALUES ('public', '${process.env.TABLE}') ON CONFLICT DO NOTHING`)
    sql(`INSERT INTO public.${process.env.TABLE} (tenant_id, body) VALUES ('${process.env.TENANT}', 'full-body')`)
    await waitForPublications(4)
    assert.equal(publications[3].event, 'insert')
    assert.equal(publications[3].record.body, 'full-body')
    sql(`DELETE FROM centrifugo.full_payload_tables WHERE schema_name = 'public' AND table_name = '${process.env.TABLE}'`)

    const beforeOtherTenant = publications.length
    sql(`INSERT INTO public.${process.env.TABLE} (tenant_id, body) VALUES ('${process.env.OTHER_TENANT}', 'other-tenant-body')`)
    await sleep(2000)
    assert.equal(publications.length, beforeOtherTenant, 'cross-tenant row was published to this tenant')

    const messageIds = new Set(publications.map((item) => item.message_id))
    assert.equal(messageIds.size, publications.length, 'message ids were not unique')

    clearTimeout(timer)
    ws.close()
    process.stdout.write(JSON.stringify({
      published: publications.length,
      insertMessageId,
      notificationOnly: true,
      crossTenantBlocked: true,
      restartPreserved: true,
    }))
    process.exit(0)
  } catch (error) {
    clearTimeout(timer)
    console.error(error.stack || error.message)
    process.exit(1)
  }
})
NODE
) || node_result="failed"

check "consumer publishes insert, update, delete, and allowlisted row" "4" "$(printf '%s' "$node_result" | jq -r '.published // 0' 2>/dev/null || echo 0)"
check "notification-only default hides row data" "true" "$(printf '%s' "$node_result" | jq -r '.notificationOnly // false' 2>/dev/null || echo false)"
check "consumer restart preserves pending rows" "true" "$(printf '%s' "$node_result" | jq -r '.restartPreserved // false' 2>/dev/null || echo false)"
check "cross-tenant row is not published to the wrong channel" "true" "$(printf '%s' "$node_result" | jq -r '.crossTenantBlocked // false' 2>/dev/null || echo false)"

if [ "$node_result" = "failed" ]; then
    start_outboxes
fi

echo ""
echo "--- Duplicate publish safety ---"
psql_db -c "SELECT centrifugo.send('public:outbox-duplicate', '{}'::jsonb, 'test', NULL, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd')" >/dev/null
psql_db -c "SELECT centrifugo.send('public:outbox-duplicate', '{}'::jsonb, 'test', NULL, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd')" >/dev/null
psql_json=$(psql_db -c "SELECT count(*) FROM centrifugo.outbox WHERE message_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'")
check "duplicate send keeps one row" "1" "$psql_json"

echo ""
echo "--- Dead-letter path ---"
stop_outboxes
clean_test_rows
psql_db -c "SELECT centrifugo.send('public:outbox-poison', '{\"event\":\"test\"}'::jsonb, 'test')" >/dev/null
NETWORK=$(docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}{{end}}' "$OUTBOX_CONTAINER" 2>/dev/null || true)
if [ -n "$NETWORK" ]; then
    docker run --rm --network "$NETWORK" --env-file .env.centrifugo \
        -e CENTRIFUGO_HTTP_API_URL="http://127.0.0.1:1" \
        -e CENTRIFUGO_OUTBOX_MAX_ATTEMPTS="1" \
        -e CENTRIFUGO_OUTBOX_METRICS_PORT="19100" \
        -e CENTRIFUGO_OUTBOX_WORKER_ID="outbox-poison-test" \
        supabase/centrifugo-outbox:0.1.0 \
        sh -c 'timeout 8 node src/server.js' >/dev/null 2>&1 || true
fi
start_outboxes
dead_count=$(psql_db -c "SELECT count(*) FROM centrifugo.dead_letter WHERE channel = 'public:outbox-poison'")
outbox_count=$(psql_db -c "SELECT count(*) FROM centrifugo.outbox WHERE published_at IS NULL AND channel = 'public:outbox-poison'")
check "poison message moved to dead-letter" "1" "$dead_count"
check "poison message removed from outbox" "0" "$outbox_count"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
