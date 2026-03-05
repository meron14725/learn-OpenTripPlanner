#!/bin/bash
# measure_server_full.sh — OTP2 サーバーモードのシステム全体リソースを計測
#
# 計測項目:
#   - OS ベースライン RAM (free -m)
#   - OTP2 起動後アイドル RAM (free -m)
#   - GraphQL クエリ後 RAM (free -m)
#   - OTP2 プロセス RSS
#   - CPU 使用率（起動中・クエリ中）
#
# 使用方法:
#   bash scripts/measure_server_full.sh <label> <data_dir> [Xmx]
#
# 例:
#   bash scripts/measure_server_full.sh 4pref-2g data/build-4pref 2G

set -euo pipefail

LABEL=${1:-"server"}
DATA_DIR=${2:-"data/build-4pref"}
XMX=${3:-"2G"}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR_ABS="$(cd "$ROOT/$DATA_DIR" && pwd)"
LOG_DIR="$ROOT/logs"
SERVER_LOG="$LOG_DIR/server-full-${LABEL}.log"
RESULT_FILE="$LOG_DIR/result-server-full-${LABEL}.txt"
CPU_LOG="$LOG_DIR/cpu-${LABEL}.log"

mkdir -p "$LOG_DIR"

# GraphQL クエリ（高円寺→渋谷、2026-03-04 09:00 出発）
GRAPHQL_QUERY='{"query":"{ planConnection( origin: {location: {coordinate: {latitude: 35.7037, longitude: 139.6494}}} destination: {location: {coordinate: {latitude: 35.6581, longitude: 139.7014}}} first: 3 dateTime: {earliestDeparture: \"2026-03-04T09:00:00+09:00\"} ) { edges { node { start end legs { mode from { name } to { name } } } } } }"}'

# free -m から available(MB)を取得
get_available_mb() {
    free -m | awk '/^Mem:/ {print $7}'
}
# free -m から used(MB)を取得
get_used_mb() {
    free -m | awk '/^Mem:/ {print $3}'
}

echo "=== OTP2 Server Full Resource Measurement ==="
echo "Label:    $LABEL"
echo "Data dir: $DATA_DIR_ABS"
echo "Xmx:      $XMX"
echo ""

# OS ベースライン計測
BASELINE_AVAIL=$(get_available_mb)
BASELINE_USED=$(get_used_mb)
echo "[baseline] available=${BASELINE_AVAIL}MB used=${BASELINE_USED}MB"

START_EPOCH=$(date +%s)

# OTP2 サーバー起動
java -Xmx"${XMX}" \
     -jar "$ROOT/otp.jar" \
     --load "$DATA_DIR_ABS" \
     > "$SERVER_LOG" 2>&1 &
OTP_PID=$!
echo "OTP2 PID: $OTP_PID"

# RSS・CPU のポーリング（バックグラウンド）
> "$CPU_LOG"
MAX_RSS_KB=0
PEAK_CPU=0

# サーバー起動完了を待機しながら RSS/CPU を記録
READY=0
TIMEOUT=300
WAIT_START=$(date +%s)

echo "Waiting for server to start..."
while true; do
    if ! kill -0 "$OTP_PID" 2>/dev/null; then
        echo "ERROR: OTP2 process died"
        kill "$OTP_PID" 2>/dev/null || true
        {
            echo "LABEL=$LABEL"
            echo "XMX=$XMX"
            echo "STARTUP=FAILED"
        } > "$RESULT_FILE"
        exit 1
    fi

    if grep -q "Grizzly server running" "$SERVER_LOG" 2>/dev/null; then
        READY_EPOCH=$(date +%s)
        STARTUP_SEC=$((READY_EPOCH - START_EPOCH))
        READY=1
        break
    fi

    NOW=$(date +%s)
    if [ $((NOW - WAIT_START)) -gt $TIMEOUT ]; then
        echo "ERROR: Timeout"
        kill "$OTP_PID" 2>/dev/null || true
        exit 2
    fi

    # RSS と CPU を記録
    RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
    CPU_PCT=$(ps -p "$OTP_PID" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)
    [ "${RSS_KB:-0}" -gt "$MAX_RSS_KB" ] && MAX_RSS_KB=${RSS_KB:-0}
    echo "$(date '+%H:%M:%S') RSS=${RSS_KB}kB CPU=${CPU_PCT}%" >> "$CPU_LOG"

    sleep 2
done

echo "Server ready after ${STARTUP_SEC}s"

# 起動ピーク CPU（起動中の最大値を計算）
STARTUP_PEAK_CPU=$(awk -F'CPU=' '{print $2}' "$CPU_LOG" | tr -d '%' | sort -n | tail -1)
echo "Startup peak CPU: ${STARTUP_PEAK_CPU}%"

# アイドル時の RAM 計測（少し待ってから）
sleep 3
IDLE_RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
IDLE_AVAIL=$(get_available_mb)
IDLE_USED=$(get_used_mb)
echo "[idle] available=${IDLE_AVAIL}MB used=${IDLE_USED}MB RSS=${IDLE_RSS_KB}kB"

# クエリ処理前の CPU ログ行数を記録
CPU_LINES_BEFORE=$(wc -l < "$CPU_LOG")

# GraphQL クエリ送信しながら CPU 計測
> "$LOG_DIR/query-response-full-${LABEL}.json"

# バックグラウンドで CPU ポーリング継続
(
    for i in $(seq 1 15); do
        if ! kill -0 "$OTP_PID" 2>/dev/null; then break; fi
        RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
        CPU_PCT=$(ps -p "$OTP_PID" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)
        echo "$(date '+%H:%M:%S') RSS=${RSS_KB}kB CPU=${CPU_PCT}% [query]" >> "$CPU_LOG"
        sleep 1
    done
) &
POLLER_PID=$!

echo "Sending GraphQL query (高円寺→渋谷)..."
HTTP_STATUS=$(curl -s -o "$LOG_DIR/query-response-full-${LABEL}.json" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$GRAPHQL_QUERY" \
    "http://localhost:8080/otp/gtfs/v1" \
    --max-time 30 || echo "CURL_FAILED")

kill "$POLLER_PID" 2>/dev/null || true
wait "$POLLER_PID" 2>/dev/null || true

# クエリ後の計測
POST_RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
POST_AVAIL=$(get_available_mb)
POST_USED=$(get_used_mb)
echo "[post-query] available=${POST_AVAIL}MB used=${POST_USED}MB RSS=${POST_RSS_KB}kB"

# クエリ中のピーク CPU
QUERY_PEAK_CPU=$(awk '/\[query\]/ {sub(/.*CPU=/, ""); sub(/%.*/, ""); print}' "$CPU_LOG" | sort -n | tail -1)

# RSS の最大値を更新
[ "${IDLE_RSS_KB:-0}" -gt "$MAX_RSS_KB" ] && MAX_RSS_KB=${IDLE_RSS_KB:-0}
[ "${POST_RSS_KB:-0}" -gt "$MAX_RSS_KB" ] && MAX_RSS_KB=${POST_RSS_KB:-0}

# レスポンス確認
QUERY_OK=0
EDGES_COUNT=0
if [ "$HTTP_STATUS" = "200" ]; then
    EDGES_COUNT=$(python3 -c "
import json
try:
    data = json.load(open('$LOG_DIR/query-response-full-${LABEL}.json'))
    print(len(data.get('data',{}).get('planConnection',{}).get('edges',[])))
except: print(0)
" 2>/dev/null || echo 0)
    if [ "${EDGES_COUNT:-0}" -gt 0 ]; then
        QUERY_OK=1
        echo "GraphQL OK: ${EDGES_COUNT} routes"
        python3 -c "
import json
data = json.load(open('$LOG_DIR/query-response-full-${LABEL}.json'))
edges = data.get('data',{}).get('planConnection',{}).get('edges',[])
for i, e in enumerate(edges[:2]):
    n = e['node']
    print(f'  Route {i+1}: {n[\"start\"]} -> {n[\"end\"]}')
    for l in n.get('legs',[]):
        print(f'    {l[\"mode\"]}: {l[\"from\"][\"name\"]} -> {l[\"to\"][\"name\"]}')
" 2>/dev/null || true
    fi
fi

# OTP2 停止
kill "$OTP_PID" 2>/dev/null || true
wait "$OTP_PID" 2>/dev/null || true

# 差分計算
OTP_IDLE_CONSUME=$((BASELINE_AVAIL - IDLE_AVAIL))
QUERY_EXTRA_CONSUME=$((IDLE_AVAIL - POST_AVAIL))

# 結果出力
{
    echo "LABEL=$LABEL"
    echo "XMX=$XMX"
    echo "STARTUP=SUCCESS"
    echo "STARTUP_SEC=$STARTUP_SEC"
    echo "--- System RAM (free -m) ---"
    echo "BASELINE_AVAIL_MB=$BASELINE_AVAIL"
    echo "BASELINE_USED_MB=$BASELINE_USED"
    echo "IDLE_AVAIL_MB=$IDLE_AVAIL"
    echo "IDLE_USED_MB=$IDLE_USED"
    echo "POST_QUERY_AVAIL_MB=$POST_AVAIL"
    echo "POST_QUERY_USED_MB=$POST_USED"
    echo "OTP_IDLE_CONSUME_MB=$OTP_IDLE_CONSUME"
    echo "QUERY_EXTRA_CONSUME_MB=$QUERY_EXTRA_CONSUME"
    echo "--- OTP2 Process RSS ---"
    echo "IDLE_RSS_MB=$((IDLE_RSS_KB / 1024))"
    echo "POST_QUERY_RSS_MB=$((POST_RSS_KB / 1024))"
    echo "PEAK_RSS_MB=$((MAX_RSS_KB / 1024))"
    echo "--- CPU ---"
    echo "STARTUP_PEAK_CPU_PCT=${STARTUP_PEAK_CPU:-N/A}"
    echo "QUERY_PEAK_CPU_PCT=${QUERY_PEAK_CPU:-N/A}"
    echo "--- GraphQL ---"
    echo "HTTP_STATUS=$HTTP_STATUS"
    echo "QUERY_OK=$QUERY_OK"
    echo "EDGES_COUNT=$EDGES_COUNT"
} > "$RESULT_FILE"

echo ""
echo "=== Result: $LABEL ==="
cat "$RESULT_FILE"
