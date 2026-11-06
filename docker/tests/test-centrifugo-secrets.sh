#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
GENERATOR="$SCRIPT_DIR/../utils/generate-centrifugo-keys.sh"

for cmd in openssl mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found."
        exit 1
    fi
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
mkdir -p "$TMP_DIR/utils"
cp "$GENERATOR" "$TMP_DIR/utils/generate-centrifugo-keys.sh"
printf 'POSTGRES_HOST=db\nPOSTGRES_PORT=5432\nPOSTGRES_DB=postgres\n' > "$TMP_DIR/.env"

ENV_FILE="$TMP_DIR/.env.centrifugo"
SCALE_ENV_FILE="$TMP_DIR/.env.centrifugo-scale"
OUTPUT_FILE="$TMP_DIR/output"
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

mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo unknown
}

value_of() {
    grep "^$2=" "$1" | head -n 1 | cut -d= -f2- | tr -d '\r'
}

echo ""
echo "=== Centrifugo secret generation tests ==="
echo ""

if sh "$TMP_DIR/utils/generate-centrifugo-keys.sh" >"$OUTPUT_FILE" 2>&1; then
    check "generator exits successfully" "true" "true"
else
    check "generator exits successfully" "true" "false"
    sed -n '1,20p' "$OUTPUT_FILE"
    exit 1
fi

check "base env file created" "true" "$([ -f "$ENV_FILE" ] && echo true || echo false)"
check "scale env file created" "true" "$([ -f "$SCALE_ENV_FILE" ] && echo true || echo false)"
check "base env file mode" "600" "$(mode "$ENV_FILE")"
check "scale env file mode" "600" "$(mode "$SCALE_ENV_FILE")"

token_secret=$(value_of "$ENV_FILE" CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY)
http_api_key=$(value_of "$ENV_FILE" CENTRIFUGO_HTTP_API_KEY)
auth_db_password=$(value_of "$ENV_FILE" CENTRIFUGO_AUTH_DB_PASSWORD)
outbox_db_password=$(value_of "$ENV_FILE" CENTRIFUGO_OUTBOX_DB_PASSWORD)
redis_password=$(value_of "$SCALE_ENV_FILE" CENTRIFUGO_ENGINE_REDIS_PASSWORD)

for pair in \
    "connection token secret:$token_secret:64" \
    "HTTP API key:$http_api_key:64" \
    "auth database password:$auth_db_password:48" \
    "outbox database password:$outbox_db_password:48" \
    "Redis password:$redis_password:48"; do
    name=${pair%%:*}
    rest=${pair#*:}
    value=${rest%:*}
    length=${rest##*:}
    case "$value" in
        *[!0-9a-f]*|"")
            check "$name format" "hex" "invalid"
            ;;
        *)
            check "$name length" "$length" "${#value}"
            ;;
    esac
done

printf '%s\n' "$token_secret" "$http_api_key" "$auth_db_password" "$outbox_db_password" "$redis_password" > "$SECRET_FILE"
if grep -Fq -f "$SECRET_FILE" "$OUTPUT_FILE"; then
    check "generator output excludes secrets" "clean" "leaked"
else
    check "generator output excludes secrets" "clean" "clean"
fi

check "scale file reuses one Redis password" "3" \
    "$(grep -Fc "$redis_password" "$SCALE_ENV_FILE")"

before_checksum=$(cksum "$ENV_FILE" "$SCALE_ENV_FILE" | awk '{print $1 ":" $2}' | paste -sd, -)
if sh "$TMP_DIR/utils/generate-centrifugo-keys.sh" >"$TMP_DIR/output-second" 2>&1; then
    check "existing files are not overwritten" "refused" "overwritten"
else
    check "existing files are not overwritten" "refused" "refused"
fi
after_checksum=$(cksum "$ENV_FILE" "$SCALE_ENV_FILE" | awk '{print $1 ":" $2}' | paste -sd, -)
check "refused run leaves files unchanged" "$before_checksum" "$after_checksum"

old_token_secret="$token_secret"
if sh "$TMP_DIR/utils/generate-centrifugo-keys.sh" --force >"$TMP_DIR/output-force" 2>&1; then
    check "--force replaces files" "true" "true"
else
    check "--force replaces files" "true" "false"
fi
new_token_secret=$(value_of "$ENV_FILE" CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY)
check "--force rotates the connection token secret" "true" \
    "$([ -n "$new_token_secret" ] && [ "$new_token_secret" != "$old_token_secret" ] && echo true || echo false)"
check "--force preserves a backup" "true" "$([ -f "$ENV_FILE.old" ] && echo true || echo false)"
check "backup env file mode" "600" "$(mode "$ENV_FILE.old")"

printf '%s\n' "$new_token_secret" "$(value_of "$ENV_FILE" CENTRIFUGO_HTTP_API_KEY)" > "$SECRET_FILE"
if grep -Fq -f "$SECRET_FILE" "$TMP_DIR/output-force"; then
    check "forced generator output excludes secrets" "clean" "leaked"
else
    check "forced generator output excludes secrets" "clean" "clean"
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
