#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-war.sh  —  Build datadisplay-tomcat-backend.war using plain javac+jar.
# Run this on olserver134 (or any host with Java 8 + the Tomcat servlet-api).
#
# Usage:
#   cd /tmp/datadisplay-tomcat-backend   # directory containing this script
#   bash build-war.sh
#
# Produces: datadisplay-tomcat-backend.war in the current directory.
# ---------------------------------------------------------------------------
set -euo pipefail

JAVA_HOME="${JAVA_HOME:-/virgoApp/Tomcat/v0r1p3/jdk1.8.0_73}"
JAVAC="$JAVA_HOME/bin/javac"
JAR_CMD="$JAVA_HOME/bin/jar"
SERVLET_API="/virgoApp/Tomcat/v0r1p3/apache-tomcat-9.0.0.M4/lib/servlet-api.jar"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src/main/java"
WEBAPP_DIR="$SCRIPT_DIR/src/main/webapp"
BUILD_DIR="$SCRIPT_DIR/build/war-work"
WAR_CLASSES="$BUILD_DIR/WEB-INF/classes"
WAR_OUT="$SCRIPT_DIR/build/libs/datadisplay-tomcat-backend.war"

echo "=== DataDisplay Tomcat backend WAR build ==="
echo "JAVA_HOME : $JAVA_HOME"
echo "SERVLET   : $SERVLET_API"
echo "SOURCE    : $SRC_DIR"

if [ ! -x "$JAVAC" ]; then
  echo "ERROR: javac not found at $JAVAC"; exit 1
fi
if [ ! -f "$SERVLET_API" ]; then
  echo "ERROR: servlet-api.jar not found at $SERVLET_API"; exit 1
fi

# ── 1. Clean build dir ──────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$WAR_CLASSES"
mkdir -p "$(dirname "$WAR_OUT")"

# ── 2. Copy webapp resources (WEB-INF/web.xml, META-INF/context.xml, etc.) ─
cp -r "$WEBAPP_DIR"/. "$BUILD_DIR/"

# ── 3. Collect all .java source files ───────────────────────────────────────
find "$SRC_DIR" -name '*.java' > "$BUILD_DIR/sources.txt"
SRC_COUNT=$(wc -l < "$BUILD_DIR/sources.txt")
echo "Compiling $SRC_COUNT source files..."

# ── 4. Compile ───────────────────────────────────────────────────────────────
"$JAVAC" \
  -encoding UTF-8 \
  -source 1.8 -target 1.8 \
  -classpath "$SERVLET_API" \
  -d "$WAR_CLASSES" \
  @"$BUILD_DIR/sources.txt"

echo "Compilation complete."

# ── 5. Package as WAR ────────────────────────────────────────────────────────
(cd "$BUILD_DIR" && "$JAR_CMD" cf "$WAR_OUT" .)
echo ""
echo "=== WAR created: $WAR_OUT ==="
echo "Size: $(du -sh "$WAR_OUT" | cut -f1)"
