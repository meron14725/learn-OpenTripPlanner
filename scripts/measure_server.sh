#!/bin/bash
# measure_server.sh — OTP2 サーバーモードのメモリ・起動時間を計測するスクリプト
#
# 使用方法:
#   bash scripts/measure_server.sh <label> <data_dir> [Xmx]
#
# 例:
#   bash scripts/measure_server.sh 4pref-2g data/build-4pref 2G

set -euo pipefail

LABEL=${1:-"server"}
DATA_DIR=${2:-"data/build-4pref"}
XMX=${3:-"2G"}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR_ABS="$(cd "$ROOT/$DATA_DIR" && pwd)"
LOG_DIR="$ROOT/logs"
SERVER_LOG="$LOG_DIR/server-${LABEL}.log"
GC_LOG="$LOG_DIR/gc-server-${LABEL}.log"
RESULT_FILE="$LOG_DIR/result-server-${LABEL}.txt"

mkdir -p "$LOG_DIR"

# GraphQL クエリ（高円寺→渋谷、2026-03-04 09:00 出発）
GRAPHQL_QUERY='{"query":"{ planConnection( origin: {location: {coordinate: {latitude: 35.7037, longitude: 139.6494}}} destination: {location: {coordinate: {latitude: 35.6581, longitude: 139.7014}}} first: 3 dateTime: {earliestDeparture: \"2026-03-04T09:00:00+09:00\"} ) { edges { node { start end legs { mode from { name } to { name } } } } } }"}'

echo "=== OTP2 Server Memory Measurement ==="
echo "Label:    $LABEL"
echo "Data dir: $DATA_DIR_ABS"
echo "Xmx:      $XMX"
echo "Log:      $SERVER_LOG"
echo ""

START_EPOCH=$(date +%s)

# OTP2 サーバー起動（バックグラウンド）
java -Xmx"${XMX}" \
     -Xlog:gc*:file="${GC_LOG}":time,level,tags \
     -jar "$ROOT/otp.jar" \
     --load "$DATA_DIR_ABS" \
     > "$SERVER_LOG" 2>&1 &
OTP_PID=$!
echo "OTP2 PID: $OTP_PID"

# RSS ポーリング（バックグラウンド）
MAX_RSS_KB=0
RSS_LOG="$LOG_DIR/rss-server-${LABEL}.log"
> "$RSS_LOG"

# サーバー起動完了を待機
READY=0
WAIT_START=$(date +%s)
TIMEOUT=300  # 最大 5 分待機

echo "Waiting for server to start..."
while true; do
    # プロセスが死んでいたら終了
    if ! kill -0 "$OTP_PID" 2>/dev/null; then
        echo "ERROR: OTP2 process died before becoming ready!"
        EXIT_CODE=1
        break
    fi

    # 起動完了ログを確認
    if grep -q "Grizzly server running" "$SERVER_LOG" 2>/dev/null; then
        READY_EPOCH=$(date +%s)
        STARTUP_SEC=$((READY_EPOCH - START_EPOCH))
        READY=1
        echo "Server ready after ${STARTUP_SEC}s"
        break
    fi

    # タイムアウト
    NOW=$(date +%s)
    if [ $((NOW - WAIT_START)) -gt $TIMEOUT ]; then
        echo "ERROR: Timeout waiting for server to start"
        kill "$OTP_PID" 2>/dev/null || true
        EXIT_CODE=2
        break
    fi

    # RSS 記録
    RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
    if [ -n "$RSS_KB" ] && [ "$RSS_KB" -gt 0 ]; then
        echo "$(date '+%H:%M:%S') RSS=${RSS_KB}kB" >> "$RSS_LOG"
        [ "$RSS_KB" -gt "$MAX_RSS_KB" ] && MAX_RSS_KB=$RSS_KB
    fi

    sleep 3
done

if [ "$READY" -eq 0 ]; then
    {
        echo "LABEL=$LABEL"
        echo "XMX=$XMX"
        echo "STARTUP=FAILED"
        echo "EXIT_CODE=${EXIT_CODE:-99}"
    } > "$RESULT_FILE"
    echo "=== FAILED ==="
    cat "$RESULT_FILE"
    exit 1
fi

# アイドル RSS 計測（起動直後）
IDLE_RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
[ "$IDLE_RSS_KB" -gt "$MAX_RSS_KB" ] && MAX_RSS_KB=$IDLE_RSS_KB
echo "Idle RSS: $((IDLE_RSS_KB / 1024)) MB"

# GraphQL クエリ送信
echo "Sending GraphQL query (高円寺→渋谷)..."
HTTP_STATUS=$(curl -s -o "$LOG_DIR/query-response-${LABEL}.json" \
    -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$GRAPHQL_QUERY" \
    "http://localhost:8080/otp/gtfs/v1" \
    --max-time 30 || echo "CURL_FAILED")

echo "HTTP status: $HTTP_STATUS"

# レスポンス確認
QUERY_OK=0
EDGES_COUNT=0
if [ "$HTTP_STATUS" = "200" ]; then
    EDGES_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open('$LOG_DIR/query-response-${LABEL}.json'))
    edges = data.get('data', {}).get('planConnection', {}).get('edges', [])
    print(len(edges))
except Exception as e:
    print(0)
" 2>/dev/null || echo 0)
    if [ "$EDGES_COUNT" -gt 0 ]; then
        QUERY_OK=1
        echo "GraphQL OK: ${EDGES_COUNT} routes returned"
        # 最初の経路の legs を表示
        python3 -c "
import json
data = json.load(open('$LOG_DIR/query-response-${LABEL}.json'))
edges = data.get('data', {}).get('planConnection', {}).get('edges', [])
for i, e in enumerate(edges[:2]):
    node = e['node']
    legs = node.get('legs', [])
    print(f'Route {i+1}: start={node[\"start\"]} end={node[\"end\"]}')
    for leg in legs:
        print(f'  {leg[\"mode\"]}: {leg[\"from\"][\"name\"]} -> {leg[\"to\"][\"name\"]}')
" 2>/dev/null || true
    else
        echo "WARNING: GraphQL returned 200 but no edges"
    fi
else
    echo "WARNING: GraphQL query failed (HTTP $HTTP_STATUS)"
fi

# クエリ後 RSS 計測
POST_QUERY_RSS_KB=$(ps -p "$OTP_PID" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
[ "$POST_QUERY_RSS_KB" -gt "$MAX_RSS_KB" ] && MAX_RSS_KB=$POST_QUERY_RSS_KB
echo "Post-query RSS: $((POST_QUERY_RSS_KB / 1024)) MB"
echo "Peak RSS so far: $((MAX_RSS_KB / 1024)) MB"

# OTP2 シャットダウン
kill "$OTP_PID" 2>/dev/null || true
wait "$OTP_PID" 2>/dev/null || true

END_EPOCH=$(date +%s)
TOTAL_SEC=$((END_EPOCH - START_EPOCH))

# 結果出力
{
    echo "LABEL=$LABEL"
    echo "XMX=$XMX"
    echo "STARTUP=SUCCESS"
    echo "STARTUP_SEC=$STARTUP_SEC"
    echo "IDLE_RSS_MB=$((IDLE_RSS_KB / 1024))"
    echo "POST_QUERY_RSS_MB=$((POST_QUERY_RSS_KB / 1024))"
    echo "PEAK_RSS_MB=$((MAX_RSS_KB / 1024))"
    echo "QUERY_OK=$QUERY_OK"
    echo "EDGES_COUNT=$EDGES_COUNT"
    echo "HTTP_STATUS=$HTTP_STATUS"
    echo "TOTAL_SEC=$TOTAL_SEC"
} > "$RESULT_FILE"

echo ""
echo "=== Result: $LABEL ==="
cat "$RESULT_FILE"
