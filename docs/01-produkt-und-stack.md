# 01 – Produkt & Technologie-Stack

## 1. Kurz-PRD

### Problem
Ameisenhalter mit 10–150 Kolonien dokumentieren heute in Excel, Notizen oder auf Papier. Das ist langsam, am Formicarium unpraktisch und liefert keine Übersicht, was fällig ist.

### Ziel
Am Formicarium in **< 5 Sekunden** vom Scan zur dokumentierten Aktion. Bei einem Pflege-Rundgang über 30 Kolonien soll die Dokumentation pro Kolonie **≤ 2 Taps** kosten (plus Scan).

### Zielgruppen / Rollen
| Rolle | Beschreibung |
|---|---|
| Halter (Owner) | Besitzt Kolonien, voller Zugriff |
| Helfer (Editor) | Familienmitglied/Urlaubsvertretung, darf dokumentieren |
| Betrachter (Viewer) | Nur lesen |
| Instanz-Admin | Betreibt den Server, verwaltet Benutzer/Backups (sieht **nicht** automatisch fremde Kolonien) |

### Erfolgskriterien (messbar)
| Kriterium | Ziel |
|---|---|
| NFC-Tap (App im Hintergrund) → Kolonie sichtbar | < 1,5 s |
| Kaltstart per NFC → Kolonie sichtbar | < 3 s |
| „Letzte Fütterung wiederholen“ | 1 Tap |
| Wasser / Reinigung (Standardart) | 1 Tap, Details optional |
| Suche über 500 Kolonien | < 100 ms (lokal) |
| Offline erfasste Fütterung auf dem Server | genau 1× |
| Installation (versierter Nutzer) | < 10 min |
| Idle-RAM Serverseite (app + db) | < 300 MB (Raspberry Pi 4 tauglich) |

### Nicht-Ziele (MVP)
Sensor-Hardware-Integration (nur API vorbereitet), PDF-Koloniebericht, Social/öffentliche Profile, Marktplatz, iOS-Build (Architektur vorbereitet), Mehrsprachigkeit über DE hinaus (vorbereitet).

### MVP-Umfang
Entspricht Abschnitt 54 der Anforderungen (27 Punkte). Zusätzlich im Datenmodell bereits angelegt (ohne volle UI): Königinnen, Koloniegröße, Brut, Nester, Standorte, Winterruhe, Sensoren, Pflege-Rundgang.

---

## 2. Technologie-Stack (Entscheidung)

| Bereich | Wahl | Grund |
|---|---|---|
| **Mobile** | Flutter 3.x (stable), Dart 3 | Vorgabe, iOS später ohne Neuentwicklung |
| State / DI | Riverpod 2 (mit Codegen) | testbar, keine BuildContext-Abhängigkeit in der Logik |
| Routing / Deep Links | go_router | deklarative Routen, `/c/:token` identisch in App und Web |
| Lokale DB | SQLite über das Paket `sqlite3` (Web: WASM + IndexedDB) | eigene dünne Schicht mit reaktiven Queries; **Änderung in Phase 5:** Drift wurde verworfen, weil sein Codegenerator mit 900 MB Speicher nicht fertig wurde und bei drei Tabellen kaum Nutzen bringt |
| NFC | `nfc_manager` | NDEF lesen/schreiben, Tag-UID, Android + iOS |
| QR-Scan | `mobile_scanner` (ML Kit, gebündelt) | schnell, Android + Web |
| QR/PDF-Erzeugung | `qr`/`barcode` + `pdf` + `printing` | Etiketten clientseitig, kein Server-Renderer nötig |
| HTTP | `dio` + aus OpenAPI generierter Client | Interceptors für Token-Refresh/Retry |
| Secure Storage | `flutter_secure_storage` | Refresh-Token im Android Keystore |
| Benachrichtigungen | `flutter_local_notifications` + `workmanager` | lokal geplante Erinnerungen, kein FCM nötig |
| Bilder | `image_picker` + `flutter_image_compress` | Kompression vor Upload |
| Charts (später) | `fl_chart` | ausreichend, schlank |
| **Web** | **Flutter Web (WASM-Build)** | siehe Abschnitt 3 |
| **Backend** | **Go 1.26+**, `chi` Router, `pgx/v5`, handgeschriebenes SQL, eingebauter Migrations-Runner | siehe Abschnitt 4 (Stand Phase 3) |
| API-Vertrag | OpenAPI 3.1 (`api/openapi.yaml`) | Single Source of Truth; ein Test prüft, dass jede Server-Route dokumentiert ist; Dart-Client wird daraus generiert |
| Datenbank | PostgreSQL 18 | `uuidv7()` nativ, stabil, ARM64-Images |
| Dateispeicher | lokales Volume (Default), S3-kompatibel optional | kein Extra-Container nötig |
| Realtime | Server-Sent Events (SSE) | nur „es gibt Änderungen“-Signal, durch jeden Proxy, kein WS-Protokoll |
| Reverse Proxy | Caddy 2 (optional im Compose) | automatisches HTTPS, 5-Zeilen-Config; Traefik/Nginx dokumentiert |
| Backup | eigenes schlankes Image (Alpine + `pg_dump` + `supercronic` + `rsync`) | Cron im Container, Hardlink-Inkremente |
| CI | GitHub Actions / Forgejo Actions | Multi-Arch-Images via `buildx`, APK-Build |

---

## 3. Web: Flutter Web statt Next.js – Begründung

**Entscheidung: Flutter Web** als einzige Web-Oberfläche, mit adaptivem Desktop-Layout.

| Kriterium | Flutter Web | Next.js/React (separat) |
|---|---|---|
| Codebasis | **eine** – Modelle, Fälligkeitslogik, Timeline, Formulare, Sync geteilt | zwei UIs, Domänenlogik doppelt (Dart + TS) |
| Wartung für Einzelentwickler/Hobbyprojekt | **niedrig** | deutlich höher (2 Toolchains, 2 Designsysteme) |
| Konsistenz Android ↔ Web | automatisch | manuell |
| Datentabellen, Filter | gut (`data_table_2`, eigene Widgets) | sehr gut (TanStack Table) |
| Erste Ladezeit | 1,5–3 MB, danach gecacht (Service Worker) | klein |
| SEO | irrelevant (private App) | – |
| Drucken / PDF | über `pdf`-Paket identisch zu Android | Browser-Druck |
| Text markieren/Browser-Feeling | eingeschränkt, `SelectionArea` hilft | nativ |

Der entscheidende Punkt ist, dass sämtliche fachliche Logik (Fälligkeitsberechnung, Ampel, „Fütterung wiederholen“, Pflege-Rundgang, Sync-Engine) nur **einmal** existiert. Die Schwächen von Flutter Web (Ladezeit, Tabellen-Ergonomie) sind für eine private Verwaltungs-App akzeptabel.

**Ausstiegspfad:** Da die API vollständig per OpenAPI beschrieben ist, kann später jederzeit eine separate React-Admin-Oberfläche ergänzt werden, ohne Backend-Änderungen.

**Web-Datenhaltung:** Web nutzt dieselbe Repository-Schicht. Drift läuft im Browser (sqlite3.wasm auf OPFS bzw. IndexedDB) als Cache mit Sync. Fällt das im Browser aus (z. B. privater Modus), greift automatisch eine reine Online-Implementierung desselben Repository-Interfaces.

---

## 4. Backend: eigenes Go-Backend statt Supabase – Begründung

**Supabase self-hosted** besteht aus ~10–13 Containern (Kong, GoTrue, PostgREST, Realtime, Storage, imgproxy, Studio, Meta, Analytics/Logflare, Vector …), braucht 2–4 GB RAM und ist auf ARM-NAS-Systemen mühsam. Updates erfordern das Nachziehen mehrerer Komponenten. Für ein „`docker compose up -d` auf dem Raspberry Pi“-Projekt ist das zu schwer.

**Eigene API in Go:**
- **Ein statisches Binary**, distroless-Image ~20–30 MB, Idle-RAM ~20 MB.
- Trivialer Cross-Compile für `linux/amd64` und `linux/arm64` (kein QEMU-Build nötig).
- Liefert API **und** Flutter-Web-Build (`embed`) aus → ein Container weniger, keine CORS-Probleme.
- Migrationen eingebettet und beim Start automatisch (mit Advisory-Lock).
- Hintergrundjobs (Thumbnails, E-Mail-Erinnerungen, Tombstone-Bereinigung) als Goroutinen → kein Redis/Worker-Container.
- Echtes SQL mit `pgx` → Schema bleibt „normales“ PostgreSQL, kein ORM-Lock-in.

> **Änderung in Phase 3:** Statt `sqlc` und `goose` werden handgeschriebene `pgx`-Queries und ein ~100 Zeilen kleiner, eingebetteter Migrations-Runner (Advisory-Lock, eine Transaktion pro Migration) verwendet. Grund: Die generische Sync-Engine baut Spaltenlisten dynamisch aus einer Whitelist, die dynamischen Filter der Kolonieliste lassen sich mit `sqlc` schlecht abbilden, und `goose` zerlegt die PL/pgSQL-Funktionen des Schemas falsch. Ergebnis: weniger Werkzeuge im Build.

**Alternative**, falls du Go nicht möchtest: TypeScript mit Fastify + Kysely. Funktioniert, aber größeres Image (~150 MB), mehr RAM, Abhängigkeitspflege über npm.

**Warum nicht Dart im Backend (Shared Code mit Flutter)?** Das Server-Ökosystem (Auth, Bildverarbeitung, Migrationstools) ist dünner; der geteilte Code wäre im Wesentlichen DTOs, und die entstehen ohnehin aus OpenAPI.

---

## 5. Architekturprinzipien

1. **Monolith mit klaren Modulen**, keine Microservices.
2. **Offline-first auf dem Client**: UI liest *immer* aus der lokalen DB, schreibt *immer* lokal + Outbox. Netzwerk ist ein Hintergrunddetail.
3. **Server ist die autoritative Wahrheit** für Berechtigungen und Reihenfolge (`server_seq`).
4. **Keine Pflicht-Abhängigkeit zu Drittanbietern**: kein Firebase, kein Google-Login-Zwang, kein CDN (Fonts/Icons gebündelt).
5. **Konfiguration nur über ENV**, keine URL/Secrets im Code; die App fragt beim ersten Start nach der Server-URL.
6. **Daten gehören dem Nutzer**: jederzeit Export (JSON/CSV/Fotos), Backups sind normale Dateien (`pg_dump` + Ordner).
