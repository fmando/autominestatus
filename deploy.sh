#!/bin/bash
# deploy.sh v2.1.0 – XCB Autominer2 Setup
# - Lädt coreminer automatisch herunter / aktualisiert ihn
# - Erkennt Serverstandort für optimale Pool-Wahl
# - Startet coreminer direkt (kein mine.sh)
# - Holt Wallet vom zentralen Status-Server
# - Entfernt alten automine-Dienst automatisch

AUTOMINE_VERSION="2.1.0"
SERVICE_NAME="autominer2"
OLD_SERVICES=("automine" "automine2")

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   XCB Autominer2 Setup v$AUTOMINE_VERSION        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Coreminer herunterladen / aktualisieren
# ---------------------------------------------------------------------------

download_coreminer() {
    local arch platform json tag url tmp binary

    arch=$(uname -m)
    [[ "$arch" == "aarch64" ]] && arch="arm64"
    platform=$(uname | tr '[:upper:]' '[:lower:]')

    echo "[deploy] Prüfe neueste coreminer-Version..."
    json=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/catchthatrabbit/coreminer/releases/latest" 2>/dev/null)
    tag=$(echo "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$tag" ]]; then
        echo "[deploy] WARNUNG: GitHub API nicht erreichbar."
        if [[ -f "$SCRIPT_DIR/coreminer" ]]; then
            echo "[deploy] Verwende vorhandenen coreminer."
            return
        fi
        echo ""
        echo "  Coreminer konnte nicht automatisch heruntergeladen werden."
        echo "  Optionen:"
        echo "    a) coreminer manuell herunterladen und nach $SCRIPT_DIR/coreminer kopieren"
        echo "    b) Pfad zu einem vorhandenen coreminer-Binary angeben"
        echo ""
        read -rp "Pfad zum coreminer-Binary (oder leer lassen zum Abbrechen): " MANUAL_PATH
        if [[ -z "$MANUAL_PATH" ]]; then
            echo "[deploy] Abbruch."
            exit 1
        fi
        if [[ ! -f "$MANUAL_PATH" ]]; then
            echo "[deploy] FEHLER: Datei nicht gefunden: $MANUAL_PATH"
            exit 1
        fi
        cp "$MANUAL_PATH" "$SCRIPT_DIR/coreminer"
        chmod +x "$SCRIPT_DIR/coreminer"
        echo "[deploy] coreminer von $MANUAL_PATH übernommen."
        return
    fi

    local latest_ver="${tag#v}"

    if [[ -f "$SCRIPT_DIR/coreminer" ]]; then
        local local_ver
        local_ver=$("$SCRIPT_DIR/coreminer" -V 2>/dev/null \
            | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [[ "$local_ver" == "$latest_ver" ]]; then
            echo "[deploy] coreminer v$local_ver ist aktuell – kein Download nötig."
            return
        fi
        echo "[deploy] Update verfügbar: v${local_ver:-?} → $tag"
    else
        echo "[deploy] coreminer nicht gefunden – lade $tag herunter..."
    fi

    url="https://github.com/catchthatrabbit/coreminer/releases/download/${tag}/coreminer-${platform}-${arch}.tar.gz"
    tmp=$(mktemp -d)

    echo "[deploy] Lade herunter: $url"
    if ! curl -L --progress-bar -o "$tmp/coreminer.tar.gz" "$url"; then
        echo "[deploy] FEHLER: Download fehlgeschlagen."
        rm -rf "$tmp"
        exit 1
    fi

    tar -xzf "$tmp/coreminer.tar.gz" -C "$tmp/"
    binary=$(find "$tmp" -name "coreminer" -type f | head -1)

    if [[ -z "$binary" ]]; then
        echo "[deploy] FEHLER: Binary nicht im Archiv gefunden."
        rm -rf "$tmp"
        exit 1
    fi

    mv "$binary" "$SCRIPT_DIR/coreminer"
    chmod +x "$SCRIPT_DIR/coreminer"
    rm -rf "$tmp"
    echo "[deploy] coreminer $tag installiert."
}

download_coreminer

# ---------------------------------------------------------------------------
# Geo-Detection: primären Pool ermitteln
# ---------------------------------------------------------------------------

echo ""
echo "[deploy] Erkenne Serverstandort..."
COUNTRY=$(curl -sf --max-time 5 "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]')

case "$COUNTRY" in
    DE|AT|CH|NL|BE|LU|FR|IT|ES|PT|PL|CZ|SK|HU|RO|BG|HR|SI|RS|GR|CY|MT|LI)
        PRIMARY_POOL="de.catchthatrabbit.com" ;;
    FI|NO|SE|DK|IS|EE|LV|LT|GB|IE|BY|UA|RU)
        PRIMARY_POOL="fi.catchthatrabbit.com" ;;
    SG|TH|PH|MY|ID|VN|MM|IN|AU|NZ|PK|BD|LK|NP)
        PRIMARY_POOL="sg.catchthatrabbit.com" ;;
    HK|CN|JP|KR|TW|MO)
        PRIMARY_POOL="hk.catchthatrabbit.com" ;;
    US|CA|MX|BR|AR|CL|CO|PE|VE|EC|BO|PY|UY|CR|PA|GT|HN|SV)
        PRIMARY_POOL="us.catchthatrabbit.com" ;;
    *)
        PRIMARY_POOL="de.catchthatrabbit.com" ;;
esac

echo "[deploy] Land: ${COUNTRY:-unbekannt} → primärer Pool: $PRIMARY_POOL"

# Alle Pools, primärer zuerst
ALL_POOLS=(
    "de.catchthatrabbit.com"
    "fi.catchthatrabbit.com"
    "sg.catchthatrabbit.com"
    "hk.catchthatrabbit.com"
    "us.catchthatrabbit.com"
)
ORDERED_POOLS=("$PRIMARY_POOL")
for p in "${ALL_POOLS[@]}"; do
    [[ "$p" != "$PRIMARY_POOL" ]] && ORDERED_POOLS+=("$p")
done

# ---------------------------------------------------------------------------
# Eingaben
# ---------------------------------------------------------------------------

echo ""

# Worker-Name
read -rp "Worker-Name (z.B. Ccloud06): " WORKER
while [[ -z "$WORKER" ]]; do
    echo "  Worker-Name darf nicht leer sein."
    read -rp "Worker-Name: " WORKER
done

# CPU-Threads
CPU_THREADS=$(nproc)
echo "  Diese CPU hat $CPU_THREADS Threads."
echo ""

read -rp "Maximale Thread-Anzahl [Standard: $CPU_THREADS]: " MAX_THREADS
MAX_THREADS="${MAX_THREADS:-$CPU_THREADS}"
while ! [[ "$MAX_THREADS" =~ ^[0-9]+$ ]] || (( MAX_THREADS < 1 || MAX_THREADS > 128 )); do
    echo "  Bitte eine Zahl zwischen 1 und 128 eingeben."
    read -rp "Maximale Thread-Anzahl: " MAX_THREADS
done

read -rp "Minimale Thread-Anzahl [Standard: 1]: " MIN_THREADS
MIN_THREADS="${MIN_THREADS:-1}"
while ! [[ "$MIN_THREADS" =~ ^[0-9]+$ ]] || (( MIN_THREADS < 1 || MIN_THREADS > MAX_THREADS )); do
    echo "  Bitte eine Zahl zwischen 1 und $MAX_THREADS eingeben."
    read -rp "Minimale Thread-Anzahl: " MIN_THREADS
done

read -rp "Minimale Laufzeit in Minuten [Standard: 5]: " MIN_MIN
MIN_MIN="${MIN_MIN:-5}"
read -rp "Maximale Laufzeit in Minuten [Standard: 15]: " MAX_MIN
MAX_MIN="${MAX_MIN:-15}"

# Status-Server
read -rp "Status-Server URL [Standard: http://10.10.10.125:5000]: " STATUS_URL
STATUS_URL="${STATUS_URL:-http://10.10.10.125:5000}"

# API-Token
read -rp "API-Token (vom Status-Server): " API_TOKEN
while [[ -z "$API_TOKEN" ]]; do
    echo "  API-Token darf nicht leer sein."
    read -rp "API-Token: " API_TOKEN
done

# Hostname fürs Dashboard
DEFAULT_HOST="$(hostname -s)"
read -rp "Hostname fürs Dashboard [Standard: $DEFAULT_HOST]: " CUSTOM_HOST
CUSTOM_HOST="${CUSTOM_HOST:-$DEFAULT_HOST}"

echo ""
echo "── Zusammenfassung ─────────────────────────────────"
echo "  Version:       v$AUTOMINE_VERSION"
echo "  Worker:        $WORKER"
echo "  Threads:       $MIN_THREADS–$MAX_THREADS"
echo "  Laufzeit:      $MIN_MIN–$MAX_MIN Minuten"
echo "  Primärer Pool: $PRIMARY_POOL"
echo "  Status-Server: $STATUS_URL"
echo "  Hostname:      $CUSTOM_HOST"
echo "────────────────────────────────────────────────────"
echo ""
read -rp "Alles korrekt? Weiter? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-J}"
[[ ! "$CONFIRM" =~ ^[Jj]$ ]] && { echo "Abgebrochen."; exit 0; }

# ---------------------------------------------------------------------------
# automine.sh generieren
# ---------------------------------------------------------------------------

THREAD_RANGE=$((MAX_THREADS - MIN_THREADS + 1))
MIN_SEC=$((MIN_MIN * 60))
MAX_SEC=$((MAX_MIN * 60))
WAIT_RANGE=$((MAX_SEC - MIN_SEC + 1))
DEPLOY_DATE="$(date '+%Y-%m-%d %H:%M')"

# Pool-Array für generiertes Script aufbauen
POOL_ARRAY_STR="("
for p in "${ORDERED_POOLS[@]}"; do
    POOL_ARRAY_STR+="\"$p\" "
done
POOL_ARRAY_STR+=")"

cat > "$SCRIPT_DIR/automine.sh" <<SCRIPTEOF
#!/bin/bash
# automine.sh v$AUTOMINE_VERSION – generiert von deploy.sh am $DEPLOY_DATE
# Threads: $MIN_THREADS–$MAX_THREADS  |  Laufzeit: $MIN_MIN–$MAX_MIN min
# Primärer Pool: $PRIMARY_POOL

AUTOMINE_VERSION="$AUTOMINE_VERSION"
DEPLOY_DATE="$DEPLOY_DATE"
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
COREMINER="\$SCRIPT_DIR/coreminer"
STATUS_BASE="$STATUS_URL"
API_TOKEN="$API_TOKEN"
HOSTNAME="$CUSTOM_HOST"
WORKER="$WORKER"
LOG_FILE="/var/log/autominer2/autominer2.log"

POOLS=$POOL_ARRAY_STR

# ---------------------------------------------------------------------------
# Wallet vom Status-Server holen (wartet bis erreichbar)
# ---------------------------------------------------------------------------
fetch_wallet() {
    local wallet=""
    while [[ -z "\$wallet" ]]; do
        wallet=\$(curl -sf --max-time 10 \\
            "\${STATUS_BASE}/wallet?token=\${API_TOKEN}" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "\$wallet" ]]; then
            echo "[automine] Status-Server nicht erreichbar, warte 30s..."
            sleep 30
        fi
    done
    echo "\$wallet"
}

# ---------------------------------------------------------------------------
# Prozess-Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    echo "[automine] Beende..."
    kill "\$REPORTER_PID" 2>/dev/null
    kill -- -"\$MINER_PID" 2>/dev/null
    wait "\$MINER_PID" 2>/dev/null
    echo "[automine] Gestoppt."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Hardware-Features (einmalig beim Start)
# ---------------------------------------------------------------------------
HARD_AES=""
grep -q aes /proc/cpuinfo 2>/dev/null && HARD_AES="--hard-aes"

LARGE_PAGES=""
if [[ -f /proc/sys/vm/nr_hugepages ]] && (( \$(cat /proc/sys/vm/nr_hugepages) > 0 )); then
    LARGE_PAGES="--large-pages"
fi

echo "[automine] Hardware: AES=\${HARD_AES:+ja} LargePages=\${LARGE_PAGES:+ja}"

# ---------------------------------------------------------------------------
# Host-Infos sammeln (einmalig beim Start)
# ---------------------------------------------------------------------------
HOST_IP=\$(hostname -I | awk '{print \$1}')
HOST_OS=\$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
HOST_KERNEL=\$(uname -r)
HOST_CPU=\$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | xargs)
HOST_RAM=\$(free -h 2>/dev/null | awk '/^Mem:/{print \$2}')
HOST_CORES=\$(nproc)

# ---------------------------------------------------------------------------
# Wallet einmalig beim Start holen
# ---------------------------------------------------------------------------
WALLET=\$(fetch_wallet)
echo "[automine] Wallet: \${WALLET:0:6}...\${WALLET: -6}"

# Pool-Argumente bauen
build_pool_args() {
    local w="\$1"
    POOL_ARGS=()
    for pool in "\${POOLS[@]}"; do
        POOL_ARGS+=("-P" "stratum1+tcp://\${w}.\${WORKER}@\${pool}:8008")
    done
}
build_pool_args "\$WALLET"

# ---------------------------------------------------------------------------
# Hashrate-Reporter (Durchschnitt der letzten 10 m-Zeilen)
# ---------------------------------------------------------------------------
hashrate_reporter() {
    local miner_pid=\$1
    while kill -0 "\$miner_pid" 2>/dev/null; do
        sleep 30
        local HR MV
        HR=\$(tail -500 "\$LOG_FILE" 2>/dev/null \\
             | sed 's/\x1b\[[0-9;]*m//g' \\
             | grep " m " \\
             | tail -10 \\
             | grep -oP 'A\d+ \K[\d.]+ [KMG]?h' \\
             | awk '{
                 val=\$1; unit=\$2;
                 if      (unit=="h")  kh=val/1000;
                 else if (unit=="Kh") kh=val;
                 else if (unit=="Mh") kh=val*1000;
                 else if (unit=="Gh") kh=val*1000000;
                 else kh=val;
                 sum+=kh; count++;
               }
               END {
                 if (count>0) {
                   avg=sum/count;
                   if      (avg>=1000000) printf "%.2f Gh", avg/1000000;
                   else if (avg>=1000)    printf "%.2f Mh", avg/1000;
                   else if (avg>=1)       printf "%.2f Kh", avg;
                   else                   printf "%.2f h",  avg*1000;
                 }
               }')
        MV=\$(tail -2000 "\$LOG_FILE" 2>/dev/null \\
             | sed 's/\x1b\[[0-9;]*m//g' \\
             | grep -oP '^v[0-9]+\.[0-9]+\.[0-9]+(\+commit\.[a-f0-9]+)?' \\
             | tail -1)
        if [[ -n "\$HR" ]]; then
            curl -sf -X POST "\${STATUS_BASE}/hashrate" \\
                -H "Content-Type: application/json" \\
                -d "{\\"hostname\\":\\"\$HOSTNAME\\",\\"hashrate\\":\\"\$HR\\",\\"miner_version\\":\\"\$MV\\"}" \\
                >/dev/null || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Hauptschleife
# ---------------------------------------------------------------------------
while true; do
    THREADS=\$(( RANDOM % $THREAD_RANGE + $MIN_THREADS ))
    WAIT_SEC=\$(( RANDOM % $WAIT_RANGE + $MIN_SEC ))
    WAIT_MIN=\$(echo "scale=1; \$WAIT_SEC/60" | bc)
    POOL_SERVER="\${POOLS[0]}"

    echo "[automine] v\$AUTOMINE_VERSION | threads=\$THREADS, Laufzeit=\${WAIT_MIN}min (\${WAIT_SEC}s) | Pool: \$POOL_SERVER"

    # Status melden
    curl -sf -X POST "\${STATUS_BASE}/report" \\
        -H "Content-Type: application/json" \\
        -d "{
          \\"hostname\\":    \\"\$HOSTNAME\\",
          \\"threads\\":     \$THREADS,
          \\"wait_sec\\":    \$WAIT_SEC,
          \\"pool_server\\": \\"\$POOL_SERVER\\",
          \\"worker\\":      \\"\$WORKER\\",
          \\"version\\":     \\"\$AUTOMINE_VERSION\\",
          \\"deploy_date\\": \\"\$DEPLOY_DATE\\",
          \\"host_ip\\":     \\"\$HOST_IP\\",
          \\"host_os\\":     \\"\$HOST_OS\\",
          \\"host_kernel\\": \\"\$HOST_KERNEL\\",
          \\"host_cpu\\":    \\"\$HOST_CPU\\",
          \\"host_ram\\":    \\"\$HOST_RAM\\",
          \\"host_cores\\":  \\"\$HOST_CORES\\"
        }" >/dev/null || echo "[automine] Warnung: Status-Meldung fehlgeschlagen"

    # Coreminer direkt in eigener Prozessgruppe starten
    setsid "\$COREMINER" --noeval \$HARD_AES \$LARGE_PAGES "\${POOL_ARGS[@]}" -t "\$THREADS" &
    MINER_PID=\$!
    echo "[automine] Miner gestartet (PID \$MINER_PID)"

    # Hashrate-Reporter starten
    hashrate_reporter "\$MINER_PID" &
    REPORTER_PID=\$!

    sleep "\$WAIT_SEC"
    echo "[automine] Zeit abgelaufen – beende Miner..."

    kill "\$REPORTER_PID" 2>/dev/null
    kill -- -"\$MINER_PID" 2>/dev/null
    wait "\$MINER_PID" 2>/dev/null

    # Wallet ggf. aktualisieren
    NEW_WALLET=\$(curl -sf --max-time 5 \\
        "\${STATUS_BASE}/wallet?token=\${API_TOKEN}" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "\$NEW_WALLET" && "\$NEW_WALLET" != "\$WALLET" ]]; then
        echo "[automine] Wallet aktualisiert: \${NEW_WALLET:0:6}...\${NEW_WALLET: -6}"
        WALLET="\$NEW_WALLET"
        build_pool_args "\$WALLET"
    fi

    sleep 2
done
SCRIPTEOF

chmod +x "$SCRIPT_DIR/automine.sh"
echo "[deploy] automine.sh v$AUTOMINE_VERSION geschrieben."

# ---------------------------------------------------------------------------
# Alte Services entfernen (falls vorhanden)
# ---------------------------------------------------------------------------

remove_old_services() {
    for svc in "${OLD_SERVICES[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null \
           && systemctl list-unit-files "${svc}.service" | grep -q "${svc}.service"; then
            echo "[deploy] Alter Dienst gefunden: ${svc} – wird entfernt..."
            systemctl stop  "${svc}.service" 2>/dev/null && echo "  ✓ gestoppt" || echo "  (war bereits gestoppt)"
            systemctl disable "${svc}.service" 2>/dev/null && echo "  ✓ deaktiviert" || true
            rm -f "/etc/systemd/system/${svc}.service"
            echo "  ✓ Service-Datei gelöscht: /etc/systemd/system/${svc}.service"
        else
            echo "[deploy] Kein alter Dienst '${svc}' gefunden – nichts zu tun."
        fi
        # Altes logrotate
        if [[ -f "/etc/logrotate.d/${svc}" ]]; then
            rm -f "/etc/logrotate.d/${svc}"
            echo "  ✓ logrotate-Eintrag '${svc}' entfernt."
        fi
    done
    systemctl daemon-reload
}

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
        echo "  Bitte diese Werte in automine.service anpassen:"
        echo "    User=$(whoami)"
        echo "    WorkingDirectory=$SCRIPT_DIR"
        echo "    ExecStart=/bin/bash $SCRIPT_DIR/automine.sh"
        echo ""
        echo "  Danach:"
        echo "    sudo cp $SCRIPT_DIR/automine.service /etc/systemd/system/"
        echo "    sudo systemctl daemon-reload"
        echo "    sudo systemctl enable automine && sudo systemctl start automine"
        echo ""
        echo "  Oder als root erneut ausführen: sudo $SCRIPT_DIR/deploy.sh"
    else
        SERVICE_USER="${SUDO_USER:-$(whoami)}"
        LOG_DIR="/var/log/autominer2"
        LOG_FILE="$LOG_DIR/autominer2.log"

        # Alte Services entfernen
        remove_old_services

        mkdir -p "$LOG_DIR"
        chown "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
        echo "[deploy] Logverzeichnis $LOG_DIR angelegt."

        cat > /etc/logrotate.d/autominer2 <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
        echo "[deploy] logrotate konfiguriert."

        cat > /etc/systemd/system/autominer2.service <<EOF
[Unit]
Description=XCB Autominer2 v$AUTOMINE_VERSION
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
Environment=TERM=xterm
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable autominer2
        systemctl restart autominer2
        echo "[deploy] Dienst autominer2 v$AUTOMINE_VERSION gestartet."
        echo "  Logs: tail -f $LOG_FILE"
    fi
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✓ Setup abgeschlossen v$AUTOMINE_VERSION – Wichtige Befehle          ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Dienst starten      systemctl start autominer2           ║"
echo "║  Dienst stoppen      systemctl stop autominer2            ║"
echo "║  Dienst neu starten  systemctl restart autominer2         ║"
echo "║  Status anzeigen     systemctl status autominer2          ║"
echo "║                                                            ║"
echo "║  Log live lesen      tail -f /var/log/autominer2/autominer2.log ║"
echo "║                                                            ║"
echo "║  Update              git pull && sudo ./deploy.sh         ║"
echo "║                                                            ║"
echo "║  Dashboard:          $STATUS_URL"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
