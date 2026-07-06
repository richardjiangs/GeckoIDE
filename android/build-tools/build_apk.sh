#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$ROOT/android"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JDK="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-$SDK/build-tools/37.0.0}"
PLATFORM="${ANDROID_PLATFORM:-$SDK/platforms/android-36.1/android.jar}"

AAPT2="$BUILD_TOOLS/aapt2"
APKSIGNER="$BUILD_TOOLS/apksigner"
D8="$BUILD_TOOLS/d8"
ZIPALIGN="$BUILD_TOOLS/zipalign"
JAVAC="$JDK/bin/javac"
KEYTOOL="$JDK/bin/keytool"
export JAVA_HOME="$JDK"
export PATH="$JDK/bin:$PATH"

for tool in "$AAPT2" "$APKSIGNER" "$D8" "$ZIPALIGN" "$JAVAC" "$KEYTOOL" "$PLATFORM"; do
  if [ ! -e "$tool" ]; then
    echo "Missing build dependency: $tool" >&2
    exit 1
  fi
done

OUT="$APP_DIR/build"
rm -rf "$OUT"
mkdir -p "$OUT/compiled" "$OUT/generated" "$OUT/classes" "$OUT/dex"

"$AAPT2" compile --dir "$APP_DIR/src/main/res" -o "$OUT/compiled/resources.zip"
"$AAPT2" link \
  -I "$PLATFORM" \
  --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
  --java "$OUT/generated" \
  -A "$APP_DIR/src/main/assets" \
  --auto-add-overlay \
  --min-sdk-version 23 \
  --target-sdk-version 36 \
  --version-code 20 \
  --version-name 1.5.4 \
  -0 .wasm \
  -0 .zip \
  -o "$OUT/GeskoIDE-unsigned.apk" \
  "$OUT/compiled/resources.zip"

find "$APP_DIR/src/main/java" "$OUT/generated" -name '*.java' | sort > "$OUT/sources.txt"
"$JAVAC" -Xlint:-options -source 8 -target 8 -bootclasspath "$PLATFORM" -d "$OUT/classes" @"$OUT/sources.txt"

"$D8" --min-api 23 --lib "$PLATFORM" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class' | sort)
cp "$OUT/GeskoIDE-unsigned.apk" "$OUT/GeskoIDE-classes.apk"
(cd "$OUT/dex" && zip -q -u "$OUT/GeskoIDE-classes.apk" classes.dex)
"$ZIPALIGN" -f -p 4 "$OUT/GeskoIDE-classes.apk" "$OUT/GeskoIDE-aligned.apk"

KEYSTORE="$APP_DIR/keystore/geskoide.keystore"
mkdir -p "$(dirname "$KEYSTORE")"
if [ ! -f "$KEYSTORE" ]; then
  "$KEYTOOL" -genkeypair \
    -keystore "$KEYSTORE" \
    -storepass android \
    -keypass android \
    -alias androiddebugkey \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=GeskoIDE,C=US" >/dev/null
fi

"$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --v4-signing-enabled false \
  --out "$ROOT/GeskoIDE.apk" \
  "$OUT/GeskoIDE-aligned.apk"
rm -f "$ROOT/GeskoIDE.apk.idsig"

"$APKSIGNER" verify --verbose "$ROOT/GeskoIDE.apk"
echo "Built $ROOT/GeskoIDE.apk"
