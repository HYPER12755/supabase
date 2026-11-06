#!/bin/sh
set -eu

DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
TENANT_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER_TENANT_ID="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
RUN="$$-$(date +%s)"
CHANNEL="public:sql-${RUN}"
BROADCAST_TABLE="sql_$$"
BROADCAST_CHANNEL="tenant:${TENANT_ID}:table:${BROADCAST_TABLE}"

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker not found."
    exit 1
fi

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

expect_error() {
    test_name="$1"
    statement="$2"

    if psql_db -c "$statement" >/dev/null 2>&1; then
        check "$test_name" "denied" "allowed"
    else
        check "$test_name" "denied" "denied"
    fi
}

cleanup() {
    psql_db -c "DELETE FROM centrifugo.outbox WHERE channel IN ('$CHANNEL', '$BROADCAST_CHANNEL')" >/dev/null 2>&1 || true
    psql_db -c "DELETE FROM centrifugo.dead_letter WHERE channel IN ('$CHANNEL', '$BROADCAST_CHANNEL')" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

VALID_UUID="123e4567-e89b-42d3-a456-426614174000"
UPPER_UUID="123E4567-E89B-42D3-A456-426614174000"
V1_UUID="123e4567-e89b-12d3-a456-426614174000"
V5_UUID="123e4567-e89b-52d3-b456-426614174000"
INVALID_VERSION_UUID="123e4567-e89b-02d3-a456-426614174000"
INVALID_VARIANT_UUID="123e4567-e89b-42d3-c456-426614174000"
PUBLIC_128="0$(printf '%0127d' 0)"
PUBLIC_129="0$(printf '%0128d' 0)"
TENANT_SEGMENT_61="0$(printf '%060d' 0)"
TENANT_SEGMENT_65="0$(printf '%064d' 0)"
TENANT_LONG_TOTAL="tenant:${VALID_UUID}:${TENANT_SEGMENT_61}:${TENANT_SEGMENT_61}:${TENANT_SEGMENT_61}:${TENANT_SEGMENT_61}"

echo ""
echo "=== Centrifugo SQL helper tests ==="
echo ""

echo "--- UUID validation ---"
check "is_uuid accepts version 1" "t" "$(psql_scalar "SELECT centrifugo.is_uuid('$V1_UUID')")"
check "is_uuid accepts version 4" "t" "$(psql_scalar "SELECT centrifugo.is_uuid('$VALID_UUID')")"
check "is_uuid accepts version 5" "t" "$(psql_scalar "SELECT centrifugo.is_uuid('$V5_UUID')")"
check "is_uuid accepts uppercase" "t" "$(psql_scalar "SELECT centrifugo.is_uuid('$UPPER_UUID')")"
check "is_uuid rejects version 0" "f" "$(psql_scalar "SELECT centrifugo.is_uuid('$INVALID_VERSION_UUID')")"
check "is_uuid rejects invalid variant" "f" "$(psql_scalar "SELECT centrifugo.is_uuid('$INVALID_VARIANT_UUID')")"
check "is_uuid rejects nil" "f" "$(psql_scalar "SELECT centrifugo.is_uuid('00000000-0000-0000-0000-000000000000')")"

echo ""
echo "--- Channel validation ---"
check "public channel" "t" "$(psql_scalar "SELECT centrifugo.channel_is_valid('public:rooms')")"
check "public segment at 128 characters" "t" "$(psql_scalar "SELECT centrifugo.channel_is_valid('public:$PUBLIC_128')")"
check "public segment over 128 characters" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('public:$PUBLIC_129')")"
check "public channel rejects slash" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('public:rooms/sub')")"
check "public channel rejects empty segment" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('public:')")"
check "channel rejects NULL" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid(NULL)")"
check "user channel" "t" "$(psql_scalar "SELECT centrifugo.channel_is_valid('user:$VALID_UUID')")"
check "user channel rejects non-UUID" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('user:not-a-uuid')")"
check "tenant channel" "t" "$(psql_scalar "SELECT centrifugo.channel_is_valid('$BROADCAST_CHANNEL')")"
check "tenant channel accepts additional segments" "t" "$(psql_scalar "SELECT centrifugo.channel_is_valid('tenant:$VALID_UUID:table:messages:extra:more')")"
check "tenant channel rejects too many segments" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('tenant:$VALID_UUID:table:messages:extra:more:again')")"
check "tenant channel rejects 65-character segment" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('tenant:$VALID_UUID:$TENANT_SEGMENT_65')")"
check "channel rejects total length over 255" "f" "$(psql_scalar "SELECT centrifugo.channel_is_valid('$TENANT_LONG_TOTAL')")"

echo ""
echo "--- Authorization decisions ---"
check "public subscribe is anonymous" "t" \
    "$(psql_scalar "SELECT centrifugo.authorize('public:rooms', jsonb_build_object('action', 'subscribe'))")"
check "public publish rejects anonymous" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('public:rooms', jsonb_build_object('action', 'publish'))")"
check "public publish accepts authenticated user" "t" \
    "$(psql_scalar "SELECT centrifugo.authorize('public:rooms', jsonb_build_object('action', 'publish', 'role', 'authenticated', 'sub', '$VALID_UUID'))")"
check "public publish rejects non-UUID subject" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('public:rooms', jsonb_build_object('action', 'publish', 'role', 'authenticated', 'sub', 'not-a-uuid'))")"
check "user subscribes to own channel" "t" \
    "$(psql_scalar "SELECT centrifugo.authorize('user:$VALID_UUID', jsonb_build_object('action', 'subscribe', 'role', 'authenticated', 'sub', '$VALID_UUID'))")"
check "user cannot subscribe to another channel" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('user:$OTHER_TENANT_ID', jsonb_build_object('action', 'subscribe', 'role', 'authenticated', 'sub', '$VALID_UUID'))")"
check "tenant subscribes with app_metadata" "t" \
    "$(psql_scalar "SELECT centrifugo.authorize('$BROADCAST_CHANNEL', jsonb_build_object('action', 'subscribe', 'role', 'authenticated', 'sub', '$VALID_UUID', 'app_metadata', jsonb_build_object('tenant_id', '$TENANT_ID')))")"
check "tenant subscribes with top-level tenant" "t" \
    "$(psql_scalar "SELECT centrifugo.authorize('$BROADCAST_CHANNEL', jsonb_build_object('action', 'subscribe', 'role', 'authenticated', 'sub', '$VALID_UUID', 'tenant_id', '$TENANT_ID'))")"
check "tenant rejects another tenant" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('$BROADCAST_CHANNEL', jsonb_build_object('action', 'subscribe', 'role', 'authenticated', 'sub', '$VALID_UUID', 'app_metadata', jsonb_build_object('tenant_id', '$OTHER_TENANT_ID')))")"
check "authorization rejects user_metadata tenant" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('$BROADCAST_CHANNEL', jsonb_build_object('action', 'subscribe', 'role', 'authenticated', 'sub', '$VALID_UUID', 'user_metadata', jsonb_build_object('tenant_id', '$TENANT_ID')))")"
check "authorization rejects unknown action" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('public:rooms', jsonb_build_object('action', 'delete'))")"
check "authorization rejects invalid channel" "f" \
    "$(psql_scalar "SELECT centrifugo.authorize('not a channel', jsonb_build_object('action', 'subscribe'))")"

echo ""
echo "--- Send validation ---"
expect_error "send rejects invalid channel" "SELECT centrifugo.send('not a channel', '{}'::jsonb)"
expect_error "send rejects non-object payload" "SELECT centrifugo.send('$CHANNEL', '[]'::jsonb)"
expect_error "send rejects invalid event" "SELECT centrifugo.send('$CHANNEL', '{}'::jsonb, 'bad event')"
expect_error "send rejects tenant mismatch" "SELECT centrifugo.send('$BROADCAST_CHANNEL', '{}'::jsonb, 'message', '$OTHER_TENANT_ID'::uuid)"

message_id=$(psql_scalar "SELECT centrifugo.send('$CHANNEL', jsonb_build_object('ok', true))")
check "send returns a UUID" "t" "$(psql_scalar "SELECT centrifugo.is_uuid('$message_id')")"
check "send stores one row" "1" "$(psql_scalar "SELECT count(*) FROM centrifugo.outbox WHERE message_id = '$message_id'")"
duplicate_id=$(psql_scalar "SELECT centrifugo.send('$CHANNEL', jsonb_build_object('ok', true), 'message', NULL, '$message_id'::uuid)")
check "send is idempotent" "$message_id" "$duplicate_id"
check "duplicate send keeps one row" "1" "$(psql_scalar "SELECT count(*) FROM centrifugo.outbox WHERE message_id = '$message_id'")"

echo ""
echo "--- Change broadcast validation ---"
expect_error "broadcast rejects unsupported operation" "SELECT centrifugo.broadcast_changes('public', '$BROADCAST_TABLE', 'TRUNCATE', jsonb_build_object('tenant_id', '$TENANT_ID'), 'tenant_id')"
expect_error "broadcast rejects invalid schema" "SELECT centrifugo.broadcast_changes('bad schema', '$BROADCAST_TABLE', 'INSERT', jsonb_build_object('tenant_id', '$TENANT_ID'), 'tenant_id')"
expect_error "broadcast rejects invalid table" "SELECT centrifugo.broadcast_changes('public', 'bad-table', 'INSERT', jsonb_build_object('tenant_id', '$TENANT_ID'), 'tenant_id')"
expect_error "broadcast rejects invalid tenant column" "SELECT centrifugo.broadcast_changes('public', '$BROADCAST_TABLE', 'INSERT', jsonb_build_object('tenant_id', '$TENANT_ID'), 'Tenant')"
expect_error "broadcast rejects non-object row" "SELECT centrifugo.broadcast_changes('public', '$BROADCAST_TABLE', 'INSERT', '[]'::jsonb, 'tenant_id')"
expect_error "broadcast rejects missing tenant" "SELECT centrifugo.broadcast_changes('public', '$BROADCAST_TABLE', 'INSERT', '{}'::jsonb, 'tenant_id')"

broadcast_id=$(psql_scalar "SELECT centrifugo.broadcast_changes('public', '$BROADCAST_TABLE', 'INSERT', jsonb_build_object('tenant_id', '$TENANT_ID'), 'tenant_id')")
check "broadcast returns a UUID" "t" "$(psql_scalar "SELECT centrifugo.is_uuid('$broadcast_id')")"
check "broadcast channel is tenant scoped" "$BROADCAST_CHANNEL" \
    "$(psql_scalar "SELECT channel FROM centrifugo.outbox WHERE message_id = '$broadcast_id'")"
check "broadcast populates tenant id" "$TENANT_ID" \
    "$(psql_scalar "SELECT tenant_id FROM centrifugo.outbox WHERE message_id = '$broadcast_id'")"
check "broadcast default payload omits row data" "f" \
    "$(psql_scalar "SELECT payload ? 'record' FROM centrifugo.outbox WHERE message_id = '$broadcast_id'")"

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
