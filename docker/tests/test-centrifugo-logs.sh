#!/bin/sh
#
# Validate the Centrifugo Vector pipeline and its unit tests.
#
# Usage:
#   sh tests/test-centrifugo-logs.sh
#
# Prerequisites:
#   - docker
#

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
VECTOR_DIR="$SCRIPT_DIR/../volumes/logs"
VECTOR_IMAGE="timberio/vector:0.53.0-alpine"
LOGFLARE_SOURCE="centrifugo.logs.prod"

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker not found."
    exit 1
fi

echo "--- Vector validation ---"
docker run --rm \
    -e LOGFLARE_PUBLIC_ACCESS_TOKEN=test \
    -v "$VECTOR_DIR:/etc/vector:ro" \
    "$VECTOR_IMAGE" validate --no-environment /etc/vector/vector.yml

echo ""
echo "--- Vector unit tests ---"
docker run --rm \
    -e LOGFLARE_PUBLIC_ACCESS_TOKEN=test \
    -v "$VECTOR_DIR:/etc/vector:ro" \
    "$VECTOR_IMAGE" test /etc/vector/vector.yml /etc/vector/centrifugo-tests.yml

echo ""
echo "--- Logflare source ---"
if grep -Fq "source_name=$LOGFLARE_SOURCE" "$VECTOR_DIR/vector.yml"; then
    echo "  PASS: Centrifugo sink targets $LOGFLARE_SOURCE"
else
    echo "  FAIL: Centrifugo sink does not target $LOGFLARE_SOURCE"
    exit 1
fi

if docker inspect supabase-vector >/dev/null 2>&1; then
    if docker exec supabase-vector wget -qO- http://127.0.0.1:9001/health >/dev/null 2>&1; then
        echo "  PASS: running Vector health endpoint"
    else
        echo "  FAIL: running Vector health endpoint"
        exit 1
    fi
else
    echo "  SKIP: supabase-vector is not running"
fi

echo ""
echo "--- Live Logflare delivery ---"
if ! docker inspect supabase-analytics >/dev/null 2>&1; then
    echo "  SKIP: supabase-analytics is not running"
elif ! docker inspect supabase-centrifugo-auth >/dev/null 2>&1; then
    echo "  SKIP: supabase-centrifugo-auth is not running"
else
    source_token=$(
        docker exec -i supabase-db psql -U supabase_admin -d _supabase -Atq \
            -c "SELECT replace(token::text, '-', '_') FROM _analytics.sources WHERE name = '$LOGFLARE_SOURCE' ORDER BY id DESC LIMIT 1"
    )
    if [ -z "$source_token" ]; then
        echo "  FAIL: $LOGFLARE_SOURCE is not provisioned"
        exit 1
    fi

    if ! docker exec supabase-centrifugo-auth node -e \
        "fetch('http://127.0.0.1:8090/auth/token', { method: 'POST', headers: { apikey: 'invalid-log-pipeline-key' } }).then(() => process.exit(0)).catch(() => process.exit(1))" \
        >/dev/null 2>&1; then
        echo "  FAIL: could not generate an auth log event"
        exit 1
    fi

    attempt=0
    delivered=0
    while [ "$attempt" -lt 30 ]; do
        count=$(
            docker exec -i supabase-db psql -U supabase_admin -d _supabase -Atq \
                -c "SELECT count(*) FROM _analytics.log_events_$source_token WHERE event_message = 'request_denied' AND body->'metadata'->>'reason' = 'invalid_apikey' AND body->'metadata'->>'instance' = 'supabase-centrifugo-auth' AND timestamp >= now() - interval '2 minutes'"
        )
        if [ "$count" -gt 0 ]; then
            delivered=1
            break
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    if [ "$delivered" -eq 1 ]; then
        echo "  PASS: auth logs are delivered to $LOGFLARE_SOURCE"
    else
        echo "  FAIL: auth logs were not delivered to $LOGFLARE_SOURCE"
        exit 1
    fi

    health_count=$(
        docker exec -i supabase-db psql -U supabase_admin -d _supabase -Atq \
            -c "SELECT count(*) FROM _analytics.log_events_$source_token WHERE body->'metadata'->>'path' = '/health'"
    )
    if [ "$health_count" -eq 0 ]; then
        echo "  PASS: health-check logs are filtered"
    else
        echo "  FAIL: health-check logs reached $LOGFLARE_SOURCE"
        exit 1
    fi
fi

echo ""
echo "=== Centrifugo log pipeline checks passed ==="
