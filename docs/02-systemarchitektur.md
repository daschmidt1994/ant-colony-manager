# 02 – Systemarchitektur

## 1. Gesamtbild

```text
 ┌──────────── Formicarium ────────────┐
 │  NFC-Tag (NDEF-URI)   QR-Etikett    │
 │  https://ants.example.com/c/<token> │
 └───────────────┬─────────────────────┘
                 │ Tap / Scan
   ┌─────────────▼─────────────┐        ┌──────────────────────────┐
   │ Android-App (Flutter)     │        │ Browser: Web-App         │
   │  UI ─ Logik ─ Repos       │        │ (Flutter Web, gleiche    │
   │  Drift/SQLite + Outbox    │        │  Codebasis, adaptiv)     │
   │  lokale Erinnerungen      │        │  Drift-WASM-Cache        │
   └─────────────┬─────────────┘        └────────────┬─────────────┘
                 │ HTTPS  (REST /api/v1, SSE)        │
                 └──────────────┬────────────────────┘
                                │
 ┌───────────── Docker Compose (Self-Hosted) ─────────────────────┐
 │  [proxy] Caddy (optional) :443/:80  ──►  eigener Proxy ebenso  │
 │                                │                               │
 │  [app] Go-Binary :8080                                          │
 │    ├─ /api/v1/*        REST + SSE                               │
 │    ├─ /c/<token>       Scan-Einstieg (→ Web-App / App-Hinweis)  │
 │    ├─ /.well-known/assetlinks.json                              │
 │    ├─ /*               Flutter-Web-Build (eingebettet)          │
 │    └─ Jobs: Thumbnails · E-Mail-Reminder · Tombstone-GC         │
 │         │                         │                             │
 │  [db] PostgreSQL 18        ./data/uploads (Fotos)               │
 │   ./data/postgres                                               │
 │  [backup] pg_dump + rsync + Cron  ──►  ./data/backups           │
 └────────────────────────────────────────────────────────────────┘
```

## 2. Schichten (Client)

```text
Presentation   Widgets, Screens, adaptive Layouts (Phone / Tablet / Desktop)
     │         Riverpod-Provider (AsyncNotifier) – kein Business-Code in Widgets
     ▼
Application    Use-Cases: LogFeeding, RepeatLastFeeding, StartCareRound,
     │         ResolveScan, AssignNfcTag, ComputeDueTasks …
     ▼
Domain         reine Dart-Modelle (freezed), Enums, Regeln
     │         (DueCalculator, TrafficLight, WinterRestPolicy) – 100 % unit-testbar
     ▼
Data           Repositories (Interface in Domain, Implementierung hier)
     │           ├─ LocalStore (Drift DAOs)   ← UI liest nur hier
     │           ├─ Outbox                    ← jeder Schreibvorgang
     │           └─ RemoteApi (generierter OpenAPI-Client)
     ▼
Sync Engine    Push (Outbox) · Pull (Cursor) · Foto-Upload-Queue · Konfliktbehandlung
     ▼
Backend API → PostgreSQL
```

**Regel:** Ein Schreibvorgang ist *eine* lokale Transaktion: Datensatz schreiben + Outbox-Eintrag. Die UI aktualisiert sich über Drift-`watch()`-Streams sofort, unabhängig vom Netz.

## 3. Schichten (Server, Go)

```text
cmd/acm               main: serve | migrate | user | healthcheck | export
internal/http         Router, Middleware (Auth, RateLimit, RequestID, Logging, Recover)
internal/api          Handler = dünne Adapter (Validierung, DTO ↔ Domain)
internal/service      Fachlogik: colonies, events, sync, scanlinks, photos, auth, reminders
internal/authz        zentrale Berechtigungsprüfung (can(user, action, colony))
internal/store        sqlc-generierte Queries + Transaktionshelfer
internal/storage      BlobStore-Interface: FilesystemStore | S3Store
internal/jobs         Hintergrundjobs (Ticker + DB-basierte Job-Tabelle)
internal/config       ENV-Parsing + Validierung beim Start (fail fast)
migrations/           goose-SQL-Migrationen (embedded)
```

Jeder Handler, der Kolonie-Daten berührt, läuft über `authz` – es gibt keinen Codepfad an der Prüfung vorbei. Zusätzlich filtern alle Queries per `JOIN colony_members` (Defense in Depth).

## 4. Android-Architektur (Details)

| Thema | Lösung |
|---|---|
| Einstieg per NFC | `NDEF_DISCOVERED`-Intent-Filter (https, Pfad `/c/`) + Foreground-Reader-Mode, wenn App offen (siehe 06) |
| Einstieg per QR | In-App-Scanner (`mobile_scanner`), Android-Kamera → App Link bzw. Web-Fallback |
| Start-Performance | Route `/c/:token` wird *vor* dem Laden des Dashboards aufgelöst; Token → Kolonie aus lokaler DB (offline) |
| Hintergrund-Sync | `workmanager` periodisch (15 min, nur mit Netz) + nach jedem Schreibvorgang (Debounce 2 s) + bei Konnektivitätswechsel + App-Resume |
| Erinnerungen | nach jedem Sync/Schreibvorgang neu berechnet, per `flutter_local_notifications` geplant |
| Server-Verbindung | Onboarding: Server-URL eingeben **oder QR-Code aus der Web-App scannen** („Android-App verbinden“ → enthält URL + einmaligen Login-Code) |
| Mehrere Server/Accounts | vorbereitet (DB-Datei pro Server+User), MVP: einer |
| Sicherheit lokal | Refresh-Token im Keystore; SQLite optional verschlüsselt (SQLCipher) – MVP: nein, Android-App-Sandbox |

### Erinnerungen ohne Push-Dienst
Die Fälligkeiten stehen vollständig in der lokalen DB. Die App berechnet sie selbst und plant lokale Benachrichtigungen:
- **Tages-Digest** zu einer wählbaren Uhrzeit (Default 18:00): „7 Kolonien brauchen heute Aufmerksamkeit (3 überfällig)“ – verhindert Benachrichtigungsflut bei 100 Kolonien.
- **Einzelbenachrichtigungen** optional nur für *überfällige* Aufgaben, gruppiert (Android Notification Groups).
- Aktionen: **[Erledigt]** (schreibt Event im Hintergrund-Isolate direkt in Drift + Outbox) und **[Kolonie öffnen]**.
- Inexakte Alarme (kein `SCHEDULE_EXACT_ALARM` nötig), Neuplanung nach Reboot (`RECEIVE_BOOT_COMPLETED`).
- Server-seitig optional: **E-Mail-Digest** über SMTP (für Web-only-Nutzer). Später optional **UnifiedPush/ntfy** (self-hosted).

## 5. Web-Architektur (Details)

Gleiche App, andere Layouts ab Breakpoint ≥ 900 px:
- `NavigationRail` statt Bottom-Navigation, Master-Detail (Liste links, Kolonie rechts).
- Kolonieliste als sortier-/filterbare Tabelle mit Mehrfachauswahl (Massen-Aktionen: Standort ändern, Etiketten drucken, Status setzen).
- Admin-Bereich (nur Web): Benutzer, Einladungen, Backup-Status, Instanz-Einstellungen.
- NFC-Funktionen im Web ausgeblendet (Web NFC nur Chrome Android – bewusst nicht genutzt), QR-Scan per Webcam möglich.
- Service Worker cached App-Shell → zweiter Aufruf lädt sofort.

## 6. Realtime

- `GET /api/v1/sync/events` (SSE) sendet nur `{"seq": 1234}`, wenn sich für den Nutzer etwas geändert hat.
- Client reagiert mit einem normalen Pull. Kein Datenversand über SSE → keine zweite Berechtigungslogik.
- Android nutzt SSE nur im Vordergrund; Hintergrund = WorkManager.

## 7. Fälligkeiten & Ampel (zentrale Domänenlogik)

```text
next_due = letzte passende Aktion.occurred_at + Intervall
           (falls keine Aktion: schedule.starts_at)
Winterruhe aktiv:  mode=pause   → keine Fälligkeit
                   mode=scale   → Intervall × Faktor (z. B. 4)
Ampel:  🔴 next_due < heute (in User-Zeitzone)
        🟡 next_due ≤ heute + Vorwarnzeit (Default 1 Tag)
        🟢 sonst
Gruppen: ÜBERFÄLLIG · HEUTE · MORGEN · DIESE WOCHE · SPÄTER
```

Fälligkeiten werden **berechnet, nicht gespeichert** – dadurch sind sie offline stets konsistent und es gibt keine „veralteten“ Aufgaben nach einem Sync. Die gleiche Regel existiert im Server (SQL-View) nur für den E-Mail-Digest; ein gemeinsamer Satz Testfälle (`test-vectors/due.json`) stellt sicher, dass Dart und Go identisch rechnen.

## 8. Pflege-Rundgang (Ablauf)

```text
[Rundgang starten]  optional: Standort-Filter (z. B. „Regal A“) → Soll-Liste
      ↓
Scan (NFC/QR, Reader-Mode dauerhaft aktiv)  ──► Kolonie-Karte: Ampel + Quick Actions
      ↓ 1–2 Taps                                (Fütterung wiederholen, Wasser, Reinigung, Kontrolle …)
[Nächste Kolonie scannen]  (Haptik + Ton bei Scan; bereits besuchte Kolonie → Hinweis)
      ↓ …
[Beenden] → Zusammenfassung: 28/30 kontrolliert · 24 gefüttert · 18 Wasser · 6 gereinigt
            + Liste der nicht gescannten Kolonien (antippbar → manuell öffnen)
```

Alle während des Rundgangs erfassten Events tragen `care_round_id` → die Zusammenfassung ist eine einfache Abfrage und funktioniert komplett offline.
