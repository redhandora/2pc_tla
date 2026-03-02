#!/bin/bash
# Script to run TLA+ model checking for 2pc_tla.tla
# Requires Java 11+ and tla2tools.jar

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TLA_JAR=""
KNOWN_PATHS=(
    "$SCRIPT_DIR/tla2tools.jar"
    "$HOME/.cursor-server/extensions/alygin.vscode-tlaplus-nightly-2024.8.1506-universal/tools/tla2tools.jar"
)
for p in "${KNOWN_PATHS[@]}"; do
    if [ -f "$p" ]; then
        TLA_JAR="$p"
        break
    fi
done

if [ -z "$TLA_JAR" ]; then
    echo "Error: tla2tools.jar not found."
    echo "Download from https://github.com/tlaplus/tlaplus/releases"
    exit 1
fi

JAVA_BIN="${JAVA_HOME:-}/bin/java"
if [ ! -x "$JAVA_BIN" ]; then
    JAVA_BIN="$(command -v java 2>/dev/null || true)"
fi
if [ -z "$JAVA_BIN" ]; then
    echo "Error: java not found. Need Java 11+."
    exit 1
fi

CONFIGS=(
    "2pc_tla.cfg:Fan-out topology (n1 -> {n2,n3})"
    "2pc_tla_chain.cfg:Chain topology (n1 -> n2 -> n3)"
)

FAILED=0
for entry in "${CONFIGS[@]}"; do
    CFG="${entry%%:*}"
    DESC="${entry#*:}"
    if [ ! -f "$CFG" ]; then
        echo "SKIP: $CFG not found"
        continue
    fi
    echo "============================================"
    echo "Running: $DESC"
    echo "Config:  $CFG"
    echo "============================================"
    if "$JAVA_BIN" -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -config "$CFG" MC.tla -workers auto 2>&1; then
        echo "PASS: $DESC"
    else
        echo "FAIL: $DESC"
        FAILED=1
    fi
    echo ""
done

if [ "$FAILED" -eq 0 ]; then
    echo "All configurations passed."
else
    echo "Some configurations failed."
    exit 1
fi

