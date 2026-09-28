# Testinstanz und Test-App

Neue Stände erst an einer zweiten Installation ausprobieren, bevor sie zur
echten kommen. Datenbank-Migrationen lassen sich nicht zurückdrehen: Ein
älteres Image auf einer schon migrierten Datenbank ist keine Rückfahrkarte,
nur ein Backup ist eine. Deshalb zuerst an einer Kopie testen.

| | Echte Installation | Testinstanz |
|---|---|---|
| Stand | Versionen (Tag `v1.2.3`) | jeder Push auf `main` |
| Docker-Image | `latest` (oder feste Version) | `edge` |
| Domain | z. B. `ants.example.com` | z. B. `test.ants.example.com` |
| Daten | eigener `DATA_DIR` | eigener `DATA_DIR` |
| Android-App | **Ant Colony Manager** (`at.antcolony.manager`) | **ACM Test** (`at.antcolony.manager.dev`, Banner „TEST“) |
| F-Droid | gleiches Repo | gleiches Repo |

Beide Apps sind gleichzeitig installiert, jede spricht mit ihrem eigenen Server.

## Ablauf einer Änderung

1. Arbeiten auf einem Branch → Pull Request → Merge auf `main`.
2. Die CI baut das Image `edge` und die App **ACM Test** und legt sie ins F-Droid-Repo.
3. Testinstanz aktualisieren (Dockhand: **Pull** + **Redeploy**), ACM Test in F-Droid aktualisieren, ausprobieren.
4. Passt alles: `./scripts/release.sh 1.3.0` → Tag → echte Installation und echte App bekommen das Update.

Geht auf der Testinstanz etwas schief, ist nichts verloren: Stack stoppen,
`DATA_DIR` der Testinstanz leeren, neu starten.

## Testinstanz anlegen (Dockhand/Portainer)

Dieselbe Datei wie für die echte Installation: [`deploy/docker-compose.yml`](../deploy/docker-compose.yml).

1. Dockhand → **Stacks** → **Neuer Stack**, Name `ant-colony-manager-test`, Inhalt der Compose-Datei einfügen.
2. Umgebungsvariablen des Stacks setzen (die Datei bleibt unverändert):

   | Variable | Wert (Beispiel) | Warum |
   |---|---|---|
   | `STACK_NAME` | `ant-colony-manager-test` | eigene Container und Netzwerke |
   | `ACM_VERSION` | `edge` | Stand von `main` |
   | `APP_PORT` | `8481` | anderer Port als die echte Installation |
   | `DATA_DIR` | `/mnt/user/appdata/ant-colony-manager-test` | **eigener** Ordner – nie den der echten Installation! |
   | `PUBLIC_APP_URL` | `https://test.ants.example.com` | Test-Domain (QR-Codes und NFC-Tags zeigen hierhin) |
   | `ANDROID_APP_ID` | `at.antcolony.manager.dev` | App Links für ACM Test |
   | `INSTANCE_NAME` | `ACM Test` | erkennbar im Browser |
   | `ANDROID_CERT_SHA256` | wie bei der echten Installation | gleicher App-Schlüssel |

3. Starten, im Log von **app** den Setup-Code suchen, `<PUBLIC_APP_URL>/setup` öffnen, Admin-Konto anlegen.
4. Test-Domain im Reverse Proxy auf `APP_PORT` zeigen lassen (wie bei der echten Installation).

Backups laufen in der Testinstanz genauso (in ihren eigenen `DATA_DIR`).

## Test-App installieren

In F-Droid ist das Repo schon eingetragen ([18-fdroid.md](18-fdroid.md)). Nach
dem ersten Push auf `main`, der die App betrifft, erscheint dort zusätzlich
**ACM Test**. Installieren, als Server die Test-Domain eintragen, anmelden.

**Optional – QR-Codes mit der Handykamera direkt in ACM Test öffnen (App Links):**
GitHub → Repository → **Settings → Secrets and variables → Actions → Variables** →
`APP_LINK_HOST_DEV` = Test-Domain (ohne `https://`). Gegenstück zu
`APP_LINK_HOST` der echten App. Ohne die Variable funktioniert alles, der
Kamera-Scan fragt dann nur, mit welcher App der Link geöffnet werden soll.

## Echte Daten in der Testinstanz

Am aussagekräftigsten ist ein Test mit einer Kopie deiner echten Daten (vor
allem bei Migrationen). Dafür einen Backup-Ordner aus
`<DATA_DIR echt>/backups/` nach `<DATA_DIR test>/backups/` kopieren und in
der Testinstanz wiederherstellen, wie in [09-backup-restore.md](09-backup-restore.md)
beschrieben. Die Testinstanz hat eigene Schlüssel: nach dem Restore in ACM
Test neu anmelden. E-Mail (`SMTP_*`) in der Testinstanz leer lassen, sonst
bekommen Nutzer doppelte Tagesüberblicke.
