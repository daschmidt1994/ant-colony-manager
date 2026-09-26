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
- Release-Builds sind derzeit mit dem Debug-Schlüssel signiert (zum Testen per Sideload). Für eine dauerhaft installierte App und verifizierte App Links wird ein eigener Signaturschlüssel eingerichtet (Phase 6).
