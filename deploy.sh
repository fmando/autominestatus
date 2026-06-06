#!/bin/bash
# deploy.sh – Richtet automine auf diesem Host ein.
# Fragt Worker-Name, max. Threads und Dashboard-URL ab,
# schreibt pool.cfg und automine.sh, richtet optional den systemd-Dienst ein.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║        Automine Setup                ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Eingaben
# ---------------------------------------------------------------------------

# Wallet-Adresse
read -rp "Wallet-Adresse: " WALLET
while [[ -z "$WALLET" ]]; do
    echo "  Wallet-Adresse darf nicht leer sein."
    read -rp "Wallet-Adresse: " WALLET
done

# Worker-Name
read -rp "Worker-Name (z.B. Ccloud06): " WORKER
while [[ -z "$WORKER" ]]; do
    echo "  Worker-Name darf nicht leer sein."
    read -rp "Worker-Name: " WORKER
done

# CPU-Threads ermitteln
CPU_THREADS=$(nproc)
echo "  Diese CPU hat $CPU_THREADS Threads."
echo ""

# Maximale Thread-Anzahl
read -rp "Maximale Thread-Anzahl [Standard: $CPU_THREADS]: " MAX_THREADS
MAX_THREADS="${MAX_THREADS:-$CPU_THREADS}"
while ! [[ "$MAX_THREADS" =~ ^[0-9]+$ ]] || (( MAX_THREADS < 1 || MAX_THREADS > 32 )); do
    echo "  Bitte eine Zahl zwischen 1 und 32 eingeben."
    read -rp "Maximale Thread-Anzahl: " MAX_THREADS
done

# Minimale Thread-Anzahl
read -rp "Minimale Thread-Anzahl [Standard: 1]: " MIN_THREADS
MIN_THREADS="${MIN_THREADS:-1}"
while ! [[ "$MIN_THREADS" =~ ^[0-9]+$ ]] || (( MIN_THREADS < 1 || MIN_THREADS > MAX_THREADS )); do
    echo "  Bitte eine Zahl zwischen 1 und $MAX_THREADS eingeben."
    read -rp "Minimale Thread-Anzahl: " MIN_THREADS
done

# Laufzeit-Bereich
read -rp "Minimale Laufzeit in Minuten [Standard: 5]: " MIN_MIN
MIN_MIN="${MIN_MIN:-5}"
read -rp "Maximale Laufzeit in Minuten [Standard: 15]: " MAX_MIN
MAX_MIN="${MAX_MIN:-15}"

# Dashboard-URL
read -rp "Status-Dashboard URL [Standard: https://status.m8u.de]: " STATUS_URL
STATUS_URL="${STATUS_URL:-https://status.m8u.de}"

# Hostname fürs Dashboard
DEFAULT_HOST="$(hostname -s)"
read -rp "Hostname fürs Dashboard [Standard: $DEFAULT_HOST]: " CUSTOM_HOST
CUSTOM_HOST="${CUSTOM_HOST:-$DEFAULT_HOST}"

echo ""
echo "── Zusammenfassung ─────────────────────"
echo "  Wallet:        ${WALLET:0:6}...${WALLET: -6}"
echo "  Worker:        $WORKER"
echo "  Threads:       $MIN_THREADS–$MAX_THREADS"
echo "  Laufzeit:      $MIN_MIN–$MAX_MIN Minuten"
echo "  Dashboard:     $STATUS_URL"
echo "  Hostname:      $CUSTOM_HOST"
echo "────────────────────────────────────────"
echo ""
read -rp "Alles korrekt? Weiter? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-J}"
if [[ ! "$CONFIRM" =~ ^[Jj]$ ]]; then
    echo "Abgebrochen."
    exit 0
fi

# ---------------------------------------------------------------------------
# pool.cfg schreiben
# ---------------------------------------------------------------------------

cat > "$SCRIPT_DIR/pool.cfg" <<EOF
wallet=$WALLET
worker=$WORKER
threads=$MIN_THREADS
server[1]=de.catchthatrabbit.com
port[1]=8008
server[2]=fi.catchthatrabbit.com
port[2]=8008
server[3]=sg.catchthatrabbit.com
port[3]=8008
EOF

echo "[deploy] pool.cfg geschrieben."

# ---------------------------------------------------------------------------
# automine.sh schreiben
# ---------------------------------------------------------------------------

THREAD_RANGE=$((MAX_THREADS - MIN_THREADS + 1))
MIN_SEC=$((MIN_MIN * 60))
MAX_SEC=$((MAX_MIN * 60))
WAIT_RANGE=$((MAX_SEC - MIN_SEC + 1))

cat > "$SCRIPT_DIR/automine.sh" <<EOF
#!/bin/bash
# automine.sh – generiert von deploy.sh
# Threads: $MIN_THREADS–$MAX_THREADS  |  Laufzeit: $MIN_MIN–$MAX_MIN min

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
MINE="\$SCRIPT_DIR/mine.sh"
CFG="\$SCRIPT_DIR/pool.cfg"
STATUS_BASE="$STATUS_URL"
HOSTNAME="${CUSTOM_HOST}"
LOG_FILE="/var/log/automine/automine.log"

cleanup() {
    echo "[automine] Beende Miner (PID \$MINER_PID)..."
    kill "\$REPORTER_PID" 2>/dev/null
    kill "\$MINER_PID" 2>/dev/null
    wait "\$MINER_PID" 2>/dev/null
    echo "[automine] Gestoppt."
    exit 0
}
trap cleanup SIGINT SIGTERM

read_cfg() {
    grep -m1 "^\$1=" "\$CFG" | cut -d= -f2
}

# Liest alle 30s die letzte Hashrate aus dem Log und meldet sie ans Dashboard
hashrate_reporter() {
    local miner_pid=\$1
    while kill -0 "\$miner_pid" 2>/dev/null; do
        sleep 30
        local HR
        HR=\$(tail -500 "\$LOG_FILE" 2>/dev/null \\
             | grep -a " m " \\
             | tail -1 \\
             | grep -oP 'A\d+ \K[\d.]+ [KMG]?h' \\
             | head -1)
        if [[ -n "\$HR" ]]; then
            curl -sf -X POST "\${STATUS_BASE}/hashrate" \\
                -H "Content-Type: application/json" \\
                -d "{\\"hostname\\":\\"\$HOSTNAME\\",\\"hashrate\\":\\"\$HR\\"}" \\
                >/dev/null || true
        fi
    done
}

while true; do
    THREADS=\$(( RANDOM % $THREAD_RANGE + $MIN_THREADS ))
    WAIT_SEC=\$(( RANDOM % $WAIT_RANGE + $MIN_SEC ))
    WAIT_MIN=\$(echo "scale=1; \$WAIT_SEC/60" | bc)

    sed -i "s/^threads=.*/threads=\$THREADS/" "\$CFG"

    POOL_SERVER=\$(read_cfg "server\[1\]")
    WORKER=\$(read_cfg "worker")

    echo "[automine] threads=\$THREADS, Laufzeit=\${WAIT_MIN} min (\${WAIT_SEC}s)"

    curl -sf -X POST "\${STATUS_BASE}/report" \\
        -H "Content-Type: application/json" \\
        -d "{\\"hostname\\":\\"\$HOSTNAME\\",\\"threads\\":\$THREADS,\\"wait_sec\\":\$WAIT_SEC,\\"pool_server\\":\\"\$POOL_SERVER\\",\\"worker\\":\\"\$WORKER\\"}" \\
        >/dev/null || echo "[automine] Warnung: Status-Meldung fehlgeschlagen"

    bash "\$MINE" &
    MINER_PID=\$!
    echo "[automine] Miner gestartet (PID \$MINER_PID)"

    # Hashrate-Reporter als Hintergrundprozess starten
    hashrate_reporter "\$MINER_PID" &
    REPORTER_PID=\$!

    sleep "\$WAIT_SEC"
    echo "[automine] Zeit abgelaufen – starte neu..."
    kill "\$REPORTER_PID" 2>/dev/null
    kill "\$MINER_PID" 2>/dev/null
    wait "\$MINER_PID" 2>/dev/null
    sleep 2
done
EOF

chmod +x "$SCRIPT_DIR/automine.sh"
echo "[deploy] automine.sh geschrieben."

# ---------------------------------------------------------------------------
# systemd-Service einrichten (optional)
# ---------------------------------------------------------------------------

echo ""
read -rp "Systemd-Dienst einrichten? (benötigt root) [J/n]: " SETUP_SERVICE
SETUP_SERVICE="${SETUP_SERVICE:-J}"

if [[ "$SETUP_SERVICE" =~ ^[Jj]$ ]]; then
    if [[ "$EUID" -ne 0 ]]; then
        echo ""
        echo "  ⚠ Kein root – systemd-Setup übersprungen."
        echo ""
        echo "  Bitte diese Werte in automine.service anpassen und dann manuell einrichten:"
        echo ""
        echo "    User=$(whoami)"
        echo "    WorkingDirectory=$SCRIPT_DIR"
        echo "    ExecStart=/bin/bash $SCRIPT_DIR/automine.sh"
        echo ""
        echo "  Danach:"
        echo "    sudo cp $SCRIPT_DIR/automine.service /etc/systemd/system/"
        echo "    sudo systemctl daemon-reload"
        echo "    sudo systemctl enable automine"
        echo "    sudo systemctl start automine"
        echo ""
        echo "  Logverzeichnis und logrotate manuell einrichten:"
        echo "    sudo mkdir -p /var/log/automine"
        echo "    sudo chown $(whoami):$(whoami) /var/log/automine"
        echo "    sudo cp $SCRIPT_DIR/logrotate.conf /etc/logrotate.d/automine"
        echo ""
        echo "  Oder deploy.sh einfach als root erneut ausführen:"
        echo "    sudo $SCRIPT_DIR/deploy.sh"
    else
        SERVICE_USER="${SUDO_USER:-$(whoami)}"
        LOG_DIR="/var/log/automine"
        LOG_FILE="$LOG_DIR/automine.log"

        # Logverzeichnis anlegen
        mkdir -p "$LOG_DIR"
        chown "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
        echo "[deploy] Logverzeichnis $LOG_DIR angelegt."

        # logrotate einrichten
        cat > /etc/logrotate.d/automine <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
        echo "[deploy] logrotate konfiguriert (täglich, 7 Tage, komprimiert)."

        # systemd-Service schreiben (mit Logdatei statt Journal)
        cat > /etc/systemd/system/automine.service <<EOF
[Unit]
Description=XCB Automine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=/bin/bash $SCRIPT_DIR/automine.sh
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable automine
        systemctl restart automine
        echo "[deploy] Dienst automine gestartet."
        echo "  Logs live lesen: tail -f $LOG_FILE"
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✓ Setup abgeschlossen – Wichtige Befehle               ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Dienst starten      systemctl start automine           ║"
echo "║  Dienst stoppen      systemctl stop automine            ║"
echo "║  Dienst neu starten  systemctl restart automine         ║"
echo "║  Status anzeigen     systemctl status automine          ║"
echo "║                                                          ║"
echo "║  Log live lesen      tail -f /var/log/automine/automine.log ║"
echo "║                                                          ║"
echo "║  Repo aktualisieren  git pull && systemctl restart automine ║"
echo "║                                                          ║"
echo "║  Dashboard:          $STATUS_URL"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
