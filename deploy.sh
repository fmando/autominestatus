#!/bin/bash
# deploy.sh v2.1.0 – XCB Autominer2 Setup
# - Lädt coreminer automatisch herunter / aktualisiert ihn
# - Erkennt Serverstandort für optimale Pool-Wahl
# - Startet coreminer direkt (kein mine.sh)
# - Holt Wallet vom zentralen Status-Server
# - Entfernt alten automine-Dienst automatisch

AUTOMINE_VERSION="2.2.1"
SERVICE_NAME="autominer2"
OLD_SERVICES=("automine" "automine2")
CFG_FILE="$(cd "$(dirname "$0")" && pwd)/.autominer2.cfg"
UPDATE_MODE=false
[[ "$1" == "--update" ]] && UPDATE_MODE=true

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

# Pools: de fi sg hk us – Backup-Reihenfolge nach geografischer Nähe
case "$COUNTRY" in
    # Zentraleuropa / Westeuropa / Südeuropa / Afrika / Naher Osten
    DE|AT|CH|NL|BE|LU|FR|IT|ES|PT|PL|CZ|SK|HU|RO|BG|HR|SI|RS|GR|CY|MT|LI|\
    AL|BA|MK|ME|XK|AD|SM|MC|\
    MA|DZ|TN|LY|EG|ZA|NG|KE|ET|GH|TZ|UG|SD|CM|SN|CI|MZ|AO|ZW|ZM|MW|BW|\
    TR|AE|SA|IL|JO|LB|KW|QA|BH|OM|YE|IQ|IR|SY|AF)
        PRIMARY_POOL="de.catchthatrabbit.com"
        BACKUP_POOLS=("fi.catchthatrabbit.com" "us.catchthatrabbit.com" "sg.catchthatrabbit.com" "hk.catchthatrabbit.com")
        ;;
    # Nordeuropa / Osteuropa / Russland / GUS
    FI|NO|SE|DK|IS|EE|LV|LT|GB|IE|BY|UA|RU|MD|AM|GE|AZ|KZ|UZ|TM|KG|TJ)
        PRIMARY_POOL="fi.catchthatrabbit.com"
        BACKUP_POOLS=("de.catchthatrabbit.com" "us.catchthatrabbit.com" "sg.catchthatrabbit.com" "hk.catchthatrabbit.com")
        ;;
    # Südostasien / Südasien / Ozeanien
    SG|TH|PH|MY|ID|VN|MM|IN|AU|NZ|PK|BD|LK|NP|BT|MV)
        PRIMARY_POOL="sg.catchthatrabbit.com"
        BACKUP_POOLS=("hk.catchthatrabbit.com" "us.catchthatrabbit.com" "fi.catchthatrabbit.com" "de.catchthatrabbit.com")
        ;;
    # Ostasien
    HK|CN|JP|KR|TW|MO|MN)
        PRIMARY_POOL="hk.catchthatrabbit.com"
        BACKUP_POOLS=("sg.catchthatrabbit.com" "us.catchthatrabbit.com" "fi.catchthatrabbit.com" "de.catchthatrabbit.com")
        ;;
    # Amerika
    US|CA|MX|BR|AR|CL|CO|PE|VE|EC|BO|PY|UY|CR|PA|GT|HN|SV|NI|DO|CU|JM|TT|GY|SR|BB|HT|BS|BZ|PR)
        PRIMARY_POOL="us.catchthatrabbit.com"
        BACKUP_POOLS=("de.catchthatrabbit.com" "fi.catchthatrabbit.com" "sg.catchthatrabbit.com" "hk.catchthatrabbit.com")
        ;;
    # Fallback: DE
    *)
        PRIMARY_POOL="de.catchthatrabbit.com"
        BACKUP_POOLS=("fi.catchthatrabbit.com" "us.catchthatrabbit.com" "sg.catchthatrabbit.com" "hk.catchthatrabbit.com")
        ;;
esac

echo "[deploy] Land: ${COUNTRY:-unbekannt} → primärer Pool: $PRIMARY_POOL"

# Pools in Reihenfolge: primärer + geografisch sortierte Backups
ORDERED_POOLS=("$PRIMARY_POOL" "${BACKUP_POOLS[@]}")

# ---------------------------------------------------------------------------
# Eingaben – interaktiv oder aus Config-Datei
# ---------------------------------------------------------------------------

echo ""

if $UPDATE_MODE; then
    # --update: Config laden, keine Rückfragen
    if [[ ! -f "$CFG_FILE" ]]; then
        echo "[deploy] FEHLER: --update angegeben, aber keine Config-Datei gefunden: $CFG_FILE"
        echo "         Bitte einmalig ohne --update ausführen."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CFG_FILE"
    echo "[deploy] Update-Modus: Config geladen aus $CFG_FILE"
    echo "  Worker: $WORKER | Threads: $MIN_THREADS–$MAX_THREADS | Laufzeit: $MIN_MIN–${MAX_MIN}min"
    echo "  Status-Server: $STATUS_URL | Hostname: $CUSTOM_HOST"
    echo ""
else
    # Interaktiver Modus
    CPU_THREADS=$(nproc)

    # Vorhandene Config als Standardwerte anbieten
    if [[ -f "$CFG_FILE" ]]; then
        source "$CFG_FILE"
        echo "[deploy] Vorhandene Konfiguration gefunden – Enter zum Übernehmen, oder neuen Wert eingeben."
        echo ""
    fi

    # Worker-Name
    read -rp "Worker-Name [${WORKER:-z.B. Ccloud06}]: " INPUT
    [[ -n "$INPUT" ]] && WORKER="$INPUT"
    while [[ -z "$WORKER" ]]; do
        echo "  Worker-Name darf nicht leer sein."
        read -rp "Worker-Name: " WORKER
    done

    # CPU-Threads
    echo "  Diese CPU hat $CPU_THREADS Threads."
    echo ""

    read -rp "Maximale Thread-Anzahl [Standard: ${MAX_THREADS:-$CPU_THREADS}]: " INPUT
    [[ -n "$INPUT" ]] && MAX_THREADS="$INPUT"
    MAX_THREADS="${MAX_THREADS:-$CPU_THREADS}"
    while ! [[ "$MAX_THREADS" =~ ^[0-9]+$ ]] || (( MAX_THREADS < 1 || MAX_THREADS > 128 )); do
        echo "  Bitte eine Zahl zwischen 1 und 128 eingeben."
        read -rp "Maximale Thread-Anzahl: " MAX_THREADS
    done

    read -rp "Minimale Thread-Anzahl [Standard: ${MIN_THREADS:-1}]: " INPUT
    [[ -n "$INPUT" ]] && MIN_THREADS="$INPUT"
    MIN_THREADS="${MIN_THREADS:-1}"
    while ! [[ "$MIN_THREADS" =~ ^[0-9]+$ ]] || (( MIN_THREADS < 1 || MIN_THREADS > MAX_THREADS )); do
        echo "  Bitte eine Zahl zwischen 1 und $MAX_THREADS eingeben."
        read -rp "Minimale Thread-Anzahl: " MIN_THREADS
    done

    read -rp "Minimale Laufzeit in Minuten [Standard: ${MIN_MIN:-5}]: " INPUT
    [[ -n "$INPUT" ]] && MIN_MIN="$INPUT"
    MIN_MIN="${MIN_MIN:-5}"

    read -rp "Maximale Laufzeit in Minuten [Standard: ${MAX_MIN:-15}]: " INPUT
    [[ -n "$INPUT" ]] && MAX_MIN="$INPUT"
    MAX_MIN="${MAX_MIN:-15}"

    # Status-Server
    read -rp "Status-Server URL [Standard: ${STATUS_URL:-https://status.m8u.de}]: " INPUT
    [[ -n "$INPUT" ]] && STATUS_URL="$INPUT"
    STATUS_URL="${STATUS_URL:-https://status.m8u.de}"
    if [[ "$STATUS_URL" =~ ^https://[0-9] ]]; then
        echo "  ⚠ Hinweis: https:// mit einer IP-Adresse funktioniert ohne SSL-Zertifikat nicht."
        echo "  Bitte http:// verwenden (z.B. http://10.10.10.125:5000) oder eine Domain mit Zertifikat."
        read -rp "  URL korrigieren: " STATUS_URL_FIX
        [[ -n "$STATUS_URL_FIX" ]] && STATUS_URL="$STATUS_URL_FIX"
    fi

    # API-Token
    read -rp "API-Token [${API_TOKEN:+gesetzt, Enter zum Behalten}]: " INPUT
    [[ -n "$INPUT" ]] && API_TOKEN="$INPUT"
    while [[ -z "$API_TOKEN" ]]; do
        echo "  API-Token darf nicht leer sein."
        read -rp "API-Token: " API_TOKEN
    done

    # Hostname
    DEFAULT_HOST="$(hostname -s)"
    read -rp "Hostname fürs Dashboard [Standard: ${CUSTOM_HOST:-$DEFAULT_HOST}]: " INPUT
    [[ -n "$INPUT" ]] && CUSTOM_HOST="$INPUT"
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
fi

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
            echo "[automine] Status-Server nicht erreichbar, warte 30s..." >&2
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
# Konfiguration speichern (für spätere Updates via --update)
# ---------------------------------------------------------------------------

cat > "$CFG_FILE" <<CFGEOF
# Autominer2 Konfiguration – gespeichert am $(date '+%Y-%m-%d %H:%M')
WORKER="$WORKER"
MIN_THREADS="$MIN_THREADS"
MAX_THREADS="$MAX_THREADS"
MIN_MIN="$MIN_MIN"
MAX_MIN="$MAX_MIN"
STATUS_URL="$STATUS_URL"
API_TOKEN="$API_TOKEN"
CUSTOM_HOST="$CUSTOM_HOST"
CFGEOF
chmod 600 "$CFG_FILE"
echo "[deploy] Konfiguration gespeichert: $CFG_FILE"

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
