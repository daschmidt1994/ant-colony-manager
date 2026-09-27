# Installation auf Unraid mit Dockhand

Unraid bringt im Terminal kein `docker compose` mit. Das ist kein Problem: **Dockhand** startet den Stack selbst. Im Terminal wird nur einmal die Konfiguration (`.env`) angelegt.

## 1. Vorbereitung

- Die Docker-Images müssen ohne Anmeldung ladbar sein. Auf GitHub: Profil → **Packages** → `ant-colony-manager` → **Package settings** → **Change visibility** → **Public**; dasselbe für `ant-colony-manager-backup`.
  Alternativ in Dockhand unter den Registry-Einstellungen `ghcr.io` mit Benutzer `daschmidt1994` und einem GitHub-Token mit dem Recht `read:packages` eintragen.
- Freien Port wählen: `8080` ist auf Unraid oft schon belegt (Docker-Tab → Spalte „Port Mappings“). Im Folgenden steht `8080`, bei Bedarf z. B. `8480` nehmen.

## 2. Dateien holen und `.env` anlegen

Im Unraid-Terminal im Stack-Ordner von Dockhand:

```bash
cd /mnt/user/appdata/dockhand/stacks/unraid_zuhause/ant-colony-manager
git pull                      # falls der Ordner schon geklont ist; sonst git clone … .
./scripts/init-env.sh
```

Das Skript erkennt Unraid und setzt `PUID=99`, `PGID=100` (nobody:users). Danach `.env` anpassen:

```bash
nano .env
```

| Zeile | Wert auf Unraid |
|---|---|
| `PUBLIC_APP_URL` | `http://<IP des Unraid-Servers>:8080` – prüfen, ob die richtige IP eingetragen ist (nicht die eines Docker-Netzes) |
| `APP_PORT` | `8080` oder der freie Port aus Schritt 1 (dann auch in `PUBLIC_APP_URL`) |
| `DATA_DIR` | `/mnt/user/appdata/ant-colony-manager` – mit Cache-Pool besser `/mnt/cache/appdata/ant-colony-manager` (die Datenbank läuft direkt auf dem Cache schneller und zuverlässiger) |
| `TZ` | `Europe/Vienna` bzw. deine Zeitzone |

Wichtig ist ein **absoluter Pfad** bei `DATA_DIR`. Er hängt nicht davon ab, wo Dockhand den Stack ausführt, und die Daten liegen getrennt von den Programmdateien im Appdata-Share. Den Ordner vorher anlegen:

```bash
mkdir -p /mnt/user/appdata/ant-colony-manager    # bzw. /mnt/cache/appdata/…
```

## 3. Stack in Dockhand starten

1. Dockhand öffnen → Umgebung **unraid_zuhause** → **Stacks**.
2. Der Stack **ant-colony-manager** sollte mit der `compose.yml` aus dem Ordner erscheinen. Falls nicht: **Stack anlegen/importieren**, Name `ant-colony-manager`, als Compose-Datei die `compose.yml` aus diesem Ordner wählen.
3. **Deploy/Start**. Beim ersten Mal werden die Images geladen (einige Hundert MB).
4. Nach etwa einer Minute sollten `db`, `app` und `backup` als **healthy** angezeigt werden; `init` ist beendet (Exit 0) – das ist richtig so.

## 4. Admin-Konto anlegen

1. In Dockhand beim Container **app** die **Logs** öffnen und nach `Setup-Code` suchen.
2. Im Browser `http://<Unraid-IP>:8080/setup` öffnen, Code eingeben, Konto anlegen.

Weiter geht es mit Schritt 2 der Anleitung [16-anleitung-installieren-testen.md](16-anleitung-installieren-testen.md) (Android-App).

## Aktualisieren

1. Im Stack-Ordner `git pull` (neue `compose.yml`, falls geändert).
2. In Dockhand beim Stack **Pull** bzw. **Update/Redeploy**. Die Daten in `DATA_DIR` bleiben unverändert; Datenbank-Migrationen laufen beim Start automatisch.

## Backups

Der `backup`-Container sichert täglich um 03:00 nach `DATA_DIR/backups`. Den Appdata-Ordner zusätzlich mit dem üblichen Unraid-Backup (z. B. „Appdata Backup“-Plugin) sichern – aber **nicht** den laufenden `postgres`-Ordner als Ersatz für die Datenbank-Sicherung verstehen; maßgeblich sind die Dateien in `backups/`.

## Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| `denied` / Image kann nicht geladen werden | Packages nicht öffentlich und keine Registry-Anmeldung in Dockhand (Schritt 1). Ohne fertige Images würde gebaut – das braucht deutlich mehr als 1 GB RAM und dauert lange. |
| `init` endet mit Fehler, Rechte-Probleme | `DATA_DIR` existiert nicht oder liegt auf einem Pfad ohne Schreibrechte; `PUID=99`, `PGID=100` prüfen. |
| `backup` meldet, dass `/config/.env` fehlt oder ein Ordner ist | Dockhand führt Compose in einem anderen Pfad aus als dem Unraid-Ordner. Melden – dann wird der Pfad angepasst. |
| Port schon belegt | `APP_PORT` und `PUBLIC_APP_URL` auf einen freien Port ändern, Stack neu starten. |
| Handy erreicht den Server nicht | Im Handy-Browser `http://<Unraid-IP>:8080` testen; gleiches WLAN, kein Gäste-WLAN. |
