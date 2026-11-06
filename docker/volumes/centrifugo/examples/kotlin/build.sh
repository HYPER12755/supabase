#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
DEPS="$BUILD/deps"
mkdir -p "$DEPS"

verify() {
  local name="$1"
  local checksum="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$checksum" "$DEPS/$name" | sha256sum -c - >/dev/null
  else
    printf '%s  %s\n' "$checksum" "$DEPS/$name" | shasum -a 256 -c - >/dev/null
  fi
}

download() {
  local name="$1"
  local url="$2"
  local checksum="$3"
  if [[ -f "$DEPS/$name" ]] && ! verify "$name" "$checksum"; then
    rm -f "$DEPS/$name"
  fi
  if [[ ! -f "$DEPS/$name" ]]; then
    local partial="$DEPS/$name.part"
    rm -f "$partial"
    if ! curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 -o "$partial" "$url"; then
      rm -f "$partial"
      exit 1
    fi
    mv "$partial" "$DEPS/$name"
  fi
  if ! verify "$name" "$checksum"; then
    echo "Checksum mismatch for $name" >&2
    exit 1
  fi
}

download centrifuge-java-0.8.0.jar "https://repo1.maven.org/maven2/io/github/centrifugal/centrifuge-java/0.8.0/centrifuge-java-0.8.0.jar" 806a799c137664107e9a9511b91de5e9d0c843fa3c750043169d9f3495bd4622
download okhttp-4.12.0.jar "https://repo1.maven.org/maven2/com/squareup/okhttp3/okhttp/4.12.0/okhttp-4.12.0.jar" b1050081b14bb7a3a7e55a4d3ef01b5dcfabc453b4573a4fc019767191d5f4e0
download okio-jvm-3.6.0.jar "https://repo1.maven.org/maven2/com/squareup/okio/okio-jvm/3.6.0/okio-jvm-3.6.0.jar" 67543f0736fc422ae927ed0e504b98bc5e269fda0d3500579337cb713da28412
download protobuf-javalite-3.25.5.jar "https://repo1.maven.org/maven2/com/google/protobuf/protobuf-javalite/3.25.5/protobuf-javalite-3.25.5.jar" 79a3ff51ac2a8b1be7fffa228483d64974f17f3effffd966b054d87179e45634
download streamsupport-minifuture-1.7.4.jar "https://repo1.maven.org/maven2/net/sourceforge/streamsupport/streamsupport-minifuture/1.7.4/streamsupport-minifuture-1.7.4.jar" ecf9132fcfb192e7ae6921468983c1ce8b1a8ed438012baf7869812cc25d7cc6
download json-20240303.jar "https://repo1.maven.org/maven2/org/json/json/20240303/json-20240303.jar" 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed

CLASSPATH="$DEPS/centrifuge-java-0.8.0.jar:$DEPS/okhttp-4.12.0.jar:$DEPS/okio-jvm-3.6.0.jar:$DEPS/protobuf-javalite-3.25.5.jar:$DEPS/streamsupport-minifuture-1.7.4.jar:$DEPS/json-20240303.jar"

mapfile -t SOURCES < <(find "$HERE/src" -name '*.kt' -print)
kotlinc "${SOURCES[@]}" -include-runtime -classpath "$CLASSPATH" -d "$BUILD/conformance.jar"

printf '%s\n' "$BUILD/conformance.jar"
