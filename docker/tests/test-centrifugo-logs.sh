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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
echo "=== Centrifugo log pipeline checks passed ==="
