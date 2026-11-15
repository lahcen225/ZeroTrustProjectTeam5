#!/bin/bash
# ============================================================
# SecureMed Clinic — VEILIGE SETUP vm-app (Zero Trust "na"-versie)
# ============================================================
# Vervangt de kwetsbare app van setup-alles.sh door:
#   - aanmelden via Entra ID (OpenID Connect, tenant van de docent)
#   - rollen uit de "roles"-claim (Arts, Verpleging, Administratie, Management)
#   - secrets uit Key Vault via de managed identity van de VM (geen .env)
#   - least-privilege DB-gebruiker, geparametriseerde queries, geen debug-routes
#   - audit-log (JSON) voor Wazuh: /var/log/securemed/audit.log
#
# Vooraf nodig (zie README):
#   1. DNS-naam op pip-appgw  -> BASE_URL hieronder
#   2. Redirect URI <BASE_URL>/auth/callback in entra/terraform.tfvars + apply
#   3. azure/: apply met TF_VAR_entra_client_secret (secret + KV-rol voor vm-app)
#   4. Na dit script, eenmalig op vm-app: sudo securemed-db-gebruiker
#
# Gebruik:
#   az vm run-command invoke -g rg-zerotrust -n vm-app \
#     --command-id RunShellScript --scripts @setup-veilig.sh
# ============================================================

set -e
export DEBIAN_FRONTEND=noninteractive

# --- Configuratie (niet geheim) -------------------------------
TENANT_ID="c0abb0b5-4c84-4c3b-ad0c-bbc75a468bca"   # tenant van de docent
CLIENT_ID="5205e0d4-a3d3-4c69-b926-cce28f8b1af9"   # app "SecureMed Patientportaal"
BASE_URL="https://securemed-zt2.swedencentral.cloudapp.azure.com"   # = terraform output website (infra/)
KEY_VAULT_URI="https://kv-securemed2-12300882.vault.azure.net/"   # = terraform output key_vault_uri (infra/)
IDENTITY_CLIENT_ID=""                               # leeg = system-assigned identity van de VM
DB_HOST="mysql-zerotrust2.mysql.database.azure.com"
DB_USER="securemed_web"
DB_CLIENT_HOST="10.0.1.%"                           # snet-app
APPGW_SUBNET="10.0.0.64/26"                         # snet-appgw (vertrouwde proxy)
# Lokaccounts: het decoy-account uit Entra + de gelekte accounts van setup-alles.sh.
# Wie die gebruikt in het (nep)wachtwoordformulier, is per definitie een aanvaller.
HONEYTOKEN_USERS="svc-backup-admin,svc-backup-admin@n6mv.onmicrosoft.com,admin,dr.willems,dr.peeters,dr.janssens,receptie1,receptie2,lab1"

APP_DIR=/opt/securemed
WEB_DIR=/var/www/securemed
LOG_DIR=/var/log/securemed

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  SecureMed Clinic — Veilige Setup            ║"
echo "║  Entra ID → Key Vault → least privilege      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# =============================================================
#  STAP 1 — Voorbereiding
# =============================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [1/4] VOORBEREIDING..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Kwetsbare versie uitzetten (bestanden blijven staan voor de demo)
systemctl disable --now securemed-backend 2>/dev/null || true

# Node.js 20 (alleen als die er nog niet is)
if ! node -v 2>/dev/null | grep -q '^v20'; then
  apt remove -y nodejs libnode-dev libnode72 npm || true
  dpkg --configure -a
  apt -f install -y
  apt update -qq
  apt install -y ca-certificates curl gnupg
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt update -qq
  apt install -y nodejs
fi
apt install -y nginx mysql-client python3

# Eigen systeemgebruiker zonder shell: de app draait nooit als root
id securemed >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin securemed

mkdir -p "$APP_DIR" "$WEB_DIR" /etc/securemed "$LOG_DIR"
chown securemed:securemed "$LOG_DIR"
chmod 750 "$LOG_DIR"

cat > /etc/securemed/backend.env << ENV
TENANT_ID=$TENANT_ID
CLIENT_ID=$CLIENT_ID
BASE_URL=$BASE_URL
KEY_VAULT_URI=$KEY_VAULT_URI
IDENTITY_CLIENT_ID=$IDENTITY_CLIENT_ID
DB_HOST=$DB_HOST
DB_USER=$DB_USER
DB_CLIENT_HOST=$DB_CLIENT_HOST
APPGW_SUBNET=$APPGW_SUBNET
HONEYTOKEN_USERS=$HONEYTOKEN_USERS
AUDIT_LOG=$LOG_DIR/audit.log
ENV
chmod 644 /etc/securemed/backend.env

# Wazuh-agent (geïnstalleerd door Terraform) laat het audit-log inlezen;
# de regels 100200-100202 staan op de Wazuh-server (infra/modules/wazuh)
touch "$LOG_DIR/audit.log" && chown securemed:securemed "$LOG_DIR/audit.log"
if [ -f /var/ossec/etc/ossec.conf ] && ! grep -q "$LOG_DIR/audit.log" /var/ossec/etc/ossec.conf; then
  cat >> /var/ossec/etc/ossec.conf << WAZUH

<ossec_config>
  <localfile>
    <log_format>json</log_format>
    <location>$LOG_DIR/audit.log</location>
  </localfile>
</ossec_config>
WAZUH
  systemctl restart wazuh-agent || true
fi

echo "  ✓ Gebruiker securemed, mappen en configuratie klaar"

# =============================================================
#  STAP 2 — Backend
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [2/4] BACKEND installeren..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$APP_DIR"

cat > package.json << 'PKGJSON'
{
  "name": "securemed-backend-veilig",
  "version": "2.0.0",
  "private": true,
  "dependencies": {
    "@azure/identity": "^4.5.0",
    "@azure/keyvault-secrets": "^4.9.0",
    "@azure/msal-node": "^2.16.2",
    "express": "^4.21.2",
    "express-session": "^1.18.1",
    "mysql2": "^3.11.5"
  }
}
PKGJSON

npm install --omit=dev --no-audit --no-fund 2>&1 | tail -1

cat > server.js << 'SERVERJS'
'use strict';
const crypto  = require('crypto');
const fs      = require('fs');
const express = require('express');
const session = require('express-session');
const msal    = require('@azure/msal-node');
const mysql   = require('mysql2/promise');
const { ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');

const cfg = {
  tenantId:    process.env.TENANT_ID,
  clientId:    process.env.CLIENT_ID,
  baseUrl:     process.env.BASE_URL,
  keyVaultUri: process.env.KEY_VAULT_URI,
  identityId:  process.env.IDENTITY_CLIENT_ID || null,
  dbHost:      process.env.DB_HOST,
  dbUser:      process.env.DB_USER,
  appgwSubnet: process.env.APPGW_SUBNET,
  auditLog:    process.env.AUDIT_LOG,
  honeytokens: (process.env.HONEYTOKEN_USERS || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean),
};
const REDIRECT_URI = cfg.baseUrl + '/auth/callback';
const SESSIE_MS    = 8 * 60 * 60 * 1000; // gelijk aan CA05: max 8 uur

// Rollen = "value" van de app roles in entra/app.tf
const ARTS = 'Arts', VERPLEGING = 'Verpleging', ADMINISTRATIE = 'Administratie', MANAGEMENT = 'Management';
const ZORG    = [ARTS, VERPLEGING];
const PATIENT = [ARTS, VERPLEGING, ADMINISTRATIE];

// Administratie ziet geen medische velden (bloedgroep)
const KOLOMMEN_ZORG  = 'id, voornaam, achternaam, geboortedatum, bsn, email, telefoon, adres, bloedgroep';
const KOLOMMEN_ADMIN = 'id, voornaam, achternaam, geboortedatum, bsn, email, telefoon, adres';

// --- Audit-log: één JSON-regel per gebeurtenis (Wazuh leest dit bestand) ---
function audit(event, req, extra = {}) {
  const regel = JSON.stringify({
    tijd: new Date().toISOString(), app: 'securemed', event,
    gebruiker: req.session?.user?.upn ?? null, ip: req.ip, pad: req.originalUrl, ...extra,
  });
  fs.appendFile(cfg.auditLog, regel + '\n', err => { if (err) console.error('[audit]', err.message); });
}

const heeftRol = (user, rollen) => rollen.some(r => user.rollen.includes(r));

function vereisRol(...toegestaan) {
  return (req, res, next) => {
    const user = req.session.user;
    if (!user) return res.status(401).json({ error: 'Niet aangemeld' });
    if (heeftRol(user, toegestaan)) return next();
    audit('toegang_geweigerd', req, { rollen: user.rollen, vereist: toegestaan });
    res.status(403).json({ error: 'Geen toegang met jouw rol' });
  };
}

function patientId(req, res) {
  const id = Number.parseInt(req.params.id, 10);
  if (!Number.isInteger(id) || id < 1) { res.status(400).json({ error: 'Ongeldig id' }); return null; }
  return id;
}

function tekst(waarde, max) {
  if (waarde == null || waarde === '') return null;
  if (typeof waarde !== 'string' || waarde.length > max) throw Object.assign(new Error('Ongeldige invoer'), { status: 400 });
  return waarde.trim();
}

function foutPagina(titel, uitleg) {
  return `<!DOCTYPE html><html lang="nl"><head><meta charset="UTF-8"><title>SecureMed</title>
<link rel="stylesheet" href="/app.css"></head><body><div class="header"><h1>SecureMed Clinic</h1></div>
<div class="login-wrapper"><div class="login-box"><h2>${titel}</h2><p class="subtitle">${uitleg}</p>
<a class="login-btn" href="/">Terug</a></div></div></body></html>`;
}

async function start() {
  // 1. Secrets uit Key Vault met de managed identity: niets geheims op schijf
  const cred = cfg.identityId ? new ManagedIdentityCredential(cfg.identityId) : new ManagedIdentityCredential();
  const kv = new SecretClient(cfg.keyVaultUri, cred);
  const [clientSecret, dbWachtwoord] = await Promise.all([
    kv.getSecret('entra-client-secret'),
    kv.getSecret('db-app-wachtwoord'),
  ]).then(s => s.map(x => x.value));

  // 2. Database: eigen least-privilege gebruiker, altijd TLS
  const db = mysql.createPool({
    host: cfg.dbHost, user: cfg.dbUser, password: dbWachtwoord, database: 'securemed',
    ssl: { rejectUnauthorized: true }, connectionLimit: 5, dateStrings: true,
  });
  await db.query('SELECT 1');

  // 3. Entra ID (OpenID Connect, authorization code flow + PKCE)
  const cca = new msal.ConfidentialClientApplication({
    auth: { clientId: cfg.clientId, authority: `https://login.microsoftonline.com/${cfg.tenantId}`, clientSecret },
  });
  const pkce = new msal.CryptoProvider();

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', ['loopback', cfg.appgwSubnet]); // NGINX + Application Gateway
  app.use(express.json({ limit: '16kb' }));
  app.use(session({
    name: 'securemed.sid',
    secret: crypto.randomBytes(32).toString('hex'),
    resave: false,
    saveUninitialized: false,
    cookie: { httpOnly: true, secure: true, sameSite: 'lax', maxAge: SESSIE_MS },
  }));

  // --- Aanmelden ---------------------------------------------------------
  app.get('/auth/login', async (req, res, next) => {
    try {
      const { verifier, challenge } = await pkce.generatePkceCodes();
      const state = pkce.createNewGuid();
      req.session.aanmelding = { verifier, state };
      const url = await cca.getAuthCodeUrl({
        scopes: ['openid', 'profile'], redirectUri: REDIRECT_URI, responseMode: msal.ResponseMode.QUERY,
        codeChallenge: challenge, codeChallengeMethod: 'S256', state, prompt: 'select_account',
      });
      res.redirect(url);
    } catch (err) { next(err); }
  });

  app.get('/auth/callback', async (req, res, next) => {
    const aanmelding = req.session.aanmelding;
    delete req.session.aanmelding;

    if (req.query.error) {
      // Bv. AADSTS50105: gebruiker zonder app role (decoy-account, beheeraccounts)
      audit('login_geweigerd', req, { fout: String(req.query.error), uitleg: String(req.query.error_description || '').slice(0, 200) });
      return res.status(403).send(foutPagina('Geen toegang', 'Je account heeft geen toegang tot het patiëntportaal.'));
    }
    if (!aanmelding || req.query.state !== aanmelding.state) {
      audit('login_ongeldige_state', req);
      return res.status(400).send(foutPagina('Aanmelden mislukt', 'Ongeldige of verlopen aanmeldpoging. Probeer opnieuw.'));
    }

    try {
      const result = await cca.acquireTokenByCode({
        code: String(req.query.code), scopes: ['openid', 'profile'],
        redirectUri: REDIRECT_URI, codeVerifier: aanmelding.verifier,
      });
      const c = result.idTokenClaims;
      if (c.tid !== cfg.tenantId) throw new Error('Onverwachte tenant');
      const user = { naam: c.name, upn: c.preferred_username, oid: c.oid, rollen: Array.isArray(c.roles) ? c.roles : [] };

      if (!user.rollen.length) {
        audit('login_zonder_rol', req, { upn: user.upn });
        return res.status(403).send(foutPagina('Geen toegang', 'Je account heeft geen rol in het patiëntportaal.'));
      }

      // Nieuwe sessie-ID na aanmelden (tegen session fixation)
      req.session.regenerate(err => {
        if (err) return next(err);
        req.session.user = user;
        audit('login_ok', req, { rollen: user.rollen });
        res.redirect('/');
      });
    } catch (err) {
      audit('login_fout', req, { fout: err.errorCode || err.message });
      res.status(401).send(foutPagina('Aanmelden mislukt', 'Probeer opnieuw.'));
    }
  });

  // Lokformulier (deception): meldt NOOIT iemand aan, want wachtwoorden worden
  // alleen door Entra gecontroleerd. Elke poging wordt gelogd; met een honeytoken
  // (decoy-account of gelekt account) met ernst "hoog" voor Wazuh.
  // Het wachtwoord zelf wordt nooit gelogd of opgeslagen, alleen de lengte.
  app.post('/auth/wachtwoord', async (req, res) => {
    const poging = typeof req.body?.gebruikersnaam === 'string' ? req.body.gebruikersnaam.trim().slice(0, 100) : '';
    const honeytoken = cfg.honeytokens.includes(poging.toLowerCase());
    audit(honeytoken ? 'honeytoken_gebruikt' : 'honeypot_login_poging', req, {
      ernst: honeytoken ? 'hoog' : 'middel',
      poging_gebruiker: poging,
      wachtwoord_lengte: typeof req.body?.wachtwoord === 'string' ? req.body.wachtwoord.length : 0,
      user_agent: String(req.get('user-agent') || '').slice(0, 200),
    });
    // Even wachten zoals een echte wachtwoordcontrole
    await new Promise(r => setTimeout(r, 600 + crypto.randomInt(600)));
    res.status(401).json({ error: 'Ongeldige gebruikersnaam of wachtwoord' });
  });

  app.get('/auth/logout', (req, res) => {
    audit('logout', req);
    req.session.destroy(() => {
      res.clearCookie('securemed.sid');
      res.redirect(`https://login.microsoftonline.com/${cfg.tenantId}/oauth2/v2.0/logout?post_logout_redirect_uri=${encodeURIComponent(cfg.baseUrl + '/')}`);
    });
  });

  // --- API -------------------------------------------------------------
  app.get('/api/health', (req, res) => res.json({ status: 'ok' }));

  app.get('/api/me', (req, res) => {
    const u = req.session.user;
    if (!u) return res.status(401).json({ error: 'Niet aangemeld' });
    res.json({ naam: u.naam, upn: u.upn, rollen: u.rollen });
  });

  app.get('/api/patienten', vereisRol(...PATIENT), async (req, res, next) => {
    try {
      const kolommen = heeftRol(req.session.user, ZORG) ? KOLOMMEN_ZORG : KOLOMMEN_ADMIN;
      const [rows] = await db.query(`SELECT ${kolommen} FROM patienten ORDER BY achternaam`);
      res.json(rows);
    } catch (err) { next(err); }
  });

  // Geparametriseerd: geen SQL-injectie meer (vergelijk /api/zoek in setup-alles.sh)
  app.get('/api/zoek', vereisRol(...PATIENT), async (req, res, next) => {
    try {
      const naam = tekst(req.query.naam ?? '', 50) ?? '';
      const patroon = '%' + naam.replace(/[\\%_]/g, '\\$&') + '%';
      const kolommen = heeftRol(req.session.user, ZORG) ? KOLOMMEN_ZORG : KOLOMMEN_ADMIN;
      const [rows] = await db.query(
        `SELECT ${kolommen} FROM patienten WHERE voornaam LIKE ? OR achternaam LIKE ? ORDER BY achternaam`,
        [patroon, patroon]);
      res.json(rows);
    } catch (err) { next(err); }
  });

  app.get('/api/patienten/:id', vereisRol(...PATIENT), async (req, res, next) => {
    const id = patientId(req, res); if (!id) return;
    try {
      const kolommen = heeftRol(req.session.user, ZORG) ? KOLOMMEN_ZORG : KOLOMMEN_ADMIN;
      const [rows] = await db.query(`SELECT ${kolommen} FROM patienten WHERE id = ?`, [id]);
      if (!rows.length) return res.status(404).json({ error: 'Niet gevonden' });
      res.json(rows[0]);
    } catch (err) { next(err); }
  });

  app.get('/api/patienten/:id/dossiers', vereisRol(...ZORG), async (req, res, next) => {
    const id = patientId(req, res); if (!id) return;
    try {
      const [rows] = await db.query(
        'SELECT id, datum, diagnose, medicatie, arts, notities FROM dossiers WHERE patient_id = ? ORDER BY datum DESC', [id]);
      audit('dossier_gelezen', req, { patient_id: id });
      res.json(rows);
    } catch (err) { next(err); }
  });

  app.get('/api/dossiers', vereisRol(...ZORG), async (req, res, next) => {
    try {
      const [rows] = await db.query(
        `SELECT d.id, d.datum, d.diagnose, d.medicatie, d.arts, p.voornaam, p.achternaam
           FROM dossiers d JOIN patienten p ON d.patient_id = p.id ORDER BY d.datum DESC`);
      audit('dossiers_overzicht', req);
      res.json(rows);
    } catch (err) { next(err); }
  });

  // Alleen artsen schrijven in dossiers. Vereist JSON: een gewoon HTML-formulier
  // van een andere site kan dat niet sturen (samen met SameSite-cookie tegen CSRF).
  app.post('/api/dossiers', vereisRol(ARTS), async (req, res, next) => {
    if (!req.is('application/json')) return res.status(415).json({ error: 'JSON verwacht' });
    try {
      const pid = Number.parseInt(req.body.patient_id, 10);
      const diagnose = tekst(req.body.diagnose, 255);
      if (!Number.isInteger(pid) || pid < 1 || !diagnose) return res.status(400).json({ error: 'Patiënt en diagnose zijn verplicht' });
      const [r] = await db.query(
        'INSERT INTO dossiers (patient_id, datum, diagnose, medicatie, arts, notities) VALUES (?, CURDATE(), ?, ?, ?, ?)',
        [pid, diagnose, tekst(req.body.medicatie, 255), req.session.user.naam, tekst(req.body.notities, 2000)]);
      audit('dossier_toegevoegd', req, { patient_id: pid, dossier_id: r.insertId });
      res.status(201).json({ id: r.insertId });
    } catch (err) { next(err); }
  });

  app.get('/api/afspraken', vereisRol(...PATIENT), async (req, res, next) => {
    try {
      const [rows] = await db.query(
        `SELECT a.id, a.datum, a.arts, a.reden, a.status, p.voornaam, p.achternaam
           FROM afspraken a JOIN patienten p ON a.patient_id = p.id ORDER BY a.datum ASC`);
      res.json(rows);
    } catch (err) { next(err); }
  });

  // Management: alleen geaggregeerde cijfers, geen patiëntgegevens
  app.get('/api/rapportage', vereisRol(MANAGEMENT), async (req, res, next) => {
    try {
      const [[totaal]] = await db.query(
        `SELECT (SELECT COUNT(*) FROM patienten) AS patienten,
                (SELECT COUNT(*) FROM dossiers)  AS dossiers,
                (SELECT COUNT(*) FROM afspraken) AS afspraken`);
      const [perStatus] = await db.query('SELECT status, COUNT(*) AS aantal FROM afspraken GROUP BY status');
      const [perMaand]  = await db.query(
        "SELECT DATE_FORMAT(datum, '%Y-%m') AS maand, COUNT(*) AS aantal FROM dossiers GROUP BY maand ORDER BY maand");
      res.json({ totaal, perStatus, perMaand });
    } catch (err) { next(err); }
  });

  app.use('/api', (req, res) => res.status(404).json({ error: 'Niet gevonden' }));

  // Geen stacktraces of SQL-fouten naar de browser
  app.use((err, req, res, next) => {
    if (err.status === 400) return res.status(400).json({ error: err.message });
    console.error('[fout]', err);
    res.status(500).json({ error: 'Interne fout' });
  });

  app.listen(3000, '127.0.0.1', () => console.log('SecureMed (veilig) luistert op 127.0.0.1:3000'));
}

start().catch(err => {
  console.error('[start] ' + err.message);
  process.exit(1); // systemd probeert opnieuw
});
SERVERJS

# Code is van root en alleen leesbaar voor de app: een gehackte app kan zichzelf niet aanpassen
chown -R root:securemed "$APP_DIR"
chmod -R u=rwX,g=rX,o= "$APP_DIR"

cat > /etc/systemd/system/securemed.service << 'UNIT'
[Unit]
Description=SecureMed Backend (Entra ID, Key Vault, least privilege)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=securemed
Group=securemed
EnvironmentFile=/etc/securemed/backend.env
WorkingDirectory=/opt/securemed
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
CapabilityBoundingSet=
ReadWritePaths=/var/log/securemed

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/logrotate.d/securemed << 'ROTATE'
/var/log/securemed/audit.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 0640 securemed securemed
}
ROTATE

# Hulpscript: maakt de least-privilege DB-gebruiker met het wachtwoord uit Key Vault.
# Het wachtwoord komt nooit op het scherm of op schijf.
cat > /usr/local/sbin/securemed-db-gebruiker << 'DBSCRIPT'
#!/bin/bash
# Gebruik op vm-app: sudo securemed-db-gebruiker   (vraagt het wachtwoord van mysqladmin, of via MYSQL_PWD)
set -euo pipefail
source /etc/securemed/backend.env
CID=""; [ -n "${IDENTITY_CLIENT_ID:-}" ] && CID="&client_id=$IDENTITY_CLIENT_ID"
TOKEN=$(curl -sf -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net$CID" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
PW=$(curl -sf -H "Authorization: Bearer $TOKEN" "${KEY_VAULT_URI%/}/secrets/db-app-wachtwoord?api-version=7.4" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')
U="'$DB_USER'@'$DB_CLIENT_HOST'"
# MYSQL_PWD gezet (start-alles.ps1) -> niet om het wachtwoord vragen
PWOPT="-p"; [ -n "${MYSQL_PWD:-}" ] && PWOPT=""
mysql -h "$DB_HOST" -u mysqladmin $PWOPT --ssl-mode=REQUIRED << SQL
CREATE USER IF NOT EXISTS $U IDENTIFIED BY '$PW' REQUIRE SSL;
ALTER USER $U IDENTIFIED BY '$PW' REQUIRE SSL;
GRANT SELECT ON securemed.patienten TO $U;
GRANT SELECT ON securemed.afspraken TO $U;
GRANT SELECT, INSERT ON securemed.dossiers TO $U;
SQL
echo "DB-gebruiker $DB_USER klaar: SELECT op patienten/afspraken, SELECT+INSERT op dossiers, geen toegang tot medewerkers."
DBSCRIPT
chmod 750 /usr/local/sbin/securemed-db-gebruiker

systemctl daemon-reload
systemctl enable securemed
systemctl restart securemed

echo "  ✓ Backend geïnstalleerd (luistert alleen op 127.0.0.1:3000)"

# =============================================================
#  STAP 3 — Frontend + NGINX
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [3/4] FRONTEND installeren..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cat > "$WEB_DIR/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="nl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SecureMed Clinic — Patiëntportaal</title>
    <link rel="stylesheet" href="/app.css">
    <script src="/app.js" defer></script>
</head>
<body>

<div id="login-screen" hidden>
    <div class="header"><h1>SecureMed Clinic</h1></div>
    <div class="login-wrapper">
        <div class="login-box">
            <h2>Patiëntportaal</h2>
            <p class="subtitle">Aanmelden met je SecureMed-account (Microsoft Entra ID, met MFA)</p>
            <p class="error" id="server-fout" hidden></p>
            <a class="login-btn" href="/auth/login">Aanmelden met Microsoft</a>
            <div class="divider">of</div>
            <form class="form" id="ww-form">
                <input id="ww-gebruiker" autocomplete="username" maxlength="100" placeholder="Gebruikersnaam" required>
                <input id="ww-wachtwoord" type="password" autocomplete="current-password" maxlength="200" placeholder="Wachtwoord" required>
                <button type="submit">Aanmelden</button>
                <p class="error" id="ww-fout" hidden></p>
            </form>
        </div>
    </div>
</div>

<div id="dashboard-screen" hidden>
    <div class="header">
        <h1>SecureMed Clinic — Patiëntportaal</h1>
        <div class="user-info">
            <span id="user-name"></span>
            <span class="role" id="user-role"></span>
            <a class="logout-btn" href="/auth/logout">Afmelden</a>
        </div>
    </div>
    <div class="container">
        <div class="tab-bar" id="tab-bar"></div>

        <div class="section" id="tab-patienten" hidden>
            <h2>Patiëntenlijst</h2>
            <form class="search-box" id="zoek-form">
                <input type="text" id="search-input" maxlength="50" placeholder="Zoek op naam...">
                <button type="submit">Zoeken</button>
            </form>
            <div id="patienten-table">Laden...</div>
        </div>
        <div class="section" id="tab-dossiers" hidden><h2>Medische dossiers</h2><div id="dossiers-table">Laden...</div></div>
        <div class="section" id="tab-afspraken" hidden><h2>Afspraken</h2><div id="afspraken-table">Laden...</div></div>
        <div class="section" id="tab-rapportage" hidden><h2>Rapportage</h2><div id="rapportage-inhoud">Laden...</div></div>
        <div class="section" id="geen-rol" hidden><div class="error">Je account heeft geen rol in het patiëntportaal.</div></div>
    </div>
</div>

<div class="detail-modal" id="detail-modal">
    <div class="detail-content" id="detail-content"></div>
</div>
</body>
</html>
HTML

cat > "$WEB_DIR/app.css" << 'CSS'
* { margin: 0; padding: 0; box-sizing: border-box; }
[hidden] { display: none !important; }
body { font-family: -apple-system, 'Segoe UI', sans-serif; background: #f0f4f8; color: #1a202c; }
.header { background: #1a5276; color: white; padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.header h1 { font-size: 1.4rem; font-weight: 600; }
.user-info { display: flex; align-items: center; gap: 12px; font-size: 0.9rem; }
.user-info .role { background: rgba(255,255,255,0.2); padding: 2px 10px; border-radius: 4px; font-size: 0.75rem; }
.logout-btn { background: rgba(255,255,255,0.15); border: 1px solid rgba(255,255,255,0.3); color: white; padding: 6px 14px; border-radius: 4px; font-size: 0.8rem; text-decoration: none; }
.container { max-width: 1100px; margin: 2rem auto; padding: 0 1rem; }
.login-wrapper { min-height: 80vh; display: flex; align-items: center; justify-content: center; padding: 1rem; }
.login-box { background: white; border-radius: 12px; padding: 2.5rem; width: 100%; max-width: 420px; box-shadow: 0 4px 24px rgba(0,0,0,0.1); text-align: center; }
.login-box h2 { margin-bottom: 0.5rem; color: #1a5276; font-size: 1.5rem; }
.login-box .subtitle { color: #718096; margin-bottom: 2rem; font-size: 0.9rem; }
.login-btn { display: block; width: 100%; padding: 0.8rem; background: #1a5276; color: white; border: none; border-radius: 6px; font-size: 1rem; font-weight: 600; text-decoration: none; }
.login-btn:hover { background: #154360; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
.stat-card { background: #f7fafc; border-radius: 8px; padding: 1.2rem; }
.stat-card .label { font-size: 0.8rem; color: #718096; text-transform: uppercase; }
.stat-card .value { font-size: 2rem; font-weight: 700; color: #1a5276; margin-top: 0.25rem; }
.section { background: white; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow-x: auto; }
.section h2, .section h3 { font-size: 1.1rem; margin: 0 0 1rem; color: #2d3748; }
.search-box { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
.search-box input { flex: 1; padding: 0.6rem 1rem; border: 1px solid #cbd5e0; border-radius: 6px; font-size: 0.9rem; }
.search-box button, .form button { padding: 0.6rem 1.5rem; background: #1a5276; color: white; border: none; border-radius: 6px; cursor: pointer; }
table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
th { text-align: left; padding: 0.6rem; background: #edf2f7; color: #4a5568; font-weight: 600; }
td { padding: 0.6rem; border-bottom: 1px solid #e2e8f0; }
tr.klik { cursor: pointer; }
tr.klik:hover { background: #f7fafc; }
.bsn { font-family: monospace; }
.tab-bar { display: flex; margin-bottom: 1rem; border-bottom: 2px solid #e2e8f0; flex-wrap: wrap; }
.tab { padding: 0.6rem 1.2rem; cursor: pointer; font-size: 0.9rem; border: none; background: none; border-bottom: 2px solid transparent; margin-bottom: -2px; color: #718096; }
.tab.active { border-bottom-color: #1a5276; color: #1a5276; font-weight: 600; }
.tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: 600; background: #ebf8ff; color: #2b6cb0; }
.detail-modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.5); z-index: 100; align-items: center; justify-content: center; }
.detail-modal.show { display: flex; }
.detail-content { background: white; border-radius: 12px; padding: 2rem; max-width: 600px; width: 90%; max-height: 85vh; overflow-y: auto; }
.close-btn { float: right; background: none; border: none; font-size: 1.5rem; cursor: pointer; color: #a0aec0; }
.detail-row { display: flex; padding: 0.4rem 0; border-bottom: 1px solid #f0f0f0; font-size: 0.85rem; }
.detail-label { width: 140px; font-weight: 600; color: #718096; }
.detail-value { flex: 1; }
.dossier { background: #f7fafc; padding: 0.8rem; border-radius: 6px; margin-top: 0.5rem; font-size: 0.85rem; }
.form { display: grid; gap: 0.5rem; margin-top: 1rem; }
.form input, .form textarea { padding: 0.6rem; border: 1px solid #cbd5e0; border-radius: 6px; font: inherit; }
.error { background: #fed7d7; color: #9b2c2c; padding: 1rem; border-radius: 6px; }
.divider { color: #a0aec0; font-size: 0.8rem; margin: 1.2rem 0 0.2rem; }
.login-box .form { margin-top: 0; text-align: left; }
.muted { color: #718096; }
CSS

cat > "$WEB_DIR/app.js" << 'JS'
'use strict';
// Alle data gaat via textContent naar de pagina (nooit innerHTML): geen XSS.
const ZORG    = ['Arts', 'Verpleging'];
const PATIENT = ['Arts', 'Verpleging', 'Administratie'];
let ik = null;

const $ = id => document.getElementById(id);
const heeft = rollen => ik && rollen.some(r => ik.rollen.includes(r));
const datum = s => (s || '').slice(0, 10);

function el(tag, props = {}, ...kinderen) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v);
  }
  for (const k of kinderen) if (k != null) e.append(k instanceof Node ? k : String(k));
  return e;
}

async function api(pad, opties = {}) {
  const res = await fetch('/api' + pad, { credentials: 'same-origin', ...opties });
  if (res.status === 401) { toonLogin(); throw new Error('Niet aangemeld'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Fout ' + res.status);
  return data;
}

function tabel(koppen, rijen, opKlik) {
  const t = el('table', {}, el('tr', {}, ...koppen.map(k => el('th', {}, k))));
  for (const { cellen, data } of rijen) {
    t.append(el('tr', opKlik ? { class: 'klik', onclick: () => opKlik(data) } : {}, ...cellen.map(c => el('td', {}, c))));
  }
  return t;
}

const vul  = (id, ...kinderen) => $(id).replaceChildren(...kinderen);
const fout = (id, err) => vul(id, el('div', { class: 'error' }, err.message));

function toonLogin() {
  $('dashboard-screen').hidden = true;
  $('login-screen').hidden = false;
}

// --- Patiënten ---
function toonPatienten(data) {
  const zorg = heeft(ZORG);
  const koppen = ['Naam', 'Geboortedatum', 'BSN', 'Telefoon'].concat(zorg ? ['Bloedgroep'] : []);
  vul('patienten-table', tabel(koppen, data.map(p => ({
    data: p,
    cellen: [p.voornaam + ' ' + p.achternaam, datum(p.geboortedatum), el('span', { class: 'bsn' }, p.bsn), p.telefoon || '']
      .concat(zorg ? [p.bloedgroep || ''] : []),
  })), toonDetail));
}

async function laadPatienten() {
  try { toonPatienten(await api('/patienten')); } catch (e) { fout('patienten-table', e); }
}

async function zoek(ev) {
  ev.preventDefault();
  const naam = $('search-input').value;
  try { toonPatienten(await api('/zoek?naam=' + encodeURIComponent(naam))); } catch (e) { fout('patienten-table', e); }
}

function rij(label, waarde) {
  return el('div', { class: 'detail-row' }, el('span', { class: 'detail-label' }, label), el('span', { class: 'detail-value' }, waarde || ''));
}

async function toonDetail(p) {
  const inhoud = [
    el('button', { class: 'close-btn', onclick: sluitDetail, 'aria-label': 'Sluiten' }, '×'),
    el('h3', {}, p.voornaam + ' ' + p.achternaam),
    rij('BSN', p.bsn), rij('Geboortedatum', datum(p.geboortedatum)), rij('E-mail', p.email),
    rij('Telefoon', p.telefoon), rij('Adres', p.adres),
  ];
  if (heeft(ZORG)) inhoud.push(rij('Bloedgroep', p.bloedgroep));
  vul('detail-content', ...inhoud);
  $('detail-modal').classList.add('show');

  if (!heeft(ZORG)) return;
  const blok = el('div', {}, el('h3', { style: 'margin-top:1.5rem' }, 'Medisch dossier'), el('p', { class: 'muted' }, 'Laden...'));
  $('detail-content').append(blok);
  try {
    const dossiers = await api('/patienten/' + p.id + '/dossiers');
    blok.replaceChildren(el('h3', { style: 'margin-top:1.5rem' }, 'Medisch dossier'),
      ...(dossiers.length ? dossiers.map(d => el('div', { class: 'dossier' },
        el('strong', {}, datum(d.datum)), ' — ' + d.diagnose, el('br'),
        el('span', { class: 'muted' }, 'Medicatie: '), d.medicatie || '-', el('br'),
        el('span', { class: 'muted' }, 'Arts: '), d.arts || '-',
        ...(d.notities ? [el('br'), el('span', { class: 'muted' }, 'Notities: '), d.notities] : []))) : [el('p', { class: 'muted' }, 'Geen dossiers.')]));
    if (heeft(['Arts'])) blok.append(dossierFormulier(p));
  } catch (e) { blok.replaceChildren(el('div', { class: 'error' }, e.message)); }
}

function dossierFormulier(p) {
  const diagnose  = el('input', { placeholder: 'Diagnose', maxlength: '255', required: '' });
  const medicatie = el('input', { placeholder: 'Medicatie', maxlength: '255' });
  const notities  = el('textarea', { placeholder: 'Notities', maxlength: '2000', rows: '3' });
  const melding   = el('p', { class: 'muted' });
  return el('form', { class: 'form', onsubmit: async ev => {
    ev.preventDefault();
    try {
      await api('/dossiers', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ patient_id: p.id, diagnose: diagnose.value, medicatie: medicatie.value, notities: notities.value }) });
      toonDetail(p);
    } catch (e) { melding.textContent = e.message; }
  } }, el('h3', {}, 'Nieuwe dossierregel'), diagnose, medicatie, notities, el('button', { type: 'submit' }, 'Opslaan'), melding);
}

function sluitDetail() { $('detail-modal').classList.remove('show'); }

// --- Dossiers, afspraken, rapportage ---
async function laadDossiers() {
  try {
    const data = await api('/dossiers');
    vul('dossiers-table', tabel(['Patiënt', 'Datum', 'Diagnose', 'Medicatie', 'Arts'],
      data.map(d => ({ cellen: [d.voornaam + ' ' + d.achternaam, datum(d.datum), d.diagnose, d.medicatie || '', d.arts || ''] }))));
  } catch (e) { fout('dossiers-table', e); }
}

async function laadAfspraken() {
  try {
    const data = await api('/afspraken');
    vul('afspraken-table', tabel(['Patiënt', 'Datum', 'Arts', 'Reden', 'Status'],
      data.map(a => ({ cellen: [a.voornaam + ' ' + a.achternaam, (a.datum || '').slice(0, 16), a.arts || '', a.reden || '', el('span', { class: 'tag' }, a.status)] }))));
  } catch (e) { fout('afspraken-table', e); }
}

async function laadRapportage() {
  try {
    const r = await api('/rapportage');
    const kaart = (label, waarde) => el('div', { class: 'stat-card' }, el('div', { class: 'label' }, label), el('div', { class: 'value' }, waarde));
    vul('rapportage-inhoud',
      el('div', { class: 'stats' }, kaart('Patiënten', r.totaal.patienten), kaart('Dossiers', r.totaal.dossiers), kaart('Afspraken', r.totaal.afspraken)),
      el('h3', {}, 'Afspraken per status'),
      tabel(['Status', 'Aantal'], r.perStatus.map(s => ({ cellen: [s.status, s.aantal] }))),
      el('h3', { style: 'margin-top:1.5rem' }, 'Dossierregels per maand'),
      tabel(['Maand', 'Aantal'], r.perMaand.map(m => ({ cellen: [m.maand, m.aantal] }))));
  } catch (e) { fout('rapportage-inhoud', e); }
}

// --- Opstart: tabs alleen tonen voor de rollen van de gebruiker ---
const TABS = [
  { id: 'patienten',  label: 'Patiënten',  rollen: PATIENT,        laad: laadPatienten },
  { id: 'dossiers',   label: 'Dossiers',   rollen: ZORG,           laad: laadDossiers },
  { id: 'afspraken',  label: 'Afspraken',  rollen: PATIENT,        laad: laadAfspraken },
  { id: 'rapportage', label: 'Rapportage', rollen: ['Management'], laad: laadRapportage },
];

function toonTab(tab, knop) {
  TABS.forEach(t => { $('tab-' + t.id).hidden = t !== tab; });
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('active', b === knop));
  tab.laad();
}

async function start() {
  $('zoek-form').addEventListener('submit', zoek);
  $('ww-form').addEventListener('submit', async ev => {
    ev.preventDefault();
    const knop = ev.target.querySelector('button');
    knop.disabled = true;
    try {
      const res = await fetch('/auth/wachtwoord', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ gebruikersnaam: $('ww-gebruiker').value, wachtwoord: $('ww-wachtwoord').value }),
      });
      const data = await res.json().catch(() => ({}));
      $('ww-fout').textContent = data.error || 'Aanmelden mislukt';
    } catch {
      $('ww-fout').textContent = 'Aanmelden mislukt';
    }
    $('ww-fout').hidden = false;
    $('ww-wachtwoord').value = '';
    knop.disabled = false;
  });
  $('detail-modal').addEventListener('click', ev => { if (ev.target.id === 'detail-modal') sluitDetail(); });

  try {
    ik = await api('/me');
  } catch (e) {
    if (e.message !== 'Niet aangemeld') {
      // Bv. 502: backend draait niet. Toon een melding i.p.v. een wit scherm.
      toonLogin();
      $('server-fout').textContent = 'De server is tijdelijk niet bereikbaar. Probeer het later opnieuw.';
      $('server-fout').hidden = false;
    }
    return;
  }
  $('login-screen').hidden = true;
  $('dashboard-screen').hidden = false;
  $('user-name').textContent = ik.naam;
  $('user-role').textContent = ik.rollen.join(', ');

  const mijnTabs = TABS.filter(t => heeft(t.rollen));
  if (!mijnTabs.length) { $('geen-rol').hidden = false; return; }
  for (const t of mijnTabs) {
    const knop = el('button', { class: 'tab', type: 'button' }, t.label);
    knop.addEventListener('click', () => toonTab(t, knop));
    $('tab-bar').append(knop);
  }
  toonTab(mijnTabs[0], $('tab-bar').firstElementChild);
}

document.addEventListener('DOMContentLoaded', start);
JS

chown -R root:root "$WEB_DIR"
chmod -R a+rX "$WEB_DIR"

# Rate limiting per client-IP (eerste adres in X-Forwarded-For van de Application Gateway, zonder poort)
cat > /etc/nginx/conf.d/securemed-limits.conf << 'LIMITS'
map $http_x_forwarded_for $securemed_client {
    "~^(?<ip>[0-9.]+)" $ip;
    default            $remote_addr;
}
limit_req_zone $securemed_client zone=securemed_auth:10m rate=10r/m;
limit_req_zone $securemed_client zone=securemed_api:10m  rate=20r/s;
limit_req_status 429;
LIMITS

cat > /etc/nginx/snippets/securemed-proxy.conf << 'PROXY'
proxy_pass http://127.0.0.1:3000;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
PROXY

cat > /etc/nginx/sites-available/securemed-veilig << 'NGINXCONF'
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    root /var/www/securemed;
    index index.html;
    client_max_body_size 16k;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" always;
    # HSTS pas aanzetten met een vertrouwd certificaat; met een zelfondertekend
    # certificaat kan niemand de certificaatwaarschuwing nog wegklikken.
    # add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        try_files $uri $uri/ =404;
    }

    location /auth/ {
        limit_req zone=securemed_auth burst=10 nodelay;
        include /etc/nginx/snippets/securemed-proxy.conf;
    }

    location /api/ {
        limit_req zone=securemed_api burst=40 nodelay;
        include /etc/nginx/snippets/securemed-proxy.conf;
    }
}
NGINXCONF

rm -f /etc/nginx/sites-enabled/*
ln -sf /etc/nginx/sites-available/securemed-veilig /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

echo "  ✓ NGINX: security headers, rate limiting, backend alleen via proxy"

# =============================================================
#  STAP 4 — Verificatie
# =============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [4/4] VERIFICATIE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sleep 5
# Niet op systemctl is-active vertrouwen: tijdens een herstartlus is de service even "active"
if curl -sf http://localhost/api/health | grep -q '"ok"'; then
  echo "  Backend:  actief"
  echo "  Health:   $(curl -s http://localhost/api/health)"
  echo "  Zonder login /api/patienten: HTTP $(curl -s -o /dev/null -w '%{http_code}' http://localhost/api/patienten) (verwacht 401)"
  echo "  /api/debug:                  HTTP $(curl -s -o /dev/null -w '%{http_code}' http://localhost/api/debug) (verwacht 404)"
  LOGIN=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://localhost/auth/login)
  echo "  /auth/login: ${LOGIN%%\?*}"
  echo "  Poort 3000 van buitenaf: $(ss -tln | grep -q '0.0.0.0:3000' && echo 'OPEN (fout!)' || echo 'dicht (alleen 127.0.0.1)')"
else
  echo "  Backend:  NIET actief. Laatste logregels:"
  journalctl -u securemed -n 8 --no-pager | sed 's/^/    /'
  echo ""
  echo "  Veelvoorkomende oorzaken:"
  echo "    - 'SecretNotFound' of '403'  -> azure/ apply nog niet gedaan (secret / KV-rol voor vm-app)"
  echo "    - 'Access denied for user'  -> sudo securemed-db-gebruiker nog niet uitgevoerd"
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  VEILIGE SETUP COMPLEET                      ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Website: $BASE_URL"
echo "║  Aanmelden met een Entra-account uit de      ║"
echo "║  tenant van de docent (bv. an.peeters@...)   ║"
echo "║                                              ║"
echo "║  Opgelost t.o.v. setup-alles.sh:             ║"
echo "║    ✓ Entra ID + MFA i.p.v. eigen wachtwoorden║"
echo "║    ✓ Rollen uit token (least privilege)      ║"
echo "║    ✓ Secrets uit Key Vault (managed identity)║"
echo "║    ✓ Geparametriseerde queries               ║"
echo "║    ✓ Geen /api/debug of /api/medewerkers     ║"
echo "║    ✓ Geen XSS (textContent + CSP)            ║"
echo "║    ✓ Sessiecookie (HttpOnly, Secure, 8 uur)  ║"
echo "║    ✓ Rate limiting + security headers        ║"
echo "║    ✓ App draait niet als root, niet op 0.0.0.0║"
echo "║    ✓ Audit-log voor Wazuh                    ║"
echo "║    ✓ Lokformulier: honeytokens -> alert      ║"
echo "╚══════════════════════════════════════════════╝"
