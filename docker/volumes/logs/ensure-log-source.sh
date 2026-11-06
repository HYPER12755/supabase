#!/bin/sh
#
# Ensure a Logflare source exists and is accepting events before Vector starts.
#
# Logflare only seeds its built-in Supabase sources. A source added through the
# management API is persisted, but the ingest cache can keep returning 401 for
# the source name until the cache expires or Logflare restarts. Creating the
# source before Vector starts avoids caching a missing-source result.
#
# Usage:
#   ensure-log-source.sh <source-name>

set -eu

SOURCE_NAME="${1:?source name is required}"
: "${LOGFLARE_PUBLIC_ACCESS_TOKEN:?LOGFLARE_PUBLIC_ACCESS_TOKEN is required}"
: "${LOGFLARE_PRIVATE_ACCESS_TOKEN:?LOGFLARE_PRIVATE_ACCESS_TOKEN is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"

source_count() {
    psql -v ON_ERROR_STOP=1 -v source_name="$SOURCE_NAME" -Atq <<'SQL'
SELECT count(*) FROM _analytics.sources WHERE name = :'source_name';
SQL
}

echo "Ensuring Logflare source exists: $SOURCE_NAME"
if ! count=$(source_count); then
    echo "Could not query Logflare sources" >&2
    exit 1
fi
if [ "$count" -eq 0 ]; then
    # Logflare's create response can fail while still persisting the source in
    # the Postgres backend. Verify the row below instead of trusting the status.
    curl -s --max-time 10 -o /dev/null \
        -X POST "http://analytics:4000/api/sources" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $LOGFLARE_PRIVATE_ACCESS_TOKEN" \
        -d "{\"name\":\"$SOURCE_NAME\"}" \
        || true
fi

if ! count=$(source_count); then
    echo "Could not query Logflare sources" >&2
    exit 1
fi
if [ "$count" -eq 0 ]; then
    echo "Logflare source was not created: $SOURCE_NAME" >&2
    exit 1
fi

attempt=0
while [ "$attempt" -lt 60 ]; do
    status=$(
        curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
            -X POST "http://analytics:4000/api/logs?source_name=$SOURCE_NAME" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $LOGFLARE_PUBLIC_ACCESS_TOKEN" \
            -d "[{\"event_message\":\"log source ready\",\"metadata\":{\"service\":\"logs-init\"}}]" \
            || true
    )
    if [ "$status" = "200" ]; then
        echo "Logflare source is ready: $SOURCE_NAME"
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 1
done

echo "Logflare source did not become ingestible: $SOURCE_NAME" >&2
exit 1
