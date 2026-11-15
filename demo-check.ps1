<#
  SecureMed - controle van de Zero Trust-maatregelen ("na"-situatie) + auditrapport.
  Voert alle tests uit die zonder interactieve login kunnen en schrijft het resultaat
  naar rapporten\audit-<datum>.md.

  Gebruik:  .\demo-check.ps1
            .\demo-check.ps1 -Subscription <id> -Site https://<naam>.swedencentral.cloudapp.azure.com
#>
param(
    [string]$Subscription = '300613b1-5389-497b-b065-02d863b3ae84',
    [string]$ResourceGroup = 'rg-zerotrust',
    [string]$Site = 'https://securemed-zt2.swedencentral.cloudapp.azure.com',
    [string]$EntraTenant = 'c0abb0b5-4c84-4c3b-ad0c-bbc75a468bca'
)

$ErrorActionPreference = 'Continue'
$resultaten = New-Object System.Collections.Generic.List[object]

function Test-Stap([string]$Groep, [string]$Test, [string]$Verwacht, [string]$Gemeten, [bool]$Ok) {
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    $resultaten.Add([pscustomobject]@{ Groep = $Groep; Test = $Test; Verwacht = $Verwacht; Gemeten = $Gemeten; Status = $status })
    $kleur = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1,-13} {2}  (gemeten: {3})" -f $status, $Groep, $Test, $Gemeten) -ForegroundColor $kleur
}

function Http-Code([string]$Url, [string]$Extra = '') {
    if ($Extra) { return (curl.exe -k -s -o NUL -w '%{http_code}' --max-time 15 $Extra $Url) }
    return (curl.exe -k -s -o NUL -w '%{http_code}' --max-time 15 $Url)
}

# Script op een VM uitvoeren via een bestand (voorkomt problemen met aanhalingstekens)
function Invoke-OpVm([string]$Vm, [string]$Bash) {
    $f = Join-Path $env:TEMP "securemed-check-$Vm.sh"
    [IO.File]::WriteAllText($f, $Bash.Replace("`r`n", "`n"))
    Push-Location $env:TEMP
    $uit = az vm run-command invoke -g $ResourceGroup -n $Vm --subscription $Subscription --command-id RunShellScript --scripts "@$(Split-Path $f -Leaf)" --query 'value[0].message' -o tsv 2>$null
    Pop-Location
    Remove-Item $f -ErrorAction SilentlyContinue
    $waarden = @{}
    foreach ($regel in ($uit -split "`n")) { if ($regel -match '^(\w+)=(.*)$') { $waarden[$Matches[1]] = $Matches[2].Trim() } }
    return $waarden
}

Write-Host "`n=== 1. Website en WAF (vanaf internet) ===" -ForegroundColor Cyan
$c = Http-Code "$Site/api/health";                 Test-Stap 'Website' 'App online (/api/health)' '200' $c ($c -eq '200')
$c = Http-Code "$Site/api/patienten";              Test-Stap 'Toegang' 'Patiëntdata zonder aanmelden' '401' $c ($c -eq '401')
$c = Http-Code "$Site/api/debug";                  Test-Stap 'Toegang' '/api/debug (lekte secrets)' '404' $c ($c -eq '404')
$c = Http-Code "$Site/api/medewerkers";            Test-Stap 'Toegang' '/api/medewerkers (lekte wachtwoorden)' '404' $c ($c -eq '404')
$sqli = [uri]::EscapeDataString("' OR '1'='1' -- ")
$c = Http-Code "$Site/api/zoek?naam=$sqli";        Test-Stap 'WAF' "SQL-injectie ' OR '1'='1" '403' $c ($c -eq '403')
$xss = [uri]::EscapeDataString('<script>alert(1)</script>')
$c = Http-Code "$Site/api/zoek?naam=$xss";         Test-Stap 'WAF' 'XSS <script>' '403' $c ($c -eq '403')
$c = Http-Code "$Site/auth/callback?code=1.AbC--xYz&state=x"; Test-Stap 'WAF' 'Entra-code met -- niet geblokkeerd' '400' $c ($c -eq '400')
$http = $Site -replace '^https:', 'http:'
$c = curl.exe -s -o NUL -w '%{http_code}' --max-time 15 "$http/"; Test-Stap 'Website' 'HTTP wordt HTTPS' '301' $c ($c -eq '301')
$login = curl.exe -k -s -o NUL -w '%{redirect_url}' --max-time 15 "$Site/auth/login"
Test-Stap 'IAM' 'Aanmelden via Entra (tenant docent)' 'login.microsoftonline.com' (($login -split '\?')[0]) ($login -like "https://login.microsoftonline.com/$EntraTenant/*")
$headers = curl.exe -k -s -I --max-time 15 "$Site/"
Test-Stap 'Website' 'Security headers (CSP, X-Frame-Options)' 'aanwezig' ((($headers | Select-String 'content-security-policy|x-frame-options').Count).ToString() + ' van 2') ((($headers | Select-String 'content-security-policy|x-frame-options').Count) -eq 2)

Write-Host "`n=== 2. Azure: blootstelling en IAM ===" -ForegroundColor Cyan
$ips = az vm list-ip-addresses -g $ResourceGroup --subscription $Subscription --query '[].virtualMachine.network.publicIpAddresses[0].ipAddress' -o tsv
Test-Stap 'Netwerk' "VM's zonder publiek IP" '0' ((@($ips | Where-Object { $_ })).Count) ((@($ips | Where-Object { $_ })).Count -eq 0)
$kvRbac = az keyvault list -g $ResourceGroup --subscription $Subscription --query "[?starts_with(name,'kv-securemed')].properties.enableRbacAuthorization | [0]" -o tsv
Test-Stap 'Secrets' 'Key Vault app-secrets met RBAC' 'true' $kvRbac ($kvRbac -eq 'true')
$rollen = az role assignment list -g $ResourceGroup --subscription $Subscription --query "[].{wie:principalName, rol:roleDefinitionName, scope:scope}" -o json | ConvertFrom-Json
$owners = @($rollen | Where-Object { $_.rol -eq 'Owner' -and $_.scope -like '*resourceGroups*' })
Test-Stap 'IAM' 'Geen Owner op de RG (least privilege)' '0' $owners.Count ($owners.Count -eq 0)

Write-Host "`n=== 3. Entra: Conditional Access ===" -ForegroundColor Cyan
$caOk = $false; $caTekst = 'niet opvraagbaar'
try {
    # Even het account van de docent-tenant actief maken (anders vraagt de CLI het token met het schoolaccount)
    az account set --subscription $EntraTenant 2>$null
    $token = az account get-access-token --tenant $EntraTenant --resource-type ms-graph --query accessToken -o tsv 2>$null
    az account set --subscription $Subscription 2>$null
    if ($token) {
        $ca = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$select=displayName,state' -Headers @{ Authorization = "Bearer $token" }
        $ca.value | ForEach-Object { Write-Host ("        {0,-60} {1}" -f $_.displayName, $_.state) }
        $aan = @($ca.value | Where-Object { $_.state -eq 'enabled' }).Count
        $caTekst = "$aan van $(@($ca.value).Count) enabled"; $caOk = ($aan -ge 5)
    }
} catch { $caTekst = 'geen rechten (meld aan in de tenant van de docent)' }
Test-Stap 'IAM' 'CA-policies afgedwongen (MFA)' '5 enabled' $caTekst $caOk

Write-Host "`n=== 4. Segmentatie en hardening (binnen de VM's) ===" -ForegroundColor Cyan
$app = Invoke-OpVm 'vm-app' @'
. /etc/securemed/backend.env 2>/dev/null
poort() { timeout 4 bash -c "</dev/tcp/$1/$2" 2>/dev/null && echo open || echo dicht; }
echo "db=$(poort $DB_HOST 3306)"
echo "wazuh_ssh=$(poort 10.0.3.10 22)"
echo "wazuh_agent=$(poort 10.0.3.10 1514)"
echo "luistert3000=$(ss -tln | grep -q '0.0.0.0:3000' && echo extern || echo lokaal)"
echo "appuser=$(ps -o user= -C node | head -1)"
echo "agent=$(systemctl is-active wazuh-agent)"
'@
Test-Stap 'Netwerk' 'vm-app -> database (3306)' 'open' $app['db'] ($app['db'] -eq 'open')
Test-Stap 'Netwerk' 'vm-app -> SSH op vm-wazuh' 'dicht' $app['wazuh_ssh'] ($app['wazuh_ssh'] -eq 'dicht')
Test-Stap 'Netwerk' 'vm-app -> Wazuh-agentpoort (1514)' 'open' $app['wazuh_agent'] ($app['wazuh_agent'] -eq 'open')
Test-Stap 'Hardening' 'Backend alleen op 127.0.0.1:3000' 'lokaal' $app['luistert3000'] ($app['luistert3000'] -eq 'lokaal')
Test-Stap 'Hardening' 'Backend draait niet als root' 'securemed' $app['appuser'] ($app['appuser'] -eq 'securemed')

$hp = Invoke-OpVm 'vm-honeypot' @'
echo "internet=$(curl -s -m 5 -o /dev/null https://www.microsoft.com && echo open || echo dicht)"
echo "wazuh=$(timeout 4 bash -c '</dev/tcp/10.0.3.10/1514' 2>/dev/null && echo open || echo dicht)"
echo "querylog=$(mysql -N -e 'SELECT @@general_log' 2>/dev/null)"
'@
Test-Stap 'Netwerk' 'Honeypot -> internet' 'dicht' $hp['internet'] ($hp['internet'] -eq 'dicht')
Test-Stap 'Netwerk' 'Honeypot -> Wazuh (1514)' 'open' $hp['wazuh'] ($hp['wazuh'] -eq 'open')
Test-Stap 'Monitoring' 'Honeypot logt elke DB-query' '1' $hp['querylog'] ($hp['querylog'] -eq '1')

Write-Host "`n=== 5. Monitoring (Wazuh) ===" -ForegroundColor Cyan
$wz = Invoke-OpVm 'vm-wazuh' @'
echo "agents=$(/var/ossec/bin/agent_control -l | grep -c 'Active')"
echo "discord=$(grep -c '<name>custom-discord</name>' /var/ossec/etc/ossec.conf)"
echo "ar=$(grep -c '<rules_id>100002,100005</rules_id>' /var/ossec/etc/ossec.conf)"
python3 - << 'PY'
import json, collections
tel = collections.Counter()
for l in open('/var/ossec/logs/alerts/alerts.json'):
    try: a = json.loads(l)
    except ValueError: continue
    rid = a['rule']['id']
    if rid.startswith('1000') or rid.startswith('1002'): tel[rid + ' ' + a['rule']['description']] += 1
print('alerts=' + ' | '.join('%s (x%d)' % kv for kv in sorted(tel.items())))
PY
'@
Test-Stap 'Monitoring' 'Wazuh-agents actief (server + app + honeypot)' '3' $wz['agents'] ($wz['agents'] -eq '3')
Test-Stap 'Monitoring' 'Alerts naar Discord' '1' $wz['discord'] ($wz['discord'] -eq '1')
Test-Stap 'Monitoring' 'Active response (blokkeer aanvaller)' '1' $wz['ar'] ($wz['ar'] -ge '1')

# --- Auditrapport ---
$map = Join-Path $PSScriptRoot 'rapporten'
New-Item -ItemType Directory -Force $map | Out-Null
$bestand = Join-Path $map ("audit-{0:yyyy-MM-dd_HHmm}.md" -f (Get-Date))
$geslaagd = @($resultaten | Where-Object Status -eq 'PASS').Count
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# SecureMed - auditrapport Zero Trust")
[void]$md.AppendLine("")
[void]$md.AppendLine("Datum: $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  Omgeving: $Site  |  Resultaat: **$geslaagd van $($resultaten.Count) geslaagd**")
[void]$md.AppendLine("")
[void]$md.AppendLine("## Tests")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Status | Groep | Test | Verwacht | Gemeten |")
[void]$md.AppendLine("|---|---|---|---|---|")
foreach ($r in $resultaten) { [void]$md.AppendLine("| $($r.Status) | $($r.Groep) | $($r.Test) | $($r.Verwacht) | $($r.Gemeten) |") }
[void]$md.AppendLine("")
[void]$md.AppendLine("## Roltoewijzingen op $ResourceGroup")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Wie | Rol | Scope |")
[void]$md.AppendLine("|---|---|---|")
foreach ($r in ($rollen | Sort-Object wie, rol)) { [void]$md.AppendLine("| $($r.wie) | $($r.rol) | $($r.scope -replace '^/subscriptions/[^/]+', '') |") }
[void]$md.AppendLine("")
[void]$md.AppendLine("## Wazuh-alerts (eigen regels)")
[void]$md.AppendLine("")
foreach ($a in ($wz['alerts'] -split ' \| ')) { if ($a) { [void]$md.AppendLine("- $a") } }
[IO.File]::WriteAllText($bestand, $md.ToString())

Write-Host ("`nResultaat: {0} van {1} geslaagd. Rapport: {2}" -f $geslaagd, $resultaten.Count, $bestand) -ForegroundColor Cyan
