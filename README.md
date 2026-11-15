# SecureMed Clinic – IAM (Terraform)

Onderdeel van het Zero Trust-project (verantwoordelijke IAM: Alan Skrodzki).

## Waarom twee delen?

Jullie werken met twee tenants die niet gekoppeld kunnen worden:

| | Tenant van de docent | Schooltenant |
|---|---|---|
| Wat | Entra ID: medewerkers, rollen, MFA, Conditional Access | Azure-subscription met de VM's, het netwerk en Wazuh |
| Rechten | Global Admin | Owner op de subscription (één teamlid) |
| Subscription | Niet toegestaan door de docent | Ja (Azure for Students) |

De webapp kan toch via de tenant van de docent laten aanmelden, want aanmelden met OpenID Connect werkt over het internet en heeft geen subscription nodig. Daarom:

```
entra/            -> tenant van de docent: wie mag binnen in de app, en onder welke voorwaarden
infra/            -> schoolsubscription: netwerk, VM's, App Gateway + WAF, MySQL, Bastion,
                     Wazuh, honeypot (van Lahcen) + IAM (modules/iam: rollen, Key Vault, Entra-login op VM's)
mysql/            -> schema + testdata (database.sql)
setup-alles.sh    -> kwetsbare "voor"-versie van de app op vm-app
setup-veilig.sh   -> veilige "na"-versie: Entra-login, rollen, Key Vault, audit-log voor Wazuh
start-alles.ps1   -> stap 2 + 3 in één keer (infra apply, app, database)
demo-check.ps1    -> controleert de hele opstelling (25 tests) en schrijft rapporten/audit-*.md
rapporten/        -> auditrapporten van demo-check.ps1
```

## Overzicht van de toegang

**Medewerkers (via de SecureMed-webapp, tenant van de docent)**

| Groep | App role | Mag in de app |
|---|---|---|
| grp-artsen | Arts | Dossiers lezen en schrijven |
| grp-verpleging | Verpleging | Dossiers alleen lezen |
| grp-administratie | Administratie | Afspraken en facturatie, geen dossiers |
| grp-management | Management | Rapportages, geen dossiers |

De app staat op "toewijzing vereist". Wie geen app role heeft (beheeraccounts, het decoy-account), kan niet aanmelden.

**Team (beheer van de infrastructuur, schoolaccounts)**

| Taak | Rollen |
|---|---|
| lezer | Reader op de RG (ook nodig voor Bastion) |
| netwerk | Network Contributor |
| vm-admin | Virtual Machine Administrator Login (SSH met sudo) |
| vm-user | Virtual Machine User Login (SSH zonder sudo) |
| soc | Virtual Machine Administrator Login, alleen op vm-wazuh |
| app-deploy | Virtual Machine Contributor, alleen op vm-app (az vm run-command) |
| keyvault | Key Vault Secrets Officer |
| compliance | Security Reader op de RG (Defender for Cloud, CIS) |
| iam | Role Based Access Control Administrator op de RG |

**Conditional Access (tenant van de docent, vereist P1)**

- CA01: MFA voor iedereen.
- CA02: legacy authentication blokkeren.
- CA03: beheerrollen moeten elke 4 uur opnieuw aanmelden.
- CA04: aanmelden buiten België blokkeren.
- CA05: de SecureMed-app vraagt MFA en een sessie duurt maximaal 8 uur.
- CA06: aanmeldingen met hoog risico blokkeren (P2).

## Uitrollen

### Stap 1 – Entra (Alan, met het adminaccount van de tenant van de docent)

```powershell
cd entra
az login --tenant <tenant-id-docent> --allow-no-subscriptions
copy terraform.tfvars.example terraform.tfvars   # invullen
terraform init
terraform plan
terraform apply
```

Daarna:

1. Haal de break-glass wachtwoorden op met `terraform output -json breakglass_wachtwoorden`. Test of je ermee kunt aanmelden en bewaar ze offline.
2. Registreer MFA voor je eigen adm-account.
3. Controleer de report-only resultaten (Entra > Sign-in logs > Report-only).
4. Zet `ca_state = "enabled"` en voer opnieuw `terraform apply` uit.

Bezorg het client secret aan wie stap 2 uitvoert. Je haalt het op met `terraform output -raw app_client_secret`. Stuur het niet via chat, maar geef het bv. door via een password manager.

### Snel: stap 2 + 3 in één keer

```powershell
az login --tenant <tenant-id-school>
.\start-alles.ps1              # terraform apply (vraagt "yes"), daarna app + database op vm-app
.\start-alles.ps1 -AlleenApp   # infra staat al: alleen app + database
.\demo-check.ps1               # alles controleren
```

Het script haalt het client secret uit de lokale state van `entra/` en geeft het mysqladmin-wachtwoord via een tijdelijk Key Vault-secret aan vm-app. Dat secret wordt daarna gewist en gepurged.

### Stap 2 – Infrastructuur + IAM (Owner van de subscription, schoolaccount)

Eén `apply` bouwt alles: netwerk, VM's, App Gateway (DNS-label, HTTP→HTTPS, WAF-uitzondering voor `code`), MySQL, Bastion (tunneling), Wazuh (+ regels voor de app), honeypot, de teamrollen, de Key Vault met app-secrets en Entra-login op vm-app en vm-wazuh.

```powershell
cd infra
az login --tenant <tenant-id-school>
copy terraform.tfvars.example terraform.tfvars   # invullen
# Aanhalingstekens rond -chdir zijn nodig in PowerShell 5.1
$env:TF_VAR_entra_client_secret = (terraform "-chdir=..\entra" output -raw app_client_secret)
terraform init
terraform plan
terraform apply
```

### Stap 3 – App en database (vm-app)

De database is privé, dus alles gebeurt vanaf vm-app:

1. Schema + testdata: zet `mysql/database.sql` op vm-app en voer het uit met `mysqladmin` (zie de kop van dat bestand).
2. App: `az vm run-command invoke -g rg-zerotrust -n vm-app --command-id RunShellScript --scripts "@setup-veilig.sh"` (of `@setup-alles.sh` voor de kwetsbare versie).
3. DB-gebruiker van de app (via Bastion, als `azureadmin`): `sudo securemed-db-gebruiker`. Haalt het wachtwoord zelf uit Key Vault.

Aanmelden op een VM met je schoolaccount (Entra, rol `vm-user`/`vm-admin`):
```powershell
az network bastion ssh --name bastion-zerotrust --resource-group rg-zerotrust `
  --target-resource-id <vm-id> --auth-type AAD
```

## Rollen controleren in de Node.js-app

Na het aanmelden staat de rol in de `roles`-claim van het ID-token. Een voorbeeld van een middleware:

```js
function vereisRol(...toegestaan) {
  return (req, res, next) => {
    const claims = req.session.account?.idTokenClaims;
    if (!claims) return res.redirect('/auth/login');

    const rollen = claims.roles || [];
    if (toegestaan.some(r => rollen.includes(r))) return next();

    // Gaat via de Wazuh-agent naar Wazuh
    console.warn(JSON.stringify({
      event: 'toegang_geweigerd',
      gebruiker: claims.preferred_username,
      rollen, pad: req.path, ip: req.ip
    }));
    return res.status(403).send('Geen toegang');
  };
}

app.get('/dossiers/:id', vereisRol('Arts', 'Verpleging'), toonDossier);
app.put('/dossiers/:id', vereisRol('Arts'), wijzigDossier);
app.get('/facturen',     vereisRol('Administratie', 'Management'), toonFacturen);
```

De secrets haal je op met de managed identity, nooit uit een `.env`-bestand:

```js
const { ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');

const cred = new ManagedIdentityCredential(process.env.BACKEND_IDENTITY_CLIENT_ID);
const kv = new SecretClient(process.env.KEY_VAULT_URI, cred);
const dbWachtwoord = (await kv.getSecret('db-app-wachtwoord')).value;
```

## Beperkingen (opnemen in het verslag)

| Beperking | Oorzaak | Gevolg / oplossing |
|---|---|---|
| Entra sign-in logs komen niet automatisch in Wazuh | Entra zit in een andere tenant | De app logt zelf aanmeldingen, geweigerde toegang en honeytoken-pogingen (`/var/log/securemed/audit.log`, regels 100200-100202). Optioneel haalt Wazuh de sign-in logs op via de Graph API (vereist P1). |
| Geen PIM op de Azure-resources | Geen admin in de schooltenant | Least privilege per taak. Owner blijft bij één persoon. |
| MFA bij beheer via Bastion | Wordt bepaald door de schooltenant | Documenteren. |
| Decoy-account kan niet aanmelden op de app | "Toewijzing vereist" | Dat is bewust. De poging verschijnt in de Entra sign-in logs (foutcode AADSTS50105). |

## Beveiliging van de code

De Terraform state van **beide** delen bevat wachtwoorden en secrets. Zet nooit `*.tfstate` of `*.tfvars` op GitHub (zie `.gitignore`).
