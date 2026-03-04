#!/usr/bin/env bash
# OTP2 グラフビルドのメモリ・時間を計測するスクリプト
#
# 使い方:
#   bash scripts/measure_build.sh <label> <data_dir> [Xmx]
#
# 例:
#   bash scripts/measure_build.sh baseline data/build-baseline 8G
#   bash scripts/measure_build.sh 4pref   data/build-4pref    8G

set -euo pipefail

LABEL="${1:?Usage: $0 <label> <data_dir> [Xmx]}"
DATA_DIR="${2:?Usage: $0 <label> <data_dir> [Xmx]}"
XMX="${3:-8G}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="$ROOT/logs"
GC_LOG="$LOGDIR/gc-${LABEL}.log"
BUILD_LOG="$LOGDIR/build-${LABEL}.log"
RESULT_FILE="$LOGDIR/result-${LABEL}.txt"

mkdir -p "$LOGDIR"

echo "================================================"
echo "  OTP2 Build Measurement"
echo "  Label    : $LABEL"
echo "  Data dir : $DATA_DIR"
echo "  -Xmx     : $XMX"
echo "  Start    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================"

# --- ビルド起動 ---
START_EPOCH=$(date +%s)

java -Xmx"${XMX}" \
     -Xlog:gc*:file="${GC_LOG}":time,level,tags \
     -jar "$ROOT/otp.jar" \
     --build --save "$DATA_DIR" \
     > "$BUILD_LOG" 2>&1 &
OTP_PID=$!
echo "OTP2 PID: $OTP_PID"

# --- RSS ポーリング ---
MAX_RSS_KB=0
SAMPLE_COUNT=0
while kill -0 "$OTP_PID" 2>/dev/null; do
    RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null || echo 0)
    RSS_KB="${RSS_KB//[[:space:]]/}"
    if [[ "$RSS_KB" =~ ^[0-9]+$ ]] && [ "$RSS_KB" -gt "$MAX_RSS_KB" ]; then
        MAX_RSS_KB=$RSS_KB
    fi
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    sleep 5
done

wait "$OTP_PID"
BUILD_EXIT=$?
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
ELAPSED_MIN=$(echo "scale=1; $ELAPSED / 60" | bc)

# --- graph.obj サイズ ---
GRAPH_SIZE="N/A"
if [ -f "$DATA_DIR/graph.obj" ]; then
    GRAPH_SIZE=$(du -sh "$DATA_DIR/graph.obj" | cut -f1)
fi

# --- GC ログからピークヒープ使用量を抽出 ---
PEAK_HEAP_MB="N/A"
if [ -f "$GC_LOG" ]; then
    # GC ログから "Heap after GC" の最大値を取得 (used/committed MB)
    PEAK_HEAP_MB=$(grep -o 'heap=[0-9]*M' "$GC_LOG" 2>/dev/null | \
        grep -o '[0-9]*' | sort -n | tail -1 || echo "N/A")
    [ -n "$PEAK_HEAP_MB" ] && PEAK_HEAP_MB="${PEAK_HEAP_MB}M (from GC log)"
fi

PEAK_RSS_MB=$((MAX_RSS_KB / 1024))

# --- 結果出力 ---
{
    echo "================================================"
    echo "  Build Result: $LABEL"
    echo "================================================"
    echo "  Exit code      : $BUILD_EXIT"
    echo "  Build time     : ${ELAPSED}s (${ELAPSED_MIN} min)"
    echo "  Peak RSS       : ${PEAK_RSS_MB} MB  (${MAX_RSS_KB} kB)"
    echo "  Peak heap (GC) : ${PEAK_HEAP_MB}"
    echo "  graph.obj size : ${GRAPH_SIZE}"
    echo "  -Xmx setting   : ${XMX}"
    echo "  Samples taken  : ${SAMPLE_COUNT}"
    echo "  End time       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================"
} | tee "$RESULT_FILE"

if [ "$BUILD_EXIT" -ne 0 ]; then
    echo ""
    echo "!!! BUILD FAILED (exit=$BUILD_EXIT) !!!"
    echo "Last 30 lines of build log:"
    tail -30 "$BUILD_LOG"
    exit "$BUILD_EXIT"
fi

echo ""
echo "Build SUCCESS. graph.obj: $DATA_DIR/graph.obj"
