# Android-App über F-Droid aktualisieren

Jede veröffentlichte Version (Tag `v1.2.3`, siehe README → Versionen) landet
automatisch in einem eigenen F-Droid-Repo (GitHub Pages). F-Droid zeigt neue
Versionen dann wie jedes andere Update an. Stände von `main` ohne Release
kommen nicht ins Repo.

## Einrichten (einmal)

1. [F-Droid](https://f-droid.org) installieren (oder Droid-ify / Neo Store – gleiche Repos).
2. **Einstellungen → Paketquellen → +** und diese Adresse eintragen
   (am Handy: Link antippen und mit F-Droid öffnen):

   ```text
   https://daschmidt1994.github.io/ant-colony-manager/fdroid/repo?fingerprint=BBCE52863C9584F4457D932A9FC0DF7EB5872B96E1940F502C747FF57EDB8863
   ```

   Fingerabdruck des Repo-Schlüssels (SHA-256), falls F-Droid danach fragt:
   `BBCE52863C9584F4457D932A9FC0DF7EB5872B96E1940F502C747FF57EDB8863`
3. Nach dem Aktualisieren der Paketquellen „Ant Colony Manager“ suchen und installieren.

**Schon per APK aus den GitHub-Releases installiert?** Kein Neuinstallieren nötig:
F-Droid-Builds sind dieselben APKs mit demselben App-Schlüssel, F-Droid übernimmt
die vorhandene Installation samt Daten beim nächsten Update.

Die Übersichtsseite mit QR-Code zum Scannen:
https://daschmidt1994.github.io/ant-colony-manager/fdroid/repo/index.html

## Wie es funktioniert

- `.github/workflows/app.yml` baut beim Versions-Tag die APKs (eine je
  CPU-Architektur, F-Droid wählt die passende), veröffentlicht das GitHub-Release und ruft
  [`fdroid/publish.sh`](../fdroid/publish.sh) auf.
- Das Skript legt die APKs ins Repo auf dem Branch `gh-pages`, signiert den
  Index mit `fdroidserver` und behält die letzten 3 Builds.
- Konfiguration und App-Beschreibung: [`fdroid/config.yml`](../fdroid/config.yml),
  [`fdroid/metadata/`](../fdroid/metadata/).

## Schlüssel

| Secret | Inhalt |
|---|---|
| `FDROID_KEYSTORE_BASE64` | Repo-Schlüssel (PKCS12, Alias `fdroidrepo`), base64 |
| `FDROID_KEYSTORE_PASS` | Passwort dazu |
| `ANDROID_KEYSTORE_*` | App-Signaturschlüssel (unverändert, für Updates über bestehende Installationen) |

Den Repo-Schlüssel sicher aufbewahren (Passwortmanager/Backup). Geht er verloren,
bekommt das Repo einen neuen Fingerabdruck und muss auf allen Handys neu
hinzugefügt werden. Geht der **App**-Schlüssel verloren, lässt sich die App gar
nicht mehr aktualisieren, nur neu installieren.
