# 04 – API-Struktur

- **REST/JSON**, Basis `/api/v1`, beschrieben in `api/openapi.yaml` (OpenAPI 3.1). GraphQL bringt hier keinen Vorteil – der Client liest ohnehin aus der lokalen DB, das Backend liefert primär Sync-Deltas.
- Auth: `Authorization: Bearer <access-token>` (JWT, 15 min). Sensoren: `Authorization: Bearer acm_sk_<prefix>_<secret>`.
- Fehlerformat: RFC 9457 `application/problem+json` mit `code` (maschinenlesbar, z. B. `colony.not_found`).
- Idempotenz: alle schreibenden Nicht-Sync-Endpunkte akzeptieren `Idempotency-Key` (UUID); Sync-Operationen haben `op_id`.
- Paginierung: Cursor-basiert (`?cursor=…&limit=…`), nie Offset.
- Zeitangaben: ISO 8601 mit Offset; Server speichert UTC.
- Versionierung: `/api/v1`; die App sendet `X-Client-Version`, der Server antwortet bei zu alter App mit `426 Upgrade Required` + Hinweis.

## Endpunkte

### System (ohne Auth)
| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/healthz` | Liveness (Prozess lebt) |
| GET | `/readyz` | Readiness (DB erreichbar, Storage beschreibbar, Migrationen aktuell) |
| GET | `/api/v1/instance` | öffentliche Instanz-Infos: Name, Version, `public_url`, Registrierungsmodus, `setup_required` |
| GET | `/.well-known/assetlinks.json` | Android App Links (aus ENV erzeugt) |
| GET | `/c/{token}` | Scan-Einstieg → liefert Web-App (siehe 06) |

### Setup & Auth
| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/api/v1/setup` | ersten Admin anlegen (nur solange keine Nutzer existieren, erfordert Setup-Token aus dem Log) |
| POST | `/api/v1/auth/register` | Registrierung (je nach `REGISTRATION_MODE`: open / invite / closed) |
| POST | `/api/v1/auth/login` | E-Mail + Passwort → Access-Token + Refresh-Token |
| POST | `/api/v1/auth/refresh` | Refresh-Token rotieren |
| POST | `/api/v1/auth/logout` | aktuelle Session beenden |
| POST | `/api/v1/auth/password/forgot` | Reset-Mail (antwortet immer 202, keine Nutzer-Enumeration) |
| POST | `/api/v1/auth/password/reset` | Token + neues Passwort |
| POST | `/api/v1/auth/device-link` | (eingeloggt, Web) kurzlebigen Code für „Android-App verbinden“-QR erzeugen |
| POST | `/api/v1/auth/device-link/redeem` | (App) Code → Session |
| GET/DELETE | `/api/v1/auth/sessions[/{id}]` | aktive Sessions/Geräte anzeigen, abmelden |

### Konto
| Methode | Pfad | Zweck |
|---|---|---|
| GET/PATCH | `/api/v1/me` | Profil |
| PUT | `/api/v1/me/password` | Passwort ändern (widerruft andere Sessions) |
| GET/PATCH | `/api/v1/me/settings` | Zeitzone, Erinnerungen, Theme … |
| DELETE | `/api/v1/me` | Konto + alle Daten löschen (mit Passwortbestätigung) |

### Sync (Herzstück für Android/Web)
| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/api/v1/sync/push` | Batch von Operationen (max. 100) anwenden, Ergebnis pro `op_id` |
| GET | `/api/v1/sync/pull?since={seq}&limit=500` | Änderungen seit Cursor (inkl. Tombstones) |
| GET | `/api/v1/sync/snapshot` | Vollabgleich (Erstinstallation / Cursor zu alt), gestreamt als NDJSON |
| GET | `/api/v1/sync/events` | SSE: „neue Änderungen bis seq X“ |
| GET/DELETE | `/api/v1/sync/conflicts[/{id}]` | automatisch gelöste Konflikte anzeigen/quittieren |

### Ressourcen (REST, v. a. für Web-Verwaltung, Admin-Skripte, Integrationen)
Alle Listen unterstützen `q`, Filter und Cursor. Schreibzugriffe erzeugen intern dieselben Operationen wie der Sync – es gibt nur **einen** Schreibpfad im Service-Layer.

| Methode | Pfad | Zweck |
|---|---|---|
| GET/POST | `/api/v1/colonies` | Liste (Filter: `status`, `location_id` inkl. Unterorte, `species_id`, `genus`, `due=feeding\|water\|cleaning\|overdue`, `size_min`) / anlegen |
| GET/PATCH/DELETE | `/api/v1/colonies/{id}` | Detail / ändern / löschen (Tombstone) |
| POST | `/api/v1/colonies/{id}/archive` · `/unarchive` | archivieren |
| GET | `/api/v1/colonies/{id}/timeline?types=feeding,water&cursor=` | Timeline |
| GET | `/api/v1/colonies/{id}/due` | Fälligkeiten |
| GET | `/api/v1/colonies/{id}/stats?range=7d\|30d\|3m\|1y\|all` | Statistiken |
| GET/POST/DELETE | `/api/v1/colonies/{id}/members[/{userId}]` | Teilen (owner / editor / viewer) |
| GET/POST | `/api/v1/colonies/{id}/events` | Events (Fütterung, Wasser, Reinigung, Notiz, Messung, Zählung, Brut …) |
| GET/PATCH/DELETE | `/api/v1/events/{id}` | Event bearbeiten/löschen |
| POST | `/api/v1/colonies/{id}/feedings/repeat-last` | „Letzte Fütterung wiederholen“ (Server-Variante; App macht es lokal) |
| CRUD | `/api/v1/colonies/{id}/queens` | Königinnen |
| CRUD | `/api/v1/colonies/{id}/schedules` | Pflegeintervalle |
| CRUD | `/api/v1/colonies/{id}/winter-rests` | Winterruhe |
| CRUD | `/api/v1/tasks` | Einzelaufgaben |
| CRUD | `/api/v1/locations` | Standortbaum |
| CRUD | `/api/v1/habitats` | Nester/Arenen |
| CRUD | `/api/v1/species`, `/api/v1/food-items` | Katalog + eigene Einträge |
| GET | `/api/v1/dashboard` | aggregierte Kennzahlen + Fälligkeitsgruppen |
| GET | `/api/v1/stats` | globale Statistiken |
| POST/GET | `/api/v1/care-rounds`, `/api/v1/care-rounds/{id}/summary` | Pflege-Rundgang |

### Scan: QR & NFC
| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/v1/scan/{token}` | Token → `{colony_id}` **nur wenn der Nutzer Zugriff hat**, sonst 404 (kein Unterschied zu „existiert nicht“) |
| POST | `/api/v1/scan/nfc-uid` | Tag-UID (gehasht) → Kolonie, für Tags ohne unsere URL |
| GET/POST | `/api/v1/colonies/{id}/scan-links` | Links auflisten / neuen erzeugen (`kind=qr\|nfc`) |
| POST | `/api/v1/scan-links/{id}/revoke` | deaktivieren |
| GET | `/api/v1/scan-links/{id}/qr.svg` · `.png?size=` | QR-Grafik (Web-Download; Etiketten-PDF entsteht clientseitig) |
| CRUD | `/api/v1/colonies/{id}/nfc-tags` | NFC-Tags verwalten |

### Fotos
| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/api/v1/photos` | Metadaten anlegen (id vom Client) |
| PUT | `/api/v1/photos/{id}/content` | Binärdaten hochladen – idempotent (gleicher SHA-256 → 200 ohne Neuschreiben) |
| GET | `/api/v1/photos/{id}/url?variant=thumb\|display\|original` | kurzlebige signierte URL (5 min) |
| GET | `/files/{key}?exp=&sig=` | Auslieferung (HMAC-geprüft, `Cache-Control: private, immutable`) |
| GET | `/api/v1/colonies/{id}/photos` | Galerie |

### Export
| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/api/v1/exports` | Export-Job starten: `json` (vollständig), `csv` (ZIP mit einer Datei pro Tabelle), `photos` (ZIP) |
| GET | `/api/v1/exports/{id}` | Status + Download-Link |

### Sensoren (vorbereitet)
| Methode | Pfad | Zweck |
|---|---|---|
| CRUD | `/api/v1/sensors` | Sensor anlegen → API-Key **einmalig** anzeigen |
| POST | `/api/v1/sensors/{id}/rotate-key` | Schlüssel neu erzeugen |
| POST | `/api/v1/sensors/{id}/measurements` | Messwerte (Sensor-Key, nur *dieser* Sensor, Batch bis 500, idempotent über `(sensor, metric, measured_at)`) |
| GET | `/api/v1/sensors/{id}/measurements?from&to&bucket=1h` | Zeitreihe/Aggregate |

```json
POST /api/v1/sensors/{id}/measurements
Authorization: Bearer acm_sk_7f3a9c_…
{ "readings": [ { "metric": "temperature", "value": 25.4, "measured_at": "2026-09-26T08:00:00Z" },
                { "metric": "humidity",    "value": 61,   "measured_at": "2026-09-26T08:00:00Z" } ] }
```

### Administration (Instanz-Admin)
| Methode | Pfad | Zweck |
|---|---|---|
| GET/PATCH | `/api/v1/admin/users[/{id}]` | Nutzer auflisten, sperren, Admin-Rolle |
| POST | `/api/v1/admin/users/{id}/password-reset-link` | Reset-Link ohne SMTP erzeugen |
| CRUD | `/api/v1/admin/invitations` | Einladungen |
| GET | `/api/v1/admin/backups` | Backup-Status (liest `data/backups/*/manifest.json`, schreibgeschützt) |
| GET | `/api/v1/admin/system` | Version, DB-Größe, Speicherbelegung, Migrationsstand |

Admins sehen **keine** fremden Kolonien – nur Metadaten (Anzahl, Speicherverbrauch).
