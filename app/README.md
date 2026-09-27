# Ant Colony Manager – App (Android + Web)

Eine Flutter-Codebasis für die Android-App und die Web-App. Offline-first: Die Oberfläche liest und schreibt ausschließlich die lokale SQLite-Datenbank; die Synchronisierung läuft im Hintergrund.

## Architektur

```text
features/*          Screens (Riverpod-Provider, keine Fachlogik in Widgets)
app/providers.dart  reaktive Abfragen: db.watch(() => repo.colonies()) …
data/repositories   ColonyRepository – Lesen + Schreiben (Datensatz + Outbox in einer Transaktion)
data/sync           SyncEngine – Push (Outbox, idempotent) → Pull (Cursor) → Snapshot bei Bedarf
data/local          AppDatabase – dünne Schicht über SQLite (sqlite3; Web: WASM + IndexedDB)
domain              Modelle (Sicht auf Server-JSON), Fälligkeiten/Ampel (= Go-Server, gleiche Test-Vektoren)
core                API-Client (Token-Refresh), Sitzung/Anmeldung
```

Die lokale Datenbank hat drei Tabellen: `records` (jede Server-Zeile als JSON + indizierte Spalten), `outbox` (ausstehende Operationen mit `op_id`) und `meta`. Das entspricht der generischen Sync-Engine des Servers – neue Server-Felder brauchen keine App-Migration. Fälligkeiten werden per SQLite-JSON-Funktionen direkt in der Datenbank ausgewertet.

**Warum kein Drift?** Drift braucht einen Codegenerator (`build_runner`), der mit 900 MB Speicher nicht fertig wurde. Bei drei Tabellen mit handgeschriebenem SQL bringt er wenig; die reaktiven Abfragen stellt `AppDatabase.watch()` bereit.

## Bauen und testen

Die CI (`.github/workflows/app.yml`) führt bei jedem Push aus: Formatierung, `flutter analyze`, alle Tests, Web-Build (WASM), APK-Build und einen **Vertragstest gegen den echten Go-Server**. Die fertige APK liegt als Artefakt am Workflow-Lauf.

Lokal (Flutter 3.44):

```bash
cd app
flutter pub get
./tool/fetch_web_assets.sh          # sqlite3.wasm für die Web-App
flutter test
flutter run -d chrome --web-port 8081   # gegen einen laufenden Server: siehe unten
flutter build apk --release
```

Ohne lokale Flutter-Installation: `scripts/flutter.sh flutter test` (Container, Speicher begrenzt – für große Builds zu wenig auf kleinen Rechnern, dort die CI nutzen).

Web-App gegen die Entwicklungsumgebung: `docker compose -f compose.yml -f compose.dev.yml up`, dann `flutter build web` und `app/build/web` nach `server/internal/webui/dist` kopieren – oder das Server-Image mit `ACM_WEB_BUILD=flutter` bauen (Standard).

Vertragstest lokal: Server starten, dann
`ACM_TEST_SERVER=http://localhost:8080 ACM_TEST_SETUP_TOKEN=<Code> flutter test test/server_contract_test.dart`.

## Android

- App-ID `at.antcolony.manager` (passt zu `ANDROID_APP_ID` des Servers)
- `usesCleartextTraffic` ist aktiv, damit Server im Heimnetz per `http://192.168.x.x` funktionieren
- Berechtigungen: Internet, NFC, Kamera – NFC und Kamera sind optional (ohne geht die Code-Eingabe)

### NFC & QR (Phase 6)

| Situation | Was passiert |
|---|---|
| App offen, Tag antippen | Reader-Modus: Kolonie öffnet sich sofort, von jedem Screen aus |
| App im Hintergrund/geschlossen, Tag antippen | Android startet die App direkt über den Link auf dem Tag (`NDEF_DISCOVERED`, jede Domain, auch `http://`) |
| QR in der App scannen | Scan-Tab mit Kamera; Auflösung offline über die lokale Datenbank |
| QR mit der Kamera-App | Standard-APK: Web-Seite → „In der App öffnen“. Eigene APK mit Domain: direkt (verifizierter App Link) |
| „Android-App verbinden“ | Anmeldeseite → „QR-Code aus der Web-App scannen“ – kein Passwort nötig |

Tags werden mit einem NDEF-URI-Record `https://<PUBLIC_APP_URL>/c/<code>` beschrieben, nach dem Schreiben zurückgelesen und geprüft. Zusätzlich wird die Seriennummer als `HMAC-SHA256(Instanz-Schlüssel, UID)` gespeichert; dadurch werden auch schreibgeschützte oder überschriebene Tags erkannt, solange die App offen ist. Die Logik ist hardwareunabhängig getestet (`test/nfc_labels_test.dart`).

### Signatur und App Links

Release-APKs aus der CI sind mit einem eigenen Schlüssel signiert (GitHub-Secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`). **Der Schlüssel muss gesichert werden** – ohne ihn lassen sich Updates nicht über eine installierte App installieren.

Zertifikat-Fingerabdruck (SHA-256) für die Server-Variable `ANDROID_CERT_SHA256`:

```
AB:81:47:A3:DA:FF:D6:2E:82:F1:D3:1F:1F:E1:1A:E6:DC:FE:87:08:1D:E5:78:70:9B:4F:1B:E2:1B:C7:45:FD
```

**Verifizierte App Links** (QR mit der Kamera-App öffnet direkt die App):
1. `.env` des Servers: `ANDROID_CERT_SHA256=AB:81:47:A3:DA:FF:D6:2E:82:F1:D3:1F:1F:E1:1A:E6:DC:FE:87:08:1D:E5:78:70:9B:4F:1B:E2:1B:C7:45:FD` → `https://<domain>/.well-known/assetlinks.json` liefert die Freigabe (HTTPS Pflicht).
2. APK mit Domain bauen: GitHub → Actions → „App“ → *Run workflow* → `app_link_host = ants.example.com` (oder Repo-Variable `APP_LINK_HOST` setzen).
3. Lokal: `flutter build apk --release -PappLinkHost=ants.example.com` mit `android/key.properties` (Vorlage siehe CI-Workflow).
