#!/bin/bash
# ============================================================
# SecureMed Clinic — SETUP vm-app (frontend + backend)
# ============================================================
# Dit script installeert in de juiste volgorde:
#   1. Node.js backend API
#   2. Nginx frontend + loginpagina
#
# De database is mysql-zerotrust (Azure MySQL, privé). Schema en data
# staan in mysql/database.sql en worden daar eenmalig ingeladen.
#
# Gebruik (vm-app heeft geen publiek IP):
#   az vm run-command invoke -g rg-zerotrust -n vm-app \
#     --command-id RunShellScript --scripts @setup-alles.sh
# ============================================================

set -e
export DEBIAN_FRONTEND=noninteractive

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  SecureMed Clinic — Complete Setup           ║"
echo "║  Backend → Frontend → Login                  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# =============================================================
#  STAP 1 — Node.js Backend API
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [1/3] BACKEND installeren..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Bestaande Nginx-sites uitschakelen (alleen de links in sites-enabled;
# sites-available blijft staan) zodat poort 3000 vrij is voor de backend.
if command -v nginx > /dev/null; then
  rm -f /etc/nginx/sites-enabled/*
  systemctl stop nginx
fi

# Oude Node.js van Ubuntu (v12) verwijderen: libnode-dev botst met nodejs 20
apt remove -y nodejs libnode-dev libnode72 npm || true
dpkg --configure -a
apt -f install -y

# Node.js 20 installeren
apt update -qq
apt install -y ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt update -qq
apt install -y nodejs

# App directory
mkdir -p /opt/securemed-backend
cd /opt/securemed-backend

cat > package.json << 'PKGJSON'
{
  "name": "securemed-backend",
  "version": "1.0.0",
  "dependencies": {
    "express": "^4.18.2",
    "mysql2": "^3.6.0",
    "cors": "^2.8.5"
  }
}
PKGJSON

npm install --production 2>&1 | tail -1

# API server
cat > server.js << 'SERVERJS'
const express = require('express');
const mysql   = require('mysql2/promise');
const cors    = require('cors');
const crypto  = require('crypto');

const app = express();
app.use(cors());
app.use(express.json());

// === DATABASE (credentials hardcoded — ONVEILIG) ===
const DB_CONFIG = {
  host:     'mysql-zerotrust.mysql.database.azure.com',
  user:     'securemed_app',
  password: 'SecureMed2026',
  database: 'securemed',
  ssl:      { rejectUnauthorized: true } // Azure MySQL weigert verbindingen zonder TLS
};

let db;
async function connectDB() {
  try {
    db = await mysql.createConnection(DB_CONFIG);
    console.log('[DB] Verbonden met MySQL');
  } catch (err) {
    console.error('[DB] Fout:', err.message);
    setTimeout(connectDB, 5000);
  }
}
connectDB();

// === SESSIES (in-memory, geen expiry — ONVEILIG) ===
const sessions = {};
function generateToken() { return crypto.randomBytes(16).toString('hex'); }

function requireAuth(req, res, next) {
  const token = req.headers['authorization']?.replace('Bearer ', '');
  if (!token || !sessions[token]) return res.status(401).json({ error: 'Niet ingelogd' });
  req.user = sessions[token];
  next();
}

// === AUTH ROUTES ===

app.post('/api/login', async (req, res) => {
  const { gebruikersnaam, wachtwoord } = req.body;
  if (!gebruikersnaam || !wachtwoord) return res.status(400).json({ error: 'Vul beide velden in' });
  try {
    const [rows] = await db.query(
      'SELECT * FROM medewerkers WHERE gebruikersnaam = ? AND wachtwoord = ? AND actief = 1',
      [gebruikersnaam, wachtwoord]
    );
    if (rows.length === 0) {
      const [userCheck] = await db.query('SELECT id FROM medewerkers WHERE gebruikersnaam = ?', [gebruikersnaam]);
      if (userCheck.length > 0) return res.status(401).json({ error: 'Fout wachtwoord' });
      return res.status(401).json({ error: 'Gebruiker niet gevonden' });
    }
    const user = rows[0];
    const token = generateToken();
    sessions[token] = { id: user.id, gebruikersnaam: user.gebruikersnaam, naam: user.volledige_naam, rol: user.rol, email: user.email };
    await db.query('UPDATE medewerkers SET laatst_ingelogd = NOW() WHERE id = ?', [user.id]);
    res.json({ token, user: sessions[token] });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.post('/api/logout', (req, res) => {
  const token = req.headers['authorization']?.replace('Bearer ', '');
  if (token) delete sessions[token];
  res.json({ message: 'Uitgelogd' });
});

app.get('/api/me', requireAuth, (req, res) => { res.json(req.user); });

// === BESCHERMDE ROUTES ===

app.get('/api/health', (req, res) => {
  res.json({ status: 'online', server: 'SecureMed Backend', database: db ? 'verbonden' : 'niet verbonden', timestamp: new Date().toISOString() });
});

app.get('/api/patienten', requireAuth, async (req, res) => {
  try { const [rows] = await db.query('SELECT * FROM patienten ORDER BY achternaam'); res.json(rows); }
  catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/patienten/:id', requireAuth, async (req, res) => {
  try {
    const [rows] = await db.query('SELECT * FROM patienten WHERE id = ?', [req.params.id]);
    if (rows.length === 0) return res.status(404).json({ error: 'Niet gevonden' });
    res.json(rows[0]);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// SQL INJECTION KWETSBAAR (bewust!)
app.get('/api/zoek', requireAuth, async (req, res) => {
  const naam = req.query.naam || '';
  try {
    const query = `SELECT * FROM patienten WHERE voornaam LIKE '%${naam}%' OR achternaam LIKE '%${naam}%'`;
    const [rows] = await db.query(query);
    res.json(rows);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/patienten/:id/dossiers', requireAuth, async (req, res) => {
  try {
    const [rows] = await db.query('SELECT d.*, p.voornaam, p.achternaam FROM dossiers d JOIN patienten p ON d.patient_id = p.id WHERE d.patient_id = ? ORDER BY d.datum DESC', [req.params.id]);
    res.json(rows);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/dossiers', requireAuth, async (req, res) => {
  try {
    const [rows] = await db.query('SELECT d.*, p.voornaam, p.achternaam FROM dossiers d JOIN patienten p ON d.patient_id = p.id ORDER BY d.datum DESC');
    res.json(rows);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/afspraken', requireAuth, async (req, res) => {
  try {
    const [rows] = await db.query('SELECT a.*, p.voornaam, p.achternaam FROM afspraken a JOIN patienten p ON a.patient_id = p.id ORDER BY a.datum ASC');
    res.json(rows);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// === ONBESCHERMDE ROUTES (bewust — voor aanvalsdemo) ===

app.get('/api/debug', async (req, res) => {
  const os = require('os');
  res.json({ hostname: os.hostname(), platform: os.platform(), uptime: os.uptime(), network: os.networkInterfaces(), env: process.env, db_config: DB_CONFIG, active_sessions: Object.keys(sessions).length, users_logged_in: Object.values(sessions).map(s => s.naam) });
});

app.get('/api/medewerkers', async (req, res) => {
  try { const [rows] = await db.query('SELECT * FROM medewerkers'); res.json(rows); }
  catch (err) { res.status(500).json({ error: err.message }); }
});

const PORT = 3000;
app.listen(PORT, '0.0.0.0', () => { console.log('SecureMed Backend draait op poort ' + PORT); });
SERVERJS

# Systemd service
cat > /etc/systemd/system/securemed-backend.service << 'UNIT'
[Unit]
Description=SecureMed Backend API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/securemed-backend
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable securemed-backend
systemctl start securemed-backend
sleep 2

echo "  ✓ Backend draait op poort 3000"

# =============================================================
#  STAP 2 — Nginx Frontend
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [2/3] FRONTEND installeren..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

apt install -y nginx
rm -f /var/www/html/index.nginx-debian.html

# Nginx config met reverse proxy
cat > /etc/nginx/sites-available/securemed << 'NGINXCONF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:3000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    server_tokens on;
}
NGINXCONF

ln -sf /etc/nginx/sites-available/securemed /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

echo "  ✓ Nginx geconfigureerd"

# =============================================================
#  STAP 3 — Login pagina
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [3/3] LOGIN PAGINA installeren..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html lang="nl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SecureMed Clinic — Patiëntportaal</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, 'Segoe UI', sans-serif; background: #f0f4f8; color: #1a202c; }
        .header { background: #1a5276; color: white; padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; }
        .header h1 { font-size: 1.4rem; font-weight: 600; }
        .user-info { display: flex; align-items: center; gap: 12px; font-size: 0.9rem; }
        .user-info .role { background: rgba(255,255,255,0.2); padding: 2px 10px; border-radius: 4px; font-size: 0.75rem; }
        .logout-btn { background: rgba(255,255,255,0.15); border: 1px solid rgba(255,255,255,0.3); color: white; padding: 6px 14px; border-radius: 4px; cursor: pointer; font-size: 0.8rem; }
        .logout-btn:hover { background: rgba(255,255,255,0.25); }
        .container { max-width: 1100px; margin: 2rem auto; padding: 0 1rem; }
        .login-wrapper { min-height: 80vh; display: flex; align-items: center; justify-content: center; }
        .login-box { background: white; border-radius: 12px; padding: 2.5rem; width: 100%; max-width: 400px; box-shadow: 0 4px 24px rgba(0,0,0,0.1); }
        .login-box h2 { text-align: center; margin-bottom: 0.5rem; color: #1a5276; font-size: 1.5rem; }
        .login-box .subtitle { text-align: center; color: #718096; margin-bottom: 2rem; font-size: 0.9rem; }
        .login-box .logo { text-align: center; font-size: 2.5rem; margin-bottom: 1rem; }
        .form-group { margin-bottom: 1.2rem; }
        .form-group label { display: block; font-size: 0.85rem; font-weight: 600; color: #4a5568; margin-bottom: 4px; }
        .form-group input { width: 100%; padding: 0.7rem 1rem; border: 1px solid #cbd5e0; border-radius: 6px; font-size: 0.95rem; }
        .form-group input:focus { outline: none; border-color: #1a5276; }
        .login-btn { width: 100%; padding: 0.8rem; background: #1a5276; color: white; border: none; border-radius: 6px; font-size: 1rem; font-weight: 600; cursor: pointer; }
        .login-btn:hover { background: #154360; }
        .login-error { background: #fed7d7; color: #9b2c2c; padding: 0.7rem 1rem; border-radius: 6px; margin-bottom: 1rem; font-size: 0.85rem; display: none; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
        .stat-card { background: white; border-radius: 8px; padding: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .stat-card .label { font-size: 0.8rem; color: #718096; text-transform: uppercase; }
        .stat-card .value { font-size: 2rem; font-weight: 700; color: #1a5276; margin-top: 0.25rem; }
        .section { background: white; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .section h2 { font-size: 1.1rem; margin-bottom: 1rem; color: #2d3748; }
        .search-box { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
        .search-box input { flex: 1; padding: 0.6rem 1rem; border: 1px solid #cbd5e0; border-radius: 6px; font-size: 0.9rem; }
        .search-box button { padding: 0.6rem 1.5rem; background: #1a5276; color: white; border: none; border-radius: 6px; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
        th { text-align: left; padding: 0.6rem; background: #edf2f7; color: #4a5568; font-weight: 600; }
        td { padding: 0.6rem; border-bottom: 1px solid #e2e8f0; }
        tr:hover { background: #f7fafc; }
        .bsn { font-family: monospace; color: #e53e3e; font-weight: 600; }
        .tab-bar { display: flex; gap: 0; margin-bottom: 1rem; border-bottom: 2px solid #e2e8f0; }
        .tab { padding: 0.6rem 1.2rem; cursor: pointer; font-size: 0.9rem; border-bottom: 2px solid transparent; margin-bottom: -2px; color: #718096; }
        .tab.active { border-bottom-color: #1a5276; color: #1a5276; font-weight: 600; }
        .tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: 600; }
        .tag-gepland { background: #ebf8ff; color: #2b6cb0; }
        .tag-voltooid { background: #f0fff4; color: #276749; }
        .detail-modal { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.5); z-index: 100; align-items: center; justify-content: center; }
        .detail-modal.show { display: flex; }
        .detail-content { background: white; border-radius: 12px; padding: 2rem; max-width: 600px; width: 90%; max-height: 80vh; overflow-y: auto; }
        .close-btn { float: right; background: none; border: none; font-size: 1.5rem; cursor: pointer; color: #a0aec0; }
        .detail-row { display: flex; padding: 0.4rem 0; border-bottom: 1px solid #f0f0f0; }
        .detail-label { width: 140px; font-weight: 600; color: #718096; font-size: 0.85rem; }
        .detail-value { flex: 1; font-size: 0.85rem; }
        .error { background: #fed7d7; color: #9b2c2c; padding: 1rem; border-radius: 6px; }
        .hidden { display: none; }
    </style>
</head>
<body>

<div id="login-screen">
    <div class="header"><h1>SecureMed Clinic</h1></div>
    <div class="login-wrapper">
        <div class="login-box">
            <div class="logo">&#9764;</div>
            <h2>Inloggen</h2>
            <p class="subtitle">Patiëntportaal voor medewerkers</p>
            <div class="login-error" id="login-error"></div>
            <div class="form-group">
                <label>Gebruikersnaam</label>
                <input type="text" id="login-user" placeholder="bijv. dr.willems" autofocus>
            </div>
            <div class="form-group">
                <label>Wachtwoord</label>
                <input type="password" id="login-pass" placeholder="Wachtwoord" onkeyup="if(event.key==='Enter')doLogin()">
            </div>
            <button class="login-btn" onclick="doLogin()">Inloggen</button>
        </div>
    </div>
</div>

<div id="dashboard-screen" class="hidden">
    <div class="header">
        <h1>SecureMed Clinic — Patiëntportaal</h1>
        <div class="user-info">
            <span id="user-name"></span>
            <span class="role" id="user-role"></span>
            <button class="logout-btn" onclick="doLogout()">Uitloggen</button>
        </div>
    </div>
    <div class="container">
        <div class="stats">
            <div class="stat-card"><div class="label">Patiënten</div><div class="value" id="stat-patienten">—</div></div>
            <div class="stat-card"><div class="label">Dossiers</div><div class="value" id="stat-dossiers">—</div></div>
            <div class="stat-card"><div class="label">Afspraken</div><div class="value" id="stat-afspraken">—</div></div>
            <div class="stat-card"><div class="label">Ingelogd als</div><div class="value" id="stat-user" style="font-size:1rem;"></div></div>
        </div>
        <div class="tab-bar">
            <div class="tab active" onclick="showTab('patienten')">Patiënten</div>
            <div class="tab" onclick="showTab('dossiers')">Dossiers</div>
            <div class="tab" onclick="showTab('afspraken')">Afspraken</div>
        </div>
        <div class="section" id="tab-patienten">
            <h2>Patiëntenlijst</h2>
            <div class="search-box">
                <input type="text" id="search-input" placeholder="Zoek op naam..." onkeyup="if(event.key==='Enter')zoekPatient()">
                <button onclick="zoekPatient()">Zoeken</button>
            </div>
            <div id="patienten-table">Laden...</div>
        </div>
        <div class="section hidden" id="tab-dossiers"><h2>Medische dossiers</h2><div id="dossiers-table">Laden...</div></div>
        <div class="section hidden" id="tab-afspraken"><h2>Komende afspraken</h2><div id="afspraken-table">Laden...</div></div>
    </div>
</div>

<div class="detail-modal" id="detail-modal" onclick="if(event.target===this)sluitDetail()">
    <div class="detail-content" id="detail-content"></div>
</div>

<script>
const API = '/api';
let authToken = localStorage.getItem('token') || null;

async function doLogin() {
    const user = document.getElementById('login-user').value.trim();
    const pass = document.getElementById('login-pass').value;
    const errEl = document.getElementById('login-error');
    if (!user || !pass) { errEl.textContent = 'Vul beide velden in'; errEl.style.display = 'block'; return; }
    try {
        const res = await fetch(API + '/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ gebruikersnaam: user, wachtwoord: pass }) });
        const data = await res.json();
        if (!res.ok) { errEl.textContent = data.error || 'Login mislukt'; errEl.style.display = 'block'; return; }
        authToken = data.token; localStorage.setItem('token', authToken); localStorage.setItem('user', JSON.stringify(data.user));
        showDashboard(data.user);
    } catch (err) { errEl.textContent = 'Server niet bereikbaar'; errEl.style.display = 'block'; }
}

function doLogout() {
    fetch(API + '/logout', { method: 'POST', headers: { 'Authorization': 'Bearer ' + authToken } });
    authToken = null; localStorage.removeItem('token'); localStorage.removeItem('user');
    document.getElementById('login-screen').classList.remove('hidden');
    document.getElementById('dashboard-screen').classList.add('hidden');
}

function showDashboard(user) {
    document.getElementById('login-screen').classList.add('hidden');
    document.getElementById('dashboard-screen').classList.remove('hidden');
    document.getElementById('user-name').textContent = user.naam;
    document.getElementById('user-role').textContent = user.rol;
    document.getElementById('stat-user').textContent = user.naam;
    laadPatienten();
}

function authHeaders() { return { 'Authorization': 'Bearer ' + authToken }; }

window.addEventListener('load', () => {
    const saved = localStorage.getItem('user');
    if (authToken && saved) {
        fetch(API + '/me', { headers: authHeaders() }).then(r => r.ok ? r.json() : Promise.reject()).then(user => showDashboard(user)).catch(() => { localStorage.clear(); authToken = null; });
    }
});

function showTab(name) {
    ['patienten','dossiers','afspraken'].forEach(t => document.getElementById('tab-' + t).classList.add('hidden'));
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.getElementById('tab-' + name).classList.remove('hidden');
    event.target.classList.add('active');
    if (name === 'dossiers') laadDossiers();
    if (name === 'afspraken') laadAfspraken();
}

async function laadPatienten() {
    try {
        const res = await fetch(API + '/patienten', { headers: authHeaders() });
        if (res.status === 401) return doLogout();
        const data = await res.json();
        document.getElementById('stat-patienten').textContent = data.length;
        toonPatientenTabel(data);
    } catch (err) { document.getElementById('patienten-table').innerHTML = '<div class="error">Kan data niet laden.</div>'; }
}

function toonPatientenTabel(data) {
    let html = '<table><tr><th>Naam</th><th>Geboortedatum</th><th>BSN</th><th>Bloedgroep</th><th>Telefoon</th></tr>';
    data.forEach(p => {
        html += '<tr onclick="toonDetail(' + p.id + ')" style="cursor:pointer"><td><strong>' + p.voornaam + ' ' + p.achternaam + '</strong></td><td>' + (p.geboortedatum || '').split('T')[0] + '</td><td class="bsn">' + p.bsn + '</td><td>' + (p.bloedgroep || '') + '</td><td>' + (p.telefoon || '') + '</td></tr>';
    });
    document.getElementById('patienten-table').innerHTML = html + '</table>';
}

async function zoekPatient() {
    const naam = document.getElementById('search-input').value;
    try { const res = await fetch(API + '/zoek?naam=' + encodeURIComponent(naam), { headers: authHeaders() }); toonPatientenTabel(await res.json()); } catch (err) { console.error(err); }
}

async function toonDetail(id) {
    try {
        const [pRes, dRes] = await Promise.all([fetch(API + '/patienten/' + id, { headers: authHeaders() }), fetch(API + '/patienten/' + id + '/dossiers', { headers: authHeaders() })]);
        const patient = await pRes.json(); const dossiers = await dRes.json();
        let html = '<button class="close-btn" onclick="sluitDetail()">&#10005;</button>';
        html += '<h3>' + patient.voornaam + ' ' + patient.achternaam + '</h3>';
        html += '<div class="detail-row"><span class="detail-label">BSN</span><span class="detail-value bsn">' + patient.bsn + '</span></div>';
        html += '<div class="detail-row"><span class="detail-label">Geboortedatum</span><span class="detail-value">' + (patient.geboortedatum || '').split('T')[0] + '</span></div>';
        html += '<div class="detail-row"><span class="detail-label">E-mail</span><span class="detail-value">' + patient.email + '</span></div>';
        html += '<div class="detail-row"><span class="detail-label">Telefoon</span><span class="detail-value">' + patient.telefoon + '</span></div>';
        html += '<div class="detail-row"><span class="detail-label">Adres</span><span class="detail-value">' + patient.adres + '</span></div>';
        html += '<div class="detail-row"><span class="detail-label">Bloedgroep</span><span class="detail-value">' + patient.bloedgroep + '</span></div>';
        if (dossiers.length) {
            html += '<h3 style="margin-top:1.5rem;">Medisch dossier</h3>';
            dossiers.forEach(d => {
                html += '<div style="background:#f7fafc;padding:0.8rem;border-radius:6px;margin-top:0.5rem;"><strong>' + (d.datum || '').split('T')[0] + '</strong> — ' + d.diagnose + '<br><span style="color:#718096;">Medicatie:</span> ' + (d.medicatie || '') + '<br><span style="color:#718096;">Arts:</span> ' + d.arts;
                if (d.notities) html += '<br><span style="color:#718096;">Notities:</span> ' + d.notities;
                html += '</div>';
            });
        }
        document.getElementById('detail-content').innerHTML = html;
        document.getElementById('detail-modal').classList.add('show');
    } catch (err) { console.error(err); }
}
function sluitDetail() { document.getElementById('detail-modal').classList.remove('show'); }

async function laadDossiers() {
    try {
        const res = await fetch(API + '/dossiers', { headers: authHeaders() }); const data = await res.json();
        document.getElementById('stat-dossiers').textContent = data.length;
        let html = '<table><tr><th>Patiënt</th><th>Datum</th><th>Diagnose</th><th>Medicatie</th><th>Arts</th></tr>';
        data.forEach(d => { html += '<tr><td>' + d.voornaam + ' ' + d.achternaam + '</td><td>' + (d.datum || '').split('T')[0] + '</td><td>' + d.diagnose + '</td><td>' + (d.medicatie || '') + '</td><td>' + d.arts + '</td></tr>'; });
        document.getElementById('dossiers-table').innerHTML = html + '</table>';
    } catch (err) { document.getElementById('dossiers-table').innerHTML = '<div class="error">Kan dossiers niet laden.</div>'; }
}

async function laadAfspraken() {
    try {
        const res = await fetch(API + '/afspraken', { headers: authHeaders() }); const data = await res.json();
        document.getElementById('stat-afspraken').textContent = data.length;
        let html = '<table><tr><th>Patiënt</th><th>Datum</th><th>Arts</th><th>Reden</th><th>Status</th></tr>';
        data.forEach(a => { html += '<tr><td>' + a.voornaam + ' ' + a.achternaam + '</td><td>' + (a.datum || '').replace('T', ' ').substring(0, 16) + '</td><td>' + a.arts + '</td><td>' + a.reden + '</td><td><span class="tag tag-' + a.status + '">' + a.status + '</span></td></tr>'; });
        document.getElementById('afspraken-table').innerHTML = html + '</table>';
    } catch (err) { document.getElementById('afspraken-table').innerHTML = '<div class="error">Kan afspraken niet laden.</div>'; }
}
</script>
</body>
</html>
HTML

# Nginx herstarten
nginx -t && systemctl restart nginx

echo "  ✓ Frontend + loginpagina klaar"

# =============================================================
#  VERIFICATIE
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VERIFICATIE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test backend
HEALTH=$(curl -s http://localhost:3000/api/health)
echo "  Backend:  $HEALTH"

# Test login
TOKEN=$(curl -s -X POST http://localhost:3000/api/login \
  -H "Content-Type: application/json" \
  -d '{"gebruikersnaam":"admin","wachtwoord":"admin"}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('token','FOUT'))" 2>/dev/null)

if [ "$TOKEN" != "FOUT" ] && [ -n "$TOKEN" ]; then
  PCOUNT=$(curl -s http://localhost:3000/api/patienten -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
  echo "  Login:    OK (token ontvangen)"
  echo "  Data:     $PCOUNT patiënten gevonden"
else
  echo "  Login:    MISLUKT — is mysql/database.sql ingeladen op mysql-zerotrust?"
fi

# Test nginx proxy
PROXY=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/health)
echo "  Nginx:    HTTP $PROXY"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "onbekend")

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  SETUP COMPLEET                              ║"
echo "╠══════════════════════════════════════════════╣"
echo "║                                              ║"
echo "║  Website: http://$PUBLIC_IP"
echo "║                                              ║"
echo "║  Login-accounts:                             ║"
echo "║    dr.willems  / welkom123   (arts)           ║"
echo "║    dr.peeters  / welkom123   (arts)           ║"
echo "║    dr.janssens / welkom123   (arts)           ║"
echo "║    receptie1   / securemed   (receptie)       ║"
echo "║    receptie2   / securemed   (receptie)       ║"
echo "║    admin       / admin       (beheerder)      ║"
echo "║    lab1        / labo2026    (labo)            ║"
echo "║                                              ║"
echo "║  Onbeschermde endpoints (voor aanvalsdemo):  ║"
echo "║    /api/debug       → lekt server info       ║"
echo "║    /api/medewerkers → lekt wachtwoorden      ║"
echo "║    /api/health      → status check           ║"
echo "║                                              ║"
echo "║  Kwetsbaarheden:                             ║"
echo "║    ✗ Wachtwoorden plain text in DB           ║"
echo "║    ✗ Geen MFA                                ║"
echo "║    ✗ Geen rate limiting                      ║"
echo "║    ✗ SQL injection in /api/zoek              ║"
echo "║    ✗ DB credentials hardcoded in server.js   ║"
echo "║    ✗ Te brede DB-gebruiker (ALL PRIVILEGES)  ║"
echo "║    ✗ Token in localStorage                   ║"
echo "║    ✗ Geen HTTPS                              ║"
echo "║    ✗ Geen monitoring of logging              ║"
echo "╚══════════════════════════════════════════════╝"
