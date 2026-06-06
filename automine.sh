#!/bin/bash
# automine.sh – Startet mine.sh in einer Schleife,
# wechselt nach 5–15 Minuten die Thread-Anzahl (1–4).
# Meldet sich nach jedem Neustart an status.m8n.de/report.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MINE="$SCRIPT_DIR/mine.sh"
CFG="$SCRIPT_DIR/pool.cfg"
STATUS_URL="https://status.m8n.de/report"
HOSTNAME="${CUSTOM_HOSTNAME:-$(hostname -s)}"   # überschreibbar per Env-Variable

cleanup() {
    echo "[automine] Beende Miner (PID $MINER_PID)..."
    kill "$MINER_PID" 2>/dev/null
    wait "$MINER_PID" 2>/dev/null
    echo "[automine] Gestoppt."
    exit 0
}
trap cleanup SIGINT SIGTERM

# Aktuelle Config-Werte auslesen
read_cfg() {
    grep -m1 "^$1=" "$CFG" | cut -d= -f2
}

while true; do
    # Zufällige Werte bestimmen
    THREADS=$(( RANDOM % 4 + 1 ))                  # 1–4
    WAIT_SEC=$(( RANDOM % 601 + 300 ))              # 300–900 s (5–15 min)
    WAIT_MIN=$(echo "scale=1; $WAIT_SEC/60" | bc)

    # Threads in pool.cfg setzen
    sed -i "s/^threads=.*/threads=$THREADS/" "$CFG"

    # Pool-Server (server[1]) und Worker aus Config lesen
    POOL_SERVER=$(read_cfg "server\[1\]")
    WORKER=$(read_cfg "worker")

    echo "[automine] threads=$THREADS, Laufzeit=${WAIT_MIN} min (${WAIT_SEC}s)"

    # Status an Dashboard melden
    curl -sf -X POST "$STATUS_URL" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"threads\":$THREADS,\"wait_sec\":$WAIT_SEC,\"pool_server\":\"$POOL_SERVER\",\"worker\":\"$WORKER\"}" \
        >/dev/null || echo "[automine] Warnung: Status-Meldung fehlgeschlagen"

    # Miner starten
    bash "$MINE" &
    MINER_PID=$!
    echo "[automine] Miner gestartet (PID $MINER_PID)"

    # Warten und dann Miner beenden
    sleep "$WAIT_SEC"
    echo "[automine] Zeit abgelaufen – starte neu..."
    kill "$MINER_PID" 2>/dev/null
    wait "$MINER_PID" 2>/dev/null
    sleep 2
done
