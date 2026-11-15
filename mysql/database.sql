-- ---------------------------------------------------------------------------
-- SecureMed: schema + fictieve data voor de Azure MySQL Flexible Server
-- Bewust kwetsbare beginsituatie (plain text wachtwoorden, te brede app-user).
--
-- Eenmalig uitvoeren vanaf vm-app (de enige plek die de private server bereikt):
--   sudo apt install -y mysql-client
--   mysql -h <mysql_server_name>.mysql.database.azure.com -u mysqladmin -p \
--         --ssl-mode=REQUIRED < database.sql
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS securemed
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE securemed;

-- Patiënten
CREATE TABLE IF NOT EXISTS patienten (
    id INT AUTO_INCREMENT PRIMARY KEY,
    voornaam VARCHAR(50) NOT NULL,
    achternaam VARCHAR(50) NOT NULL,
    geboortedatum DATE NOT NULL,
    bsn VARCHAR(11) NOT NULL,
    email VARCHAR(100),
    telefoon VARCHAR(20),
    adres VARCHAR(200),
    bloedgroep ENUM('A+','A-','B+','B-','AB+','AB-','O+','O-'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Medische dossiers
CREATE TABLE IF NOT EXISTS dossiers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    patient_id INT NOT NULL,
    datum DATE NOT NULL,
    diagnose VARCHAR(255) NOT NULL,
    medicatie VARCHAR(255),
    arts VARCHAR(100),
    notities TEXT,
    FOREIGN KEY (patient_id) REFERENCES patienten(id)
);

-- Afspraken
CREATE TABLE IF NOT EXISTS afspraken (
    id INT AUTO_INCREMENT PRIMARY KEY,
    patient_id INT NOT NULL,
    datum DATETIME NOT NULL,
    arts VARCHAR(100),
    reden VARCHAR(255),
    status ENUM('gepland','voltooid','geannuleerd') DEFAULT 'gepland',
    FOREIGN KEY (patient_id) REFERENCES patienten(id)
);

-- Medewerkers (met plain text wachtwoorden — ONVEILIG!)
CREATE TABLE IF NOT EXISTS medewerkers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    gebruikersnaam VARCHAR(50) NOT NULL UNIQUE,
    wachtwoord VARCHAR(100) NOT NULL,
    volledige_naam VARCHAR(100) NOT NULL,
    rol ENUM('arts','receptie','admin','lab') NOT NULL,
    email VARCHAR(100),
    actief TINYINT(1) DEFAULT 1,
    laatst_ingelogd DATETIME,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- === FICTIEVE DATA ===
INSERT INTO patienten (voornaam, achternaam, geboortedatum, bsn, email, telefoon, adres, bloedgroep) VALUES
('Jan',     'Janssen',     '1985-03-15', '123456789', 'jan.janssen@test.be',     '0471-123456', 'Kerkstraat 12, 3500 Hasselt',         'A+'),
('Marie',   'De Vries',    '1990-07-22', '234567890', 'marie.devries@test.be',   '0472-234567', 'Stationsplein 5, 3600 Genk',          'O+'),
('Piet',    'Bakker',      '1978-11-30', '345678901', 'piet.bakker@test.be',     '0473-345678', 'Hoogstraat 88, 3500 Hasselt',         'B+'),
('Anna',    'Smit',        '1995-01-10', '456789012', 'anna.smit@test.be',       '0474-456789', 'Marktplein 3, 3600 Genk',             'AB-'),
('Kees',    'Mulder',      '1960-05-18', '567890123', 'kees.mulder@test.be',     '0475-567890', 'Dorpsstraat 41, 3920 Lommel',         'O-'),
('Sophie',  'Visser',      '1988-09-03', '678901234', 'sophie.visser@test.be',   '0476-678901', 'Botermarkt 7, 3500 Hasselt',          'A-'),
('Tom',     'De Groot',    '2001-12-25', '789012345', 'tom.degroot@test.be',     '0477-789012', 'Laan 22, 3600 Genk',                  'B-'),
('Linda',   'Bos',         '1972-04-07', '890123456', 'linda.bos@test.be',       '0478-890123', 'Kapelstraat 15, 3500 Hasselt',        'AB+'),
('Ahmed',   'El Amrani',   '1993-06-14', '901234567', 'ahmed.elamrani@test.be',  '0479-901234', 'Nieuwstraat 9, 3600 Genk',            'O+'),
('Eva',     'Claessens',   '1982-02-28', '012345678', 'eva.claessens@test.be',   '0470-012345', 'Maastrichterstraat 33, 3500 Hasselt', 'A+');

INSERT INTO dossiers (patient_id, datum, diagnose, medicatie, arts, notities) VALUES
(1,  '2026-09-15', 'Diabetes Type 2',        'Metformine 500mg 2x/dag',    'Dr. Willems',  'HbA1c: 7.2%, voetcontrole OK'),
(1,  '2026-10-01', 'Controle diabetes',       'Metformine 500mg 2x/dag',    'Dr. Willems',  'Bloedsuiker stabiel, doorgaan'),
(2,  '2026-08-20', 'Hypertensie',             'Lisinopril 10mg 1x/dag',     'Dr. Peeters',  'Bloeddruk 155/95, medicatie gestart'),
(3,  '2026-10-10', 'Astma verergering',       'Salbutamol + Flixotide',     'Dr. Willems',  'Piepende ademhaling, longfunctie -15%'),
(4,  '2026-07-05', 'Pinda-allergie',          'EpiPen voorgeschreven',       'Dr. Peeters',  'Anafylactische reactie vorig jaar'),
(5,  '2026-10-14', 'Hartfalen NYHA II',       'Furosemide 40mg + ACE-rem',  'Dr. Janssens', 'Echo: EF 35%, vochtretentie'),
(6,  '2026-10-05', 'Chronische migraine',     'Sumatriptan 50mg bij aanval', 'Dr. Peeters',  'Meer dan 4 aanvallen/maand'),
(7,  '2026-09-20', 'Eczeem',                  'Hydrocortison crème',         'Dr. Willems',  'Armen en knieholtes, matig ernstig'),
(8,  '2026-10-12', 'Hypothyreoïdie',          'Levothyroxine 75mcg',         'Dr. Janssens', 'TSH 8.2, T4 laag-normaal'),
(9,  '2026-10-08', 'Lage rugpijn',            'Ibuprofen 400mg 3x/dag',     'Dr. Willems',  'Geen uitstraling, geen rode vlaggen'),
(10, '2026-09-30', 'Griepvaccinatie',          'Influenzavaccin 2026',        'Dr. Peeters',  'Jaarlijkse vaccinatie, geen reactie');

INSERT INTO afspraken (patient_id, datum, arts, reden, status) VALUES
(1, '2026-11-01 09:00', 'Dr. Willems',  'Controle diabetes',     'gepland'),
(2, '2026-10-25 10:30', 'Dr. Peeters',  'Bloeddruk controle',    'gepland'),
(5, '2026-10-28 14:00', 'Dr. Janssens', 'Echo hart follow-up',   'gepland'),
(3, '2026-10-22 11:00', 'Dr. Willems',  'Longfunctie hertest',   'gepland'),
(6, '2026-11-05 09:30', 'Dr. Peeters',  'Migraine evaluatie',    'gepland');

INSERT INTO medewerkers (gebruikersnaam, wachtwoord, volledige_naam, rol, email) VALUES
('dr.willems',   'welkom123',   'Dr. Sarah Willems',     'arts',     'sarah.willems@securemed.be'),
('dr.peeters',   'welkom123',   'Dr. Tom Peeters',       'arts',     'tom.peeters@securemed.be'),
('dr.janssens',  'welkom123',   'Dr. Eva Janssens',      'arts',     'eva.janssens@securemed.be'),
('receptie1',    'securemed',   'Lisa Van Damme',        'receptie', 'lisa.vandamme@securemed.be'),
('receptie2',    'securemed',   'Karim El Bakali',       'receptie', 'karim.elbakali@securemed.be'),
('admin',        'admin',       'Beheerder',             'admin',    'admin@securemed.be'),
('lab1',         'labo2026',    'Sofie Mertens',         'lab',      'sofie.mertens@securemed.be');


-- App-gebruiker (bewust te breed). Geen root@'%': die bestaat niet op een
-- Flexible Server, het beheeraccount is mysqladmin.
CREATE USER IF NOT EXISTS 'securemed_app'@'%' IDENTIFIED BY 'SecureMed2026';
GRANT ALL PRIVILEGES ON securemed.* TO 'securemed_app'@'%';
FLUSH PRIVILEGES;
