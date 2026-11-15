-- ---------------------------------------------------------------------------
-- SecureMed: least privilege in MySQL
-- Uitvoeren op de database-VM als root:  sudo mysql < least_privilege.sql
-- Vervang eerst de wachtwoorden (staan in Key Vault):
--   az keyvault secret show --vault-name <kv> --name db-app-wachtwoord --query value -o tsv
-- en pas '10.0.2.%' aan naar het bereik van jullie backend-subnet.
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS securemed;

-- 1. App-gebruiker: alleen vanaf de backend-subnet, alleen wat de app nodig heeft.
--    Geen DELETE, DROP, ALTER of GRANT: een gehackte backend kan geen
--    dossiers wissen of de database-structuur wijzigen.
CREATE USER IF NOT EXISTS 'securemed_app'@'10.0.2.%'
  IDENTIFIED BY '<WACHTWOORD_UIT_KEY_VAULT>';
GRANT SELECT, INSERT, UPDATE ON securemed.* TO 'securemed_app'@'10.0.2.%';

-- 2. Audit-gebruiker (compliance, Lahcen): alleen lezen, alleen lokaal (via Bastion op de VM).
CREATE USER IF NOT EXISTS 'securemed_audit'@'localhost'
  IDENTIFIED BY '<ANDER_STERK_WACHTWOORD>';
GRANT SELECT ON securemed.* TO 'securemed_audit'@'localhost';

-- 3. Root mag nooit van buitenaf aanmelden.
DROP USER IF EXISTS 'root'@'%';

-- 4. Anonieme gebruikers en de testdatabase verwijderen.
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;

FLUSH PRIVILEGES;

-- Controle:
SELECT User, Host FROM mysql.user;
SHOW GRANTS FOR 'securemed_app'@'10.0.2.%';
