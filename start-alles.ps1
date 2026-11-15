# ============================================================
# SecureMed - alles opstarten na een terraform destroy
# ============================================================
# 1. terraform apply in infra/ (met het Entra client secret uit entra/)
# 2. op vm-app: setup-veilig.sh, database.sql importeren, DB-gebruiker securemed_web
#
# Het mysqladmin-wachtwoord gaat via een tijdelijk Key Vault-secret naar de VM
# (niet via de run-command-parameters) en wordt daarna gewist + gepurged.
#
# Gebruik (vanuit de repo-root):
#   .\start-alles.ps1              # infra + app
#   .\start-alles.ps1 -AlleenApp   # infra staat al, alleen de app opnieuw
# ============================================================

param([switch]$AlleenApp)

$ErrorActionPreference = 'Stop'
$Root         = $PSScriptRoot
$Subscription = '300613b1-5389-497b-b065-02d863b3ae84'
$TmpSecret    = 'tmp-mysqladmin'

function Stap($tekst) { Write-Host "`n=== $tekst ===" -ForegroundColor Cyan }

az account set --subscription $Subscription
if ($LASTEXITCODE -ne 0) { throw "az account set mislukt (az login gedaan?)" }

# --- 1. Infra --------------------------------------------------------------
if (-not $AlleenApp) {
    Stap "1/3 terraform apply in infra/ (duurt 30-40 min)"
    # Alleen lokale state lezen: geen login in de tenant van de docent nodig
    $env:TF_VAR_entra_client_secret = terraform "-chdir=$Root\entra" output -raw app_client_secret
    if ($LASTEXITCODE -ne 0 -or -not $env:TF_VAR_entra_client_secret) { throw "app_client_secret niet gevonden in entra/" }
    try {
        terraform "-chdir=$Root\infra" init -input=false | Out-Null
        terraform "-chdir=$Root\infra" apply
        if ($LASTEXITCODE -ne 0) { throw "terraform apply mislukt" }
    } finally {
        Remove-Item Env:\TF_VAR_entra_client_secret -ErrorAction SilentlyContinue
    }
}

$Rg      = terraform "-chdir=$Root\infra" output -raw resource_group_name
$KvUri   = terraform "-chdir=$Root\infra" output -raw key_vault_uri
$Website = terraform "-chdir=$Root\infra" output -raw website
$KvNaam  = ([uri]$KvUri).Host.Split('.')[0]

# --- 2. App op vm-app ------------------------------------------------------
Stap "2/3 setup-veilig.sh + database op vm-app (5-10 min)"

$tfvars = Get-Content "$Root\infra\terraform.tfvars" -Raw
if ($tfvars -notmatch '(?m)^\s*mysql_admin_password\s*=\s*"((?:[^"\\]|\\.)*)"') { throw "mysql_admin_password niet gevonden in infra/terraform.tfvars" }
$MysqlPw = $Matches[1] -replace '\\"', '"' -replace '\\\\', '\'

function GzipB64($pad) {
    $tekst = [IO.File]::ReadAllText($pad) -replace "`r`n", "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($tekst)
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
    [Convert]::ToBase64String($ms.ToArray())
}

$Setup = GzipB64 "$Root\setup-veilig.sh"
$Sql   = GzipB64 "$Root\mysql\database.sql"

$VmScript = @"
#!/bin/bash
set -e
cloud-init status --wait >/dev/null 2>&1 || true   # apt-lock van de Wazuh-agentinstallatie
echo '$Setup' | base64 -d | gunzip > /root/setup-veilig.sh
echo '$Sql' | base64 -d | gunzip > /root/database.sql
if ! bash /root/setup-veilig.sh > /var/log/securemed-setup.log 2>&1; then
  echo "setup-veilig.sh mislukt:"; tail -30 /var/log/securemed-setup.log; exit 1
fi
source /etc/securemed/backend.env
TOKEN=`$(curl -sf -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
export MYSQL_PWD=`$(curl -sf -H "Authorization: Bearer `$TOKEN" "`${KEY_VAULT_URI%/}/secrets/${TmpSecret}?api-version=7.4" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')
if mysql -h "`$DB_HOST" -u mysqladmin --ssl-mode=REQUIRED -e "SELECT 1 FROM securemed.patienten LIMIT 1" >/dev/null 2>&1; then
  echo "Database securemed bestaat al: import overgeslagen"
else
  mysql -h "`$DB_HOST" -u mysqladmin --ssl-mode=REQUIRED < /root/database.sql
  echo "database.sql geimporteerd"
fi
/usr/local/sbin/securemed-db-gebruiker
unset MYSQL_PWD
rm -f /root/database.sql
systemctl restart securemed
sleep 5
echo "Health op vm-app: `$(curl -s http://localhost/api/health)"
"@

$ScriptFile = Join-Path $env:TEMP "securemed-start-$PID.sh"
$PwFile     = Join-Path $env:TEMP "securemed-pw-$PID.txt"
try {
    [IO.File]::WriteAllText($ScriptFile, ($VmScript -replace "`r`n", "`n"))
    [IO.File]::WriteAllText($PwFile, $MysqlPw)
    az keyvault secret set --vault-name $KvNaam --name $TmpSecret --file $PwFile --encoding utf-8 -o none
    if ($LASTEXITCODE -ne 0) { throw "tijdelijk secret zetten mislukt" }
    Remove-Item $PwFile

    az vm run-command invoke -g $Rg -n vm-app --command-id RunShellScript `
        --scripts "@$ScriptFile" --query "value[0].message" -o tsv
    if ($LASTEXITCODE -ne 0) { throw "run-command op vm-app mislukt" }
} finally {
    $ErrorActionPreference = 'Continue'   # PS 5.1: 2>$null bij az zou anders een fout gooien
    Remove-Item $ScriptFile, $PwFile -ErrorAction SilentlyContinue
    az keyvault secret delete --vault-name $KvNaam --name $TmpSecret -o none 2>$null
    for ($i = 0; $i -lt 10; $i++) {
        az keyvault secret purge --vault-name $KvNaam --name $TmpSecret -o none 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 3
    }
}

# --- 3. Controle -----------------------------------------------------------
Stap "3/3 controle via de App Gateway"
Write-Host "Health: $(curl.exe -sk "$Website/api/health")"
Write-Host "`nKlaar: $Website" -ForegroundColor Green
Write-Host "Volledige test: .\demo-check.ps1"
