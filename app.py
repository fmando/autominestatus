#!/usr/bin/env python3
"""
Miner-Status Dashboard
Empfängt Push-Meldungen von automine.sh und zeigt alle Instanzen.
"""

import sqlite3
import time
from datetime import datetime
from flask import Flask, request, jsonify, render_template_string

app = Flask(__name__)
DB = "/opt/miner-status/status.db"
DEAD_AFTER = 20 * 60  # Sekunden – Instanz gilt als tot


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
                reported_at INTEGER
            )
        """)
        db.execute("CREATE INDEX IF NOT EXISTS idx_hist_host ON history(hostname)")
        db.commit()


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
# CSS (geteilt zwischen Dashboard und Historie)
# ---------------------------------------------------------------------------

SHARED_CSS = """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      background: #0f1117;
      color: #e0e0e0;
      padding: 2rem;
    }
    h1 {
      font-size: 1.6rem;
      margin-bottom: 0.3rem;
      color: #fff;
    }
    h2 {
      font-size: 1.2rem;
      color: #fff;
      margin-bottom: 0.3rem;
    }
    a { color: #4a9eff; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .subtitle {
      font-size: 0.85rem;
      color: #666;
      margin-bottom: 2rem;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.95rem;
    }
    th {
      text-align: left;
      padding: 0.6rem 1rem;
      background: #1e2030;
      color: #888;
      font-weight: 600;
      font-size: 0.78rem;
      text-transform: uppercase;
      letter-spacing: .05em;
      border-bottom: 1px solid #2a2d3e;
    }
    td {
      padding: 0.75rem 1rem;
      border-bottom: 1px solid #1a1d2e;
      vertical-align: middle;
    }
    tr:hover td { background: #161825; }
    .badge {
      display: inline-block;
      padding: 0.2em 0.65em;
      border-radius: 999px;
      font-size: 0.78rem;
      font-weight: 700;
    }
    .alive  { background: #1a3a2a; color: #4caf82; }
    .dead   { background: #3a1a1a; color: #e05555; }
    .threads-bar {
      display: flex;
      gap: 4px;
      align-items: center;
    }
    .dot {
      width: 12px; height: 12px;
      border-radius: 3px;
      background: #2a4a6a;
    }
    .dot.active { background: #4a9eff; }
    .host { font-weight: 600; color: #fff; }
    .host a { color: #fff; text-decoration: none; }
    .host a:hover { text-decoration: underline; }
    .ago  { color: #666; font-size: 0.82rem; }
    .empty {
      text-align: center;
      padding: 3rem;
      color: #444;
    }
    .stats {
      display: flex;
      gap: 1.5rem;
      margin-bottom: 2rem;
      flex-wrap: wrap;
    }
    .stat {
      background: #1e2030;
      border-radius: 10px;
      padding: 1rem 1.5rem;
    }
    .stat-value { font-size: 2rem; font-weight: 700; color: #fff; }
    .stat-label { font-size: 0.78rem; color: #666; margin-top: 0.2rem; }
    .back {
      display: inline-block;
      margin-bottom: 1.5rem;
      font-size: 0.88rem;
      color: #4a9eff;
    }
"""

# ---------------------------------------------------------------------------
# Dashboard-HTML
# ---------------------------------------------------------------------------

DASHBOARD = """
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>Miner Status</title>
  <style>{{ css | safe }}</style>
</head>
<body>
  <h1>⛏ XCB Miner Status</h1>
  <p class="subtitle">Aktualisiert automatisch alle 30 Sekunden &nbsp;·&nbsp;
     Zuletzt: {{ now }}</p>

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
  </div>

  {% if miners %}
  <table>
    <thead>
      <tr>
        <th>Host</th>
        <th>Status</th>
        <th>Threads</th>
        <th>Laufzeit</th>
        <th>Pool-Server</th>
        <th>Worker</th>
        <th>Letztes Lebenszeichen</th>
      </tr>
    </thead>
    <tbody>
    {% for m in miners %}
      <tr>
        <td class="host">
          <a href="/host/{{ m.hostname }}">{{ m.hostname }}</a>
        </td>
        <td>
          {% if m.is_alive %}
            <span class="badge alive">● aktiv</span>
          {% else %}
            <span class="badge dead">✕ tot</span>
          {% endif %}
        </td>
        <td>
          <div class="threads-bar">
            {% for i in range(1, 25) %}
              <div class="dot {% if i <= m.threads %}active{% endif %}"></div>
            {% endfor %}
            &nbsp;{{ m.threads }}
          </div>
        </td>
        <td>{{ m.wait_min }} min</td>
        <td>{{ m.pool_server }}</td>
        <td>{{ m.worker }}</td>
        <td>
          {{ m.reported_str }}
          <span class="ago">(vor {{ m.ago }})</span>
        </td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}
  <div class="empty">Noch keine Meldungen eingegangen.</div>
  {% endif %}
</body>
</html>
"""

# ---------------------------------------------------------------------------
# Historien-HTML
# ---------------------------------------------------------------------------

HISTORY_PAGE = """
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Historie – {{ hostname }}</title>
  <style>{{ css | safe }}</style>
</head>
<body>
  <a class="back" href="/">← Zurück zur Übersicht</a>
  <h2>⛏ {{ hostname }}</h2>
  <p class="subtitle">{{ total }} Einträge gesamt</p>

  {% if rows %}
  <table>
    <thead>
      <tr>
        <th>#</th>
        <th>Zeitpunkt</th>
        <th>Threads</th>
        <th>Laufzeit</th>
        <th>Pool-Server</th>
        <th>Worker</th>
      </tr>
    </thead>
    <tbody>
    {% for r in rows %}
      <tr>
        <td style="color:#444">{{ loop.index }}</td>
        <td>
          {{ r.reported_str }}
          <span class="ago">(vor {{ r.ago }})</span>
        </td>
        <td>
          <div class="threads-bar">
            {% for i in range(1, 25) %}
              <div class="dot {% if i <= r.threads %}active{% endif %}"></div>
            {% endfor %}
            &nbsp;{{ r.threads }}
          </div>
        </td>
        <td>{{ r.wait_min }} min</td>
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
    """Empfängt Status-Meldung von automine.sh."""
    data = request.get_json(silent=True) or request.form
    required = ("hostname", "threads", "wait_sec")
    if not all(k in data for k in required):
        return jsonify({"error": "Fehlende Felder"}), 400

    now = int(time.time())
    params = {
        "hostname":    data.get("hostname"),
        "threads":     int(data.get("threads", 1)),
        "wait_sec":    int(data.get("wait_sec", 0)),
        "pool_server": data.get("pool_server", "?"),
        "worker":      data.get("worker", "?"),
        "now":         now,
    }

    with get_db() as db:
        # Aktuellen Stand aktualisieren
        db.execute("""
            INSERT INTO miners (hostname, threads, wait_sec, pool_server,
                                worker, reported_at, started_at)
            VALUES (:hostname, :threads, :wait_sec, :pool_server,
                    :worker, :now, :now)
            ON CONFLICT(hostname) DO UPDATE SET
                threads     = excluded.threads,
                wait_sec    = excluded.wait_sec,
                pool_server = excluded.pool_server,
                worker      = excluded.worker,
                reported_at = excluded.reported_at,
                started_at  = excluded.started_at
        """, params)

        # Historien-Eintrag hinzufügen
        db.execute("""
            INSERT INTO history (hostname, threads, wait_sec, pool_server,
                                 worker, reported_at)
            VALUES (:hostname, :threads, :wait_sec, :pool_server,
                    :worker, :now)
        """, params)

        db.commit()
    return jsonify({"ok": True}), 200


@app.route("/", methods=["GET"])
def dashboard():
    now = int(time.time())
    with get_db() as db:
        rows = db.execute(
            "SELECT * FROM miners ORDER BY reported_at DESC"
        ).fetchall()

    miners = []
    alive_count = 0
    total_threads = 0

    for r in rows:
        age = now - r["reported_at"]
        is_alive = age < DEAD_AFTER
        if is_alive:
            alive_count += 1
            total_threads += r["threads"]

        miners.append({
            "hostname":     r["hostname"],
            "threads":      r["threads"],
            "wait_min":     round(r["wait_sec"] / 60, 1),
            "pool_server":  r["pool_server"],
            "worker":       r["worker"],
            "is_alive":     is_alive,
            "reported_str": datetime.fromtimestamp(r["reported_at"])
                                    .strftime("%d.%m.%Y %H:%M:%S"),
            "ago":          fmt_age(now - r["reported_at"]),
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
    )


@app.route("/host/<hostname>", methods=["GET"])
def host_history(hostname):
    now = int(time.time())
    with get_db() as db:
        rows = db.execute(
            "SELECT * FROM history WHERE hostname = ? ORDER BY reported_at DESC",
            (hostname,)
        ).fetchall()

    entries = []
    for r in rows:
        entries.append({
            "threads":      r["threads"],
            "wait_min":     round(r["wait_sec"] / 60, 1),
            "pool_server":  r["pool_server"],
            "worker":       r["worker"],
            "reported_str": datetime.fromtimestamp(r["reported_at"])
                                    .strftime("%d.%m.%Y %H:%M:%S"),
            "ago":          fmt_age(now - r["reported_at"]),
        })

    return render_template_string(
        HISTORY_PAGE,
        css=SHARED_CSS,
        hostname=hostname,
        rows=entries,
        total=len(entries),
    )


# ---------------------------------------------------------------------------
# Ping (optional, für Monitoring)
# ---------------------------------------------------------------------------

@app.route("/ping")
def ping():
    return "pong", 200


# ---------------------------------------------------------------------------

if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=5000)
