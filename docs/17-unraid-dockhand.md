# Installation auf Unraid mit Dockhand (oder Portainer)

Es gibt eine **fertige Compose-Datei** zum Einfügen: kein Git-Klon, keine `.env`-Datei, kein Skript, kein Bauen.

- Datei im Repo: [`deploy/docker-compose.yml`](../deploy/docker-compose.yml)
- Fester Download (immer die neueste): <https://github.com/daschmidt1994/ant-colony-manager/releases/latest/download/docker-compose.yml>

## 1. Vorbereitung

- **Docker-Images öffentlich machen** (einmalig, sonst meldet Dockhand `denied`): GitHub → Profil → **Packages** → `ant-colony-manager` → **Package settings** → **Change visibility** → **Public**; dasselbe für `ant-colony-manager-backup`.
  Alternativ in Dockhand unter den Registries `ghcr.io` mit Benutzer `daschmidt1994` und einem Token mit `read:packages` eintragen.
- **Freien Port** wählen: `8080` ist auf Unraid oft belegt (Docker-Tab → „Port Mappings“). Beispiel unten: `8480`.
- **Datenordner** anlegen (Unraid-Terminal):
  ```bash
  mkdir -p /mnt/user/appdata/ant-colony-manager
  ```
  Mit Cache-Pool besser `/mnt/cache/appdata/ant-colony-manager` – die Datenbank läuft dort schneller und zuverlässiger.

## 2. Stack in Dockhand anlegen

1. Dockhand → Umgebung (z. B. **unraid_zuhause**) → **Stacks** → **Neuer Stack**, Name `ant-colony-manager`.
2. Den Inhalt von `docker-compose.yml` in den Editor einfügen.
3. Oben im Block **EINSTELLEN** bzw. als Umgebungsvariablen des Stacks setzen:

   | Variable | Beispiel | Bedeutung |
   |---|---|---|
   | `PUBLIC_APP_URL` | `http://192.168.1.10:8480` | IP des Unraid-Servers + Port – so erreichen Handy und Browser den Server, daraus entstehen auch die QR-/NFC-Links |
   | `APP_PORT` | `8480` | derselbe Port wie in der URL |
   | `DATA_DIR` | `/mnt/user/appdata/ant-colony-manager` | der Ordner aus Schritt 1 (absoluter Pfad) |

   Direkt in der Datei heißt das: den Wert hinter `:-` ändern, z. B.
   `PUBLIC_APP_URL: ${PUBLIC_APP_URL:-http://192.168.1.10:8480}` – **an allen Stellen**, an denen `APP_PORT` bzw. `DATA_DIR` vorkommt. Einfacher sind die Umgebungsvariablen des Stacks: dann bleibt die Datei unverändert.
4. **Deploy/Start**. Beim ersten Mal lädt Docker die Images (einige Hundert MB).
5. Nach etwa einer Minute: `db`, `app`, `backup` **healthy**; `init` ist beendet (Exit 0) – richtig so.

Die Voreinstellungen passen für Unraid (`PUID=99`, `PGID=100`, Daten unter `/mnt/user/appdata/…`). Auf anderen Systemen `PUID`/`PGID` auf den Besitzer des Datenordners setzen (meist `1000`).

## 3. Admin-Konto anlegen

1. In Dockhand beim Container **app** die **Logs** öffnen und den **Setup-Code** suchen.
2. `<PUBLIC_APP_URL>/setup` im Browser öffnen, Code eingeben, Konto anlegen.

Weiter mit der Android-App: Schritt 2 in [16-anleitung-installieren-testen.md](16-anleitung-installieren-testen.md).

## Optionale Einstellungen

Alle im Block `x-settings` der Datei, z. B. E-Mail (`SMTP_*`) für „Passwort vergessen“ und den Tages-Überblick per Mail, `REGISTRATION_MODE` (`invite` = nur mit Einladung) oder die Backup-Aufbewahrung. Die Schlüssel (Datenbank-Passwort, JWT, Instanz-Schlüssel) werden beim ersten Start automatisch in `DATA_DIR/secrets` erzeugt.

## Aktualisieren

In Dockhand beim Stack **Pull** + **Redeploy**. Die Daten in `DATA_DIR` bleiben erhalten, Datenbank-Migrationen laufen beim Start automatisch. Hat sich die Compose-Datei selbst geändert (steht dann in den Release-Notizen), den neuen Inhalt einfügen und die eigenen Werte übernehmen.

## Backups

Täglich um 03:00 nach `DATA_DIR/backups` (Datenbank-Dump + Fotos, geprüft). Den Appdata-Ordner zusätzlich wie gewohnt sichern; für die Datenbank maßgeblich sind die Dateien in `backups/`, nicht der laufende `postgres`-Ordner.

Sicherung sofort auslösen: in Dockhand eine Konsole im Container **backup** öffnen und `/app/entrypoint.sh backup` ausführen.

## Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| `denied` beim Laden der Images | Packages nicht öffentlich und keine Registry-Anmeldung in Dockhand (Schritt 1). |
| `init` endet mit Fehler | `DATA_DIR` existiert nicht oder ist nicht beschreibbar. |
| `app` bleibt *unhealthy* | Logs von `app` ansehen – bei „configuration invalid“ steht die fehlerhafte Einstellung dabei (meist `PUBLIC_APP_URL` ohne `http://`). |
| Port schon belegt | `APP_PORT` und `PUBLIC_APP_URL` ändern, Stack neu starten. |
| Handy erreicht den Server nicht | Im Handy-Browser `PUBLIC_APP_URL` öffnen; gleiches WLAN, kein Gäste-WLAN. |

## Alternative: mit Git-Klon

Wer lieber mit dem ganzen Repository arbeitet (z. B. für HTTPS mit Caddy): Repo in den Stack-Ordner klonen, `./scripts/init-env.sh` ausführen (funktioniert auch ohne `docker compose` und setzt auf Unraid `PUID=99`/`PGID=100`), `.env` anpassen und die `compose.yml` des Repos als Stack verwenden.
