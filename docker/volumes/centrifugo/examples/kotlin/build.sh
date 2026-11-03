#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
DEPS="$BUILD/deps"
mkdir -p "$DEPS"

download() {
  local name="$1"
  local url="$2"
  if [[ ! -f "$DEPS/$name" ]]; then
    curl -fsSL --retry 3 -o "$DEPS/$name" "$url"
  fi
}

download centrifuge-java-0.8.0.jar "https://repo1.maven.org/maven2/io/github/centrifugal/centrifuge-java/0.8.0/centrifuge-java-0.8.0.jar"
download okhttp-4.12.0.jar "https://repo1.maven.org/maven2/com/squareup/okhttp3/okhttp/4.12.0/okhttp-4.12.0.jar"
download okio-jvm-3.6.0.jar "https://repo1.maven.org/maven2/com/squareup/okio/okio-jvm/3.6.0/okio-jvm-3.6.0.jar"
download protobuf-javalite-3.25.5.jar "https://repo1.maven.org/maven2/com/google/protobuf/protobuf-javalite/3.25.5/protobuf-javalite-3.25.5.jar"
download streamsupport-minifuture-1.7.4.jar "https://repo1.maven.org/maven2/net/sourceforge/streamsupport/streamsupport-minifuture/1.7.4/streamsupport-minifuture-1.7.4.jar"

CLASSPATH="$DEPS/centrifuge-java-0.8.0.jar:$DEPS/okhttp-4.12.0.jar:$DEPS/okio-jvm-3.6.0.jar:$DEPS/protobuf-javalite-3.25.5.jar:$DEPS/streamsupport-minifuture-1.7.4.jar"

mapfile -t SOURCES < <(find "$HERE/src" -name '*.kt' -print)
kotlinc "${SOURCES[@]}" -include-runtime -classpath "$CLASSPATH" -d "$BUILD/conformance.jar"

printf '%s\n' "$BUILD/conformance.jar"
