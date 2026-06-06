# Miner-Status Dashboard – Setup

## 1. Container vorbereiten (Debian 12, IP 10.10.10.125)

```bash
apt update && apt install -y python3 python3-venv curl bc

# Systemuser anlegen (kein Login, kein Home-Verzeichnis)
useradd -r -s /usr/sbin/nologin miner-status

# App-Verzeichnis anlegen
mkdir -p /opt/miner-status
chown miner-status:miner-status /opt/miner-status
```

## 2. Flask-App installieren

```bash
# app.py in den Container kopieren (von deinem Rechner aus):
scp app.py root@10.10.10.125:/opt/miner-status/

# Im Container: virtualenv + Flask
cd /opt/miner-status
python3 -m venv venv
venv/bin/pip install flask

# Kurz testen (Ctrl+C zum Beenden)
venv/bin/python app.py
# → http://10.10.10.125:5000 sollte das leere Dashboard zeigen
```

## 3. systemd-Service einrichten

```bash
# Service-File in den Container kopieren:
scp miner-status.service root@10.10.10.125:/etc/systemd/system/

# Im Container:
systemctl daemon-reload
systemctl enable miner-status
systemctl start miner-status
systemctl status miner-status     # sollte "active (running)" zeigen
```

## 4. Caddy-Config auf dem Proxmox-Host ergänzen

In deine bestehende Caddyfile (oder eine neue Datei in /etc/caddy/conf.d/):

```
status.m8n.de {
    reverse_proxy 10.10.10.125:5000
}
```

Danach:
```bash
caddy reload   # oder: systemctl reload caddy
```

Caddy holt automatisch ein Let's-Encrypt-Zertifikat für status.m8n.de –
dafür muss Port 80/443 öffentlich erreichbar sein und der DNS-Eintrag
status.m8n.de auf die Hetzner-IP zeigen.

## 5. automine.sh auf den Mining-Servern aktualisieren

Die neue automine.sh ersetzen und sicherstellen dass `curl` installiert ist:

```bash
apt install -y curl bc    # oder: yum install curl bc
chmod +x automine.sh
./automine.sh
```

Optionaler eigener Hostname (falls hostname -s nicht aussagekräftig ist):
```bash
CUSTOM_HOSTNAME="miner-berlin-01" ./automine.sh
```

## 6. Überprüfen

```bash
# Manuell eine Meldung schicken (zum Testen):
curl -X POST https://status.m8n.de/report \
  -H "Content-Type: application/json" \
  -d '{"hostname":"test-host","threads":2,"wait_sec":600,"pool_server":"de.catchthatrabbit.com","worker":"Ccloud06"}'

# Logs des Dienstes live verfolgen:
journalctl -u miner-status -f
```

## Dateiübersicht

| Datei                  | Ziel                                    |
|------------------------|-----------------------------------------|
| app.py                 | /opt/miner-status/app.py                |
| miner-status.service   | /etc/systemd/system/miner-status.service|
| automine.sh            | auf jedem Mining-Server                 |
