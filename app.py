#!/usr/bin/env python3
"""
XCB Miner-Status Dashboard
Empfängt Push-Meldungen von automine.sh und zeigt alle Instanzen.
"""

import sqlite3
import time
import os
from datetime import datetime
from flask import Flask, request, jsonify, render_template_string

app = Flask(__name__)
APP_VERSION = "2.2.0"
DB          = "/opt/miner-status/status.db"
TOKEN_FILE  = "/opt/miner-status/token.cfg"
WALLET_FILE = "/opt/miner-status/wallet.cfg"
DEAD_AFTER  = 20 * 60  # Sekunden – Instanz gilt als tot


# ---------------------------------------------------------------------------
# Token / Wallet
# ---------------------------------------------------------------------------

def load_token():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except Exception:
        return None

def load_wallet():
    try:
        with open(WALLET_FILE) as f:
            return f.read().strip()
    except Exception:
        return ""

def save_wallet(wallet):
    os.makedirs(os.path.dirname(WALLET_FILE), exist_ok=True)
    with open(WALLET_FILE, "w") as f:
        f.write(wallet.strip())

def check_token(req):
    """Gibt True zurück wenn Token korrekt."""
    token = load_token()
    if not token:
        return False
    provided = req.args.get("token") or req.form.get("token") \
               or req.headers.get("X-Token")
    return provided == token


# ---------------------------------------------------------------------------
# Datenbank
# ---------------------------------------------------------------------------

def get_db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with get_db() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS miners (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                hostname    TEXT NOT NULL,
                threads     INTEGER,
                wait_sec    INTEGER,
                pool_server TEXT,
                worker      TEXT,
                hashrate    TEXT,
                version     TEXT,
                deploy_date TEXT,
                host_ip     TEXT,
                host_os     TEXT,
                host_kernel TEXT,
                host_cpu    TEXT,
                host_ram    TEXT,
                host_cores    TEXT,
                miner_version TEXT,
                reported_at INTEGER,
                started_at  INTEGER
            )
        """)
        db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_host ON miners(hostname)")
        db.execute("""
            CREATE TABLE IF NOT EXISTS history (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                hostname    TEXT NOT NULL,
                threads     INTEGER,
                wait_sec    INTEGER,
                pool_server TEXT,
                worker      TEXT,
                avg_hashrate TEXT,
                reported_at INTEGER
            )
        """)
        db.execute("CREATE INDEX IF NOT EXISTS idx_hist_host ON history(hostname)")

        db.execute("""
            CREATE TABLE IF NOT EXISTS hashrate_history (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                hostname    TEXT NOT NULL,
                hashrate_kh REAL,
                reported_at INTEGER
            )
        """)
        db.execute("CREATE INDEX IF NOT EXISTS idx_hr_host ON hashrate_history(hostname, reported_at)")

        # Migration: fehlende Spalten in miners nachrüsten
        cols = [r[1] for r in db.execute("PRAGMA table_info(miners)").fetchall()]
        for col, typ in [
            ("hashrate",      "TEXT"),
            ("version",       "TEXT"),
            ("deploy_date",   "TEXT"),
            ("host_ip",       "TEXT"),
            ("host_os",       "TEXT"),
            ("host_kernel",   "TEXT"),
            ("host_cpu",      "TEXT"),
            ("host_ram",      "TEXT"),
            ("host_cores",    "TEXT"),
            ("miner_version", "TEXT"),
        ]:
            if col not in cols:
                db.execute(f"ALTER TABLE miners ADD COLUMN {col} {typ}")

        # Migration: fehlende Spalten in history nachrüsten
        hist_cols = [r[1] for r in db.execute("PRAGMA table_info(history)").fetchall()]
        if "avg_hashrate" not in hist_cols:
            db.execute("ALTER TABLE history ADD COLUMN avg_hashrate TEXT")

        db.commit()


# ---------------------------------------------------------------------------
# Hashrate-Hilfsfunktionen
# ---------------------------------------------------------------------------

def parse_hashrate_kh(hr_str):
    """Konvertiert Hashrate-String zu Kh-Wert."""
    if not hr_str:
        return 0.0
    parts = hr_str.strip().split()
    if len(parts) != 2:
        return 0.0
    try:
        val = float(parts[0])
        unit = parts[1].lower()
        if unit == 'h':    return val / 1000
        if unit == 'kh':   return val
        if unit == 'mh':   return val * 1000
        if unit == 'gh':   return val * 1_000_000
        return val
    except Exception:
        return 0.0


def format_hashrate(kh):
    """Formatiert Kh-Wert zu lesbarem String."""
    if kh <= 0:
        return None
    if kh >= 1_000_000:
        return f"{kh/1_000_000:.2f} Gh"
    if kh >= 1000:
        return f"{kh/1000:.2f} Mh"
    if kh >= 1:
        return f"{kh:.2f} Kh"
    return f"{kh*1000:.2f} h"


# ---------------------------------------------------------------------------
# Hilfsfunktion: lesbares Alter
# ---------------------------------------------------------------------------

def fmt_age(age):
    if age < 60:
        return f"{age}s"
    elif age < 3600:
        return f"{age // 60}m {age % 60}s"
    else:
        return f"{age // 3600}h {(age % 3600) // 60}m"


# ---------------------------------------------------------------------------
# CSS (geteilt)
# ---------------------------------------------------------------------------

SHARED_CSS = """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      background: #0f1117;
      color: #e0e0e0;
      padding: 2rem;
    }
    h1 { font-size: 1.6rem; margin-bottom: 0.3rem; color: #fff; }
    h2 { font-size: 1.2rem; color: #fff; margin-bottom: 0.3rem; }
    a { color: #4a9eff; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .subtitle { font-size: 0.85rem; color: #666; margin-bottom: 2rem; }
    table { width: 100%; border-collapse: collapse; font-size: 0.95rem; }
    th {
      text-align: left; padding: 0.6rem 1rem;
      background: #1e2030; color: #888;
      font-weight: 600; font-size: 0.78rem;
      text-transform: uppercase; letter-spacing: .05em;
      border-bottom: 1px solid #2a2d3e;
    }
    td { padding: 0.75rem 1rem; border-bottom: 1px solid #1a1d2e; vertical-align: middle; }
    tr:hover td { background: #161825; }
    .badge { display: inline-block; padding: 0.2em 0.65em; border-radius: 999px; font-size: 0.78rem; font-weight: 700; }
    .alive  { background: #1a3a2a; color: #4caf82; }
    .dead   { background: #3a1a1a; color: #e05555; }
    .threads-bar { display: flex; gap: 4px; align-items: center; }
    .dot { width: 12px; height: 12px; border-radius: 3px; background: #2a4a6a; }
    .dot.active { background: #4a9eff; }
    .host { font-weight: 600; color: #fff; }
    .host a { color: #fff; text-decoration: none; }
    .host a:hover { text-decoration: underline; }
    .ago  { color: #666; font-size: 0.82rem; }
    .hashrate { font-weight: 600; color: #f0a040; font-variant-numeric: tabular-nums; }
    .hashrate-none { color: #444; font-size: 0.82rem; }
    .version { font-size: 0.78rem; color: #4a9eff; }
    .deploy  { font-size: 0.78rem; color: #556; }
    .empty { text-align: center; padding: 3rem; color: #444; }
    .stats { display: flex; gap: 1.5rem; margin-bottom: 2rem; flex-wrap: wrap; }
    .stat { background: #1e2030; border-radius: 10px; padding: 1rem 1.5rem; }
    .stat-value { font-size: 2rem; font-weight: 700; color: #fff; }
    .stat-label { font-size: 0.78rem; color: #666; margin-top: 0.2rem; }
    .back { display: inline-block; margin-bottom: 1.5rem; font-size: 0.88rem; color: #4a9eff; }
    .info-grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: 1rem; margin-bottom: 2rem;
    }
    .info-card { background: #1e2030; border-radius: 8px; padding: 0.8rem 1rem; }
    .info-label { font-size: 0.72rem; color: #666; text-transform: uppercase; letter-spacing: .05em; margin-bottom: 0.3rem; }
    .info-value { font-size: 0.92rem; color: #e0e0e0; word-break: break-all; }
    th.sortable { cursor: pointer; user-select: none; }
    th.sortable:hover { color: #bbb; }
    th.sort-asc::after  { content: ' ▲'; color: #4a9eff; }
    th.sort-desc::after { content: ' ▼'; color: #4a9eff; }
"""

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

DASHBOARD = """
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>XCB Miner Status</title>
  <style>{{ css | safe }}</style>
</head>
<body>
  <h1>⛏ XCB Miner Status</h1>
  <p class="subtitle">Aktualisiert automatisch alle 30 Sekunden &nbsp;·&nbsp; Zuletzt: {{ now }}
    &nbsp;·&nbsp; <span style="color:#4a9eff;font-size:0.8rem;">Dashboard v{{ app_version }}</span>
    &nbsp;·&nbsp; <a href="/admin?token=" style="color:#556;font-size:0.8rem;">⚙ Wallet</a>
  </p>

  <div class="stats">
    <div class="stat">
      <div class="stat-value">{{ total }}</div>
      <div class="stat-label">Instanzen gesamt</div>
    </div>
    <div class="stat">
      <div class="stat-value" style="color:#4caf82">{{ alive }}</div>
      <div class="stat-label">Aktiv</div>
    </div>
    <div class="stat">
      <div class="stat-value" style="color:#e05555">{{ dead }}</div>
      <div class="stat-label">Inaktiv / tot</div>
    </div>
    <div class="stat">
      <div class="stat-value">{{ total_threads }}</div>
      <div class="stat-label">Threads gesamt</div>
    </div>
    <div class="stat">
      <div class="stat-value" style="color:#f0a040">{{ total_hashrate or '–' }}</div>
      <div class="stat-label">Hashrate gesamt</div>
    </div>
  </div>

  {% if miners %}
  <table>
    <thead>
      <tr id="header-row">
        <th class="sortable" data-col="0">Host</th>
        <th class="sortable" data-col="1">Status</th>
        <th class="sortable" data-col="2">Threads</th>
        <th class="sortable" data-col="3">Hashrate</th>
        <th class="sortable" data-col="4">Laufzeit</th>
        <th class="sortable" data-col="5">Pool-Server</th>
        <th class="sortable" data-col="6">Worker</th>
        <th class="sortable" data-col="7">Version</th>
        <th class="sortable" data-col="8">Letztes Lebenszeichen</th>
      </tr>
    </thead>
    <tbody>
    {% for m in miners %}
      <tr>
        <td class="host"><a href="/host/{{ m.hostname }}">{{ m.hostname }}</a></td>
        <td>
          {% if m.is_alive %}<span class="badge alive">● aktiv</span>
          {% else %}<span class="badge dead">✕ tot</span>{% endif %}
        </td>
        <td>
          <div class="threads-bar">
            {% for i in range(1, 25) %}
              <div class="dot {% if i <= m.threads %}active{% endif %}"></div>
            {% endfor %}
            &nbsp;{{ m.threads }}
          </div>
        </td>
        <td>
          {% if m.hashrate %}<span class="hashrate">{{ m.hashrate }}</span>
          {% else %}<span class="hashrate-none">–</span>{% endif %}
        </td>
        <td>{{ m.wait_min }} min</td>
        <td>{{ m.pool_server }}</td>
        <td>{{ m.worker }}</td>
        <td>
          {% if m.version %}<span class="version">v{{ m.version }}</span><br>{% endif %}
          <span class="deploy">{{ m.deploy_date or '–' }}</span>
        </td>
        <td>{{ m.reported_str }} <span class="ago">(vor {{ m.ago }})</span></td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}
  <div class="empty">Noch keine Meldungen eingegangen.</div>
  {% endif %}
</body>
<script>
(function() {
  var currentCol = 0, ascending = true;
  function cellValue(row, col) {
    var td = row.querySelectorAll('td')[col];
    return td ? td.innerText.trim() : '';
  }
  function sortTable(col) {
    if (currentCol === col) { ascending = !ascending; }
    else { currentCol = col; ascending = true; }
    document.querySelectorAll('th.sortable').forEach(function(th) {
      th.classList.remove('sort-asc', 'sort-desc');
      if (parseInt(th.dataset.col) === currentCol)
        th.classList.add(ascending ? 'sort-asc' : 'sort-desc');
    });
    var tbody = document.querySelector('tbody');
    if (!tbody) return;
    var rows = Array.from(tbody.querySelectorAll('tr'));
    rows.sort(function(a, b) {
      var av = cellValue(a, currentCol), bv = cellValue(b, currentCol);
      var an = parseFloat(av), bn = parseFloat(bv);
      var cmp = (!isNaN(an) && !isNaN(bn)) ? an - bn : av.localeCompare(bv, 'de');
      return ascending ? cmp : -cmp;
    });
    rows.forEach(function(r) { tbody.appendChild(r); });
  }
  document.querySelectorAll('th.sortable').forEach(function(th) {
    th.addEventListener('click', function() { sortTable(parseInt(th.dataset.col)); });
  });
  sortTable(0);
})();
</script>
</html>
"""

# ---------------------------------------------------------------------------
# Host-Detailseite
# ---------------------------------------------------------------------------

HISTORY_PAGE = """
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ hostname }} – Details</title>
  <style>{{ css | safe }}</style>
</head>
<body>
  <a class="back" href="/">← Zurück zur Übersicht</a>
  <h2>⛏ {{ hostname }}</h2>
  {% if info.version %}
  <p class="subtitle">
    automine v{{ info.version }} &nbsp;·&nbsp; deployed {{ info.deploy_date or '–' }}
    {% if info.miner_version %}&nbsp;·&nbsp; coreminer {{ info.miner_version }}{% endif %}
  </p>
  {% endif %}

  {% if info.host_ip %}
  <div class="info-grid">
    <div class="info-card">
      <div class="info-label">IP-Adresse</div>
      <div class="info-value">{{ info.host_ip }}</div>
    </div>
    <div class="info-card">
      <div class="info-label">Betriebssystem</div>
      <div class="info-value">{{ info.host_os or '–' }}</div>
    </div>
    <div class="info-card">
      <div class="info-label">Kernel</div>
      <div class="info-value">{{ info.host_kernel or '–' }}</div>
    </div>
    <div class="info-card">
      <div class="info-label">CPU</div>
      <div class="info-value">{{ info.host_cpu or '–' }}</div>
    </div>
    <div class="info-card">
      <div class="info-label">CPU-Kerne</div>
      <div class="info-value">{{ info.host_cores or '–' }}</div>
    </div>
    <div class="info-card">
      <div class="info-label">RAM gesamt</div>
      <div class="info-value">{{ info.host_ram or '–' }}</div>
    </div>
  </div>
  {% endif %}

  {% if overall_avg %}
  <div class="stats" style="margin-bottom:1.5rem;">
    <div class="stat">
      <div class="stat-value" style="color:#f0a040">{{ overall_avg }}</div>
      <div class="stat-label">Ø Hashrate ({{ session_count }} Sessions)</div>
    </div>
    <div class="stat">
      <div class="stat-value">{{ total }}</div>
      <div class="stat-label">Sessions gesamt</div>
    </div>
  </div>
  {% endif %}

  <p class="subtitle">{{ total }} Einträge in der Historie</p>

  {% if rows %}
  <table>
    <thead>
      <tr>
        <th>#</th>
        <th>Zeitpunkt</th>
        <th>Threads</th>
        <th>Laufzeit</th>
        <th>Ø Hashrate</th>
        <th>Pool-Server</th>
        <th>Worker</th>
      </tr>
    </thead>
    <tbody>
    {% for r in rows %}
      <tr>
        <td style="color:#444">{{ loop.index }}</td>
        <td>{{ r.reported_str }} <span class="ago">(vor {{ r.ago }})</span></td>
        <td>
          <div class="threads-bar">
            {% for i in range(1, 25) %}
              <div class="dot {% if i <= r.threads %}active{% endif %}"></div>
            {% endfor %}
            &nbsp;{{ r.threads }}
          </div>
        </td>
        <td>{{ r.wait_min }} min</td>
        <td>
          {% if r.avg_hashrate %}<span class="hashrate">{{ r.avg_hashrate }}</span>
          {% else %}<span class="hashrate-none">–</span>{% endif %}
        </td>
        <td>{{ r.pool_server }}</td>
        <td>{{ r.worker }}</td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}
  <div class="empty">Keine Historie für diesen Host gefunden.</div>
  {% endif %}
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Routen
# ---------------------------------------------------------------------------

@app.route("/report", methods=["POST"])
def report():
    data = request.get_json(silent=True) or request.form
    if not all(k in data for k in ("hostname", "threads", "wait_sec")):
        return jsonify({"error": "Fehlende Felder"}), 400

    now = int(time.time())
    params = {
        "hostname":    data.get("hostname"),
        "threads":     int(data.get("threads", 1)),
        "wait_sec":    int(data.get("wait_sec", 0)),
        "pool_server": data.get("pool_server", "?"),
        "worker":      data.get("worker", "?"),
        "version":     data.get("version"),
        "deploy_date": data.get("deploy_date"),
        "host_ip":     data.get("host_ip"),
        "host_os":     data.get("host_os"),
        "host_kernel": data.get("host_kernel"),
        "host_cpu":    data.get("host_cpu"),
        "host_ram":    data.get("host_ram"),
        "host_cores":  data.get("host_cores"),
        "now":         now,
    }

    hostname = params["hostname"]

    with get_db() as db:
        # Abgeschlossene Session: Hashrate-Durchschnitt berechnen und in letzten History-Eintrag schreiben
        last = db.execute(
            "SELECT id, reported_at FROM history WHERE hostname = ? ORDER BY reported_at DESC LIMIT 1",
            (hostname,)
        ).fetchone()
        if last:
            row = db.execute("""
                SELECT AVG(hashrate_kh) AS avg_kh FROM hashrate_history
                WHERE hostname = ? AND reported_at >= ?
            """, (hostname, last["reported_at"])).fetchone()
            if row and row["avg_kh"]:
                db.execute(
                    "UPDATE history SET avg_hashrate = ? WHERE id = ?",
                    (format_hashrate(row["avg_kh"]), last["id"])
                )
            # Verarbeitete Einträge aufräumen
            db.execute(
                "DELETE FROM hashrate_history WHERE hostname = ? AND reported_at < ?",
                (hostname, now)
            )

        db.execute("""
            INSERT INTO miners (hostname, threads, wait_sec, pool_server, worker,
                                hashrate, version, deploy_date,
                                host_ip, host_os, host_kernel, host_cpu, host_ram, host_cores,
                                reported_at, started_at)
            VALUES (:hostname, :threads, :wait_sec, :pool_server, :worker,
                    NULL, :version, :deploy_date,
                    :host_ip, :host_os, :host_kernel, :host_cpu, :host_ram, :host_cores,
                    :now, :now)
            ON CONFLICT(hostname) DO UPDATE SET
                threads     = excluded.threads,
                wait_sec    = excluded.wait_sec,
                pool_server = excluded.pool_server,
                worker      = excluded.worker,
                hashrate    = NULL,
                version     = excluded.version,
                deploy_date = excluded.deploy_date,
                host_ip     = excluded.host_ip,
                host_os     = excluded.host_os,
                host_kernel = excluded.host_kernel,
                host_cpu    = excluded.host_cpu,
                host_ram    = excluded.host_ram,
                host_cores  = excluded.host_cores,
                reported_at = excluded.reported_at,
                started_at  = excluded.started_at
        """, params)

        db.execute("""
            INSERT INTO history (hostname, threads, wait_sec, pool_server, worker, reported_at)
            VALUES (:hostname, :threads, :wait_sec, :pool_server, :worker, :now)
        """, params)

        db.commit()
    return jsonify({"ok": True}), 200


@app.route("/hashrate", methods=["POST"])
def hashrate():
    data = request.get_json(silent=True) or request.form
    if not data or "hostname" not in data or "hashrate" not in data:
        return jsonify({"error": "Fehlende Felder"}), 400
    kh = parse_hashrate_kh(data.get("hashrate"))
    with get_db() as db:
        db.execute("""
            UPDATE miners SET
                hashrate      = ?,
                miner_version = COALESCE(?, miner_version)
            WHERE hostname = ?
        """, (data.get("hashrate"), data.get("miner_version") or None, data.get("hostname")))
        if kh > 0:
            db.execute(
                "INSERT INTO hashrate_history (hostname, hashrate_kh, reported_at) VALUES (?, ?, ?)",
                (data.get("hostname"), kh, int(time.time()))
            )
        db.commit()
    return jsonify({"ok": True}), 200


@app.route("/", methods=["GET"])
def dashboard():
    now = int(time.time())
    with get_db() as db:
        rows = db.execute("SELECT * FROM miners ORDER BY reported_at DESC").fetchall()

    miners = []
    alive_count = 0
    total_threads = 0
    total_kh = 0.0

    for r in rows:
        age = now - r["reported_at"]
        is_alive = age < DEAD_AFTER
        if is_alive:
            alive_count += 1
            total_threads += r["threads"]
            total_kh += parse_hashrate_kh(r["hashrate"])

        miners.append({
            "hostname":     r["hostname"],
            "threads":      r["threads"],
            "wait_min":     round(r["wait_sec"] / 60, 1),
            "pool_server":  r["pool_server"],
            "worker":       r["worker"],
            "hashrate":     r["hashrate"] if is_alive else None,
            "version":      r["version"],
            "deploy_date":  r["deploy_date"],
            "is_alive":     is_alive,
            "reported_str": datetime.fromtimestamp(r["reported_at"]).strftime("%d.%m.%Y %H:%M:%S"),
            "ago":          fmt_age(age),
        })

    return render_template_string(
        DASHBOARD,
        css=SHARED_CSS,
        miners=miners,
        now=datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
        total=len(miners),
        alive=alive_count,
        dead=len(miners) - alive_count,
        total_threads=total_threads,
        total_hashrate=format_hashrate(total_kh),
        app_version=APP_VERSION,
    )


@app.route("/host/<hostname>", methods=["GET"])
def host_history(hostname):
    now = int(time.time())
    with get_db() as db:
        info_row = db.execute("SELECT * FROM miners WHERE hostname = ?", (hostname,)).fetchone()
        rows = db.execute(
            "SELECT * FROM history WHERE hostname = ? ORDER BY reported_at DESC",
            (hostname,)
        ).fetchall()

    info = dict(info_row) if info_row else {}

    entries = []
    session_kh_values = []
    for r in rows:
        kh = parse_hashrate_kh(r["avg_hashrate"]) if r["avg_hashrate"] else 0.0
        if kh > 0:
            session_kh_values.append(kh)
        entries.append({
            "threads":      r["threads"],
            "wait_min":     round(r["wait_sec"] / 60, 1),
            "pool_server":  r["pool_server"],
            "worker":       r["worker"],
            "avg_hashrate": r["avg_hashrate"] or None,
            "reported_str": datetime.fromtimestamp(r["reported_at"]).strftime("%d.%m.%Y %H:%M:%S"),
            "ago":          fmt_age(now - r["reported_at"]),
        })

    overall_avg = format_hashrate(sum(session_kh_values) / len(session_kh_values)) \
                  if session_kh_values else None

    return render_template_string(
        HISTORY_PAGE,
        css=SHARED_CSS,
        hostname=hostname,
        info=info,
        rows=entries,
        total=len(entries),
        overall_avg=overall_avg,
        session_count=len(session_kh_values),
    )


@app.route("/wallet", methods=["GET"])
def get_wallet():
    if not check_token(request):
        return "Unauthorized", 401
    return load_wallet(), 200


@app.route("/wallet", methods=["POST"])
def set_wallet():
    if not check_token(request):
        return "Unauthorized", 401
    wallet = (request.form.get("wallet") or "").strip()
    if not wallet:
        return jsonify({"error": "Wallet darf nicht leer sein"}), 400
    save_wallet(wallet)
    return jsonify({"ok": True, "wallet": wallet[:6] + "..." + wallet[-6:]}), 200


ADMIN_PAGE = """
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Admin – Wallet</title>
  <style>{{ css | safe }}</style>
</head>
<body>
  <a class="back" href="/">← Zurück zur Übersicht</a>
  <h1>⚙ Wallet verwalten</h1>
  <p class="subtitle">Änderungen werden beim nächsten Miner-Neustart auf allen Servern aktiv.</p>

  {% if message %}
  <div style="background:#1a3a2a;color:#4caf82;padding:0.8rem 1.2rem;border-radius:8px;margin-bottom:1.5rem;">
    {{ message }}
  </div>
  {% endif %}

  <div style="background:#1e2030;border-radius:10px;padding:1.5rem;max-width:600px;">
    <div style="margin-bottom:1.2rem;">
      <div style="font-size:0.78rem;color:#666;text-transform:uppercase;letter-spacing:.05em;margin-bottom:0.4rem;">
        Aktuelle Wallet
      </div>
      <div style="font-family:monospace;font-size:0.9rem;color:#4a9eff;word-break:break-all;">
        {{ wallet or '(nicht gesetzt)' }}
      </div>
    </div>

    <form method="POST" action="/admin?token={{ token }}">
      <div style="margin-bottom:1rem;">
        <label style="font-size:0.85rem;color:#888;display:block;margin-bottom:0.4rem;">
          Neue Wallet-Adresse
        </label>
        <input type="text" name="wallet" value="{{ wallet }}"
          style="width:100%;background:#0f1117;border:1px solid #2a2d3e;border-radius:6px;
                 padding:0.6rem 0.8rem;color:#e0e0e0;font-family:monospace;font-size:0.9rem;">
      </div>
      <button type="submit"
        style="background:#4a9eff;color:#fff;border:none;border-radius:6px;
               padding:0.6rem 1.5rem;cursor:pointer;font-size:0.9rem;font-weight:600;">
        Speichern
      </button>
    </form>
  </div>
</body>
</html>
"""


@app.route("/admin", methods=["GET", "POST"])
def admin():
    if not check_token(request):
        return "Unauthorized", 401

    message = None
    if request.method == "POST":
        wallet = (request.form.get("wallet") or "").strip()
        if wallet:
            save_wallet(wallet)
            message = f"Wallet gespeichert: {wallet[:6]}...{wallet[-6:]}"

    token = request.args.get("token") or request.form.get("token") or ""
    return render_template_string(
        ADMIN_PAGE,
        css=SHARED_CSS,
        wallet=load_wallet(),
        token=token,
        message=message,
    )


@app.route("/ping")
def ping():
    return "pong", 200


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=5000)
