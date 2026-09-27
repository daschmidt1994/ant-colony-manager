# 05 – Offline-/Sync-Konzept

## 1. Grundprinzipien

1. **Lokale DB ist die Arbeitskopie.** Die UI liest und schreibt nur lokal. Sync läuft im Hintergrund.
2. **IDs entstehen auf dem Client** (UUIDv7). Ein Datensatz hat vom ersten Moment an seine endgültige ID – keine ID-Umschreibung nach dem Sync.
3. **Jede Änderung ist eine Operation mit eigener `op_id`**, die der Server **genau einmal** anwendet (`applied_ops`). Wiederholungen liefern das gespeicherte Ergebnis.
4. **Server vergibt die Reihenfolge** (`server_seq`), Clients holen Änderungen per Cursor.
5. **Events sind überwiegend „append-only“** (Fütterung, Wasser …) → echte Konflikte sind selten; sie betreffen fast nur Stammdaten (Koloniename, Standort …).

## 2. Lokale Strukturen (Drift)

```text
<jede synchronisierte Tabelle>
  + server_version  bigint   -- zuletzt vom Server gesehene version (0 = nie synchronisiert)
  + sync_state      text     -- synced | pending | conflict
  + deleted_at               -- lokaler Tombstone

outbox
  op_id        uuid PK       -- UUIDv7, beim lokalen Schreiben erzeugt
  entity       text          -- 'colony_events', 'colonies', …
  entity_id    uuid
  op           text          -- create | update | delete
  payload      json          -- create: vollständiges Aggregat; update: nur geänderte Felder
  base_version bigint        -- server_version beim Bearbeiten
  created_at   timestamp     -- Client-Uhr (nur zur Info/Konfliktauflösung)
  attempts     int
  next_try_at  timestamp
  last_error   text
  state        text          -- queued | in_flight | failed_permanent

photo_uploads (photo_id, local_path, sha256, bytes, attempts, next_try_at, state)
sync_meta     (server_id, user_id, pull_cursor, last_push_at, last_pull_at, tombstone_horizon)
```

**Outbox-Verdichtung:** Mehrere `update`s desselben Datensatzes, die noch nicht gesendet wurden, werden zu einer Operation zusammengeführt (Felder gemergt, *älteste* `base_version` bleibt). `create` + späteres `update` → ein `create` mit aktuellem Stand. `create` + `delete` vor dem Senden → beide entfallen. So entstehen offline keine Kaskaden unnötiger Operationen.

## 3. Push

```http
POST /api/v1/sync/push
{ "device_id": "…",
  "ops": [
    { "op_id": "0199…a1", "entity": "colony_events", "entity_id": "0199…e1", "op": "create",
      "payload": { "colony_id": "…", "type": "feeding", "occurred_at": "2026-09-26T18:04:11+02:00",
                   "feeding": { "acceptance": "unknown",
                                "items": [ { "id": "…", "food_item_id": "…", "quantity": 2, "unit": "piece" },
                                           { "id": "…", "food_item_id": "…" } ] } } },
    { "op_id": "0199…a2", "entity": "colonies", "entity_id": "…", "op": "update",
      "base_version": 1840, "payload": { "location_id": "…" } }
  ] }
```

Server pro Operation (eigene Transaktion/Savepoint, Reihenfolge beibehalten):

```text
1. op_id in applied_ops?          → gespeichertes Ergebnis zurück ("duplicate")  ← Retry-sicher
2. Berechtigung prüfen (authz)    → sonst "rejected: forbidden"
3. Validierung                    → sonst "rejected: invalid" (+ Feldfehler)
4. create:  INSERT … ON CONFLICT (id) DO NOTHING
            (existiert die ID bereits mit identischem Inhalt → "duplicate", sonst "rejected: id_conflict")
   update:  Konfliktprüfung (Abschnitt 5) → Felder anwenden
   delete:  deleted_at setzen (Tombstone), abhängige Aggregate ebenso
5. applied_ops-Eintrag + change_log (Trigger) in derselben Transaktion
```

Antwort:
```json
{ "results": [ { "op_id": "0199…a1", "status": "applied",  "version": 1902 },
               { "op_id": "0199…a2", "status": "merged",   "version": 1903, "conflicts": ["name"] } ],
  "server_seq": 1903 }
```

Client: `applied/duplicate/merged` → Outbox-Eintrag löschen, `server_version` setzen. `rejected` → Eintrag auf `failed_permanent`, Datensatz auf `conflict` markieren, dem Nutzer sichtbar machen („1 Änderung konnte nicht gespeichert werden“), lokale Änderung wird durch den Serverstand beim nächsten Pull ersetzt.

### Warum wird eine Fütterung garantiert genau einmal gespeichert?

| Störfall | Absicherung |
|---|---|
| Request kommt an, Antwort geht verloren → Retry | `op_id` in `applied_ops` → „duplicate“, kein zweiter Insert |
| Retry mit neuer `op_id` (z. B. nach App-Neuinstallation mit Backup) | `entity_id` (Event-UUID) ist PK → `ON CONFLICT DO NOTHING` |
| Doppelter Tap auf „Füttern“ | UI sperrt Button 1 s; zusätzlich Hinweis „Vor 20 s bereits gefüttert – trotzdem speichern?“ bei identischem Event < 2 min |
| App-Absturz während Sync | Outbox-Eintrag bleibt `in_flight` → nach Neustart erneut senden → Server dedupliziert |
| Zwei Geräte erfassen dieselbe echte Fütterung | fachlich zwei Events (gewollt), Timeline zeigt beide mit Autor |

Test (Phase 7, automatisiert): Offline-Fütterung → Netzwerk mit 100 % Antwortverlust für 3 Versuche → Netz normal → genau **1** Zeile in `colony_events`.

## 4. Pull

```http
GET /api/v1/sync/pull?since=1840&limit=500
→ { "changes": [ { "seq": 1841, "entity": "colony_events", "op": "upsert", "data": { …Aggregat… } },
                 { "seq": 1845, "entity": "colonies", "op": "delete", "id": "…" } ],
    "next": 1845, "has_more": false }
```

- Server liest `change_log` mit `seq > since`, gefiltert auf **Sichtbarkeit**: `colony_id ∈ meine Mitgliedschaften` **oder** `owner_id = ich` **oder** Systemkatalog (`owner_id IS NULL AND colony_id IS NULL`).
- Pro Entität wird nur der **aktuelle** Stand geliefert (mehrere Änderungen derselben Zeile im Fenster → einmal).
- **Lücken in `seq`** sind normal (z. B. verworfene Duplikate) und unschädlich – der Cursor ist nur ein „größer als“.
- Durch den Zeilen-Lock auf `sync_counter` sind `seq`-Reihenfolge und Commit-Reihenfolge identisch → der Cursor überspringt nie eine später committete kleinere `seq`.
- Client wendet Änderungen an, **außer** der Datensatz hat ausstehende lokale Outbox-Operationen: dann wird der Serverstand als neue Basis gemerkt und die lokalen Felder bleiben obenauf (werden beim nächsten Push gegen die neue Basis geprüft).
- **Zugriff entzogen** (`colony_members`-Delete für mich) → Client löscht die Kolonie mit allen lokalen Daten.
- Reihenfolge immer: **erst Push, dann Pull** → eigene Änderungen kommen nicht als „fremde“ zurück.

## 5. Konflikte (Stammdaten)

Konflikt = Client schickt `update` mit `base_version`, Server-Datensatz hat inzwischen höhere `version`.

1. Server ermittelt über `change_log.changed_fields` alle Felder, die seit `base_version` geändert wurden.
2. **Keine Überschneidung** mit den Feldern der Operation → automatisch zusammenführen („merged“). *Beispiel: Web ändert Notiz, Handy ändert Standort → beide bleiben.*
3. **Überschneidung** → **Last-Writer-Wins pro Feld** nach Client-Bearbeitungszeit (`op.created_at`); der unterlegene Wert wird in `sync_conflicts` gespeichert und in der App als dezenter Hinweis angezeigt („Name wurde parallel geändert – übernommen: …, verworfen: …“ mit „Wiederherstellen“).
4. **Löschen vs. Bearbeiten:** Löschen gewinnt; die verworfene Bearbeitung landet in `sync_conflicts`. Wiederherstellen aus dem Papierkorb (30 Tage) ist möglich.
5. **Eindeutigkeit** (z. B. Koloniennummer #12 offline doppelt vergeben) → Server vergibt die nächste freie Nummer und meldet „merged“ mit Hinweis.

Keine manuellen Merge-Dialoge im Pflegealltag – bei einer Hobby-App mit meist einem Nutzer ist das die richtige Balance.

## 6. Löschen & Tombstones

- Löschen setzt `deleted_at` (Tombstone), der Trigger schreibt `op = delete` ins `change_log`.
- Tombstones bleiben **180 Tage**, dann GC-Job: physisches Löschen, `instance_settings.tombstone_horizon_seq` wird angehoben.
- Pull mit `since < horizon` → `410 Gone` → Client macht **Snapshot-Resync** (vollständiger Abgleich, lokale Outbox bleibt erhalten und wird danach gepusht).
- Papierkorb in der UI: gelöschte Kolonien/Events 30 Tage wiederherstellbar (= `deleted_at` zurücksetzen).

## 7. Fotos

- Foto aufnehmen → lokal komprimieren (lange Kante 2048 px, JPEG q≈82, ~300–600 KB), Thumbnail lokal → Metadaten-Datensatz über die normale Outbox, Binärdaten in `photo_uploads`.
- Upload separat: `PUT /photos/{id}/content` mit `Content-SHA256`. Idempotent. Optional „nur im WLAN“.
- Server: MIME per Magic Bytes prüfen, neu kodieren (entfernt Metadaten inkl. **GPS**; Aufnahmedatum wird vorher übernommen), Thumbnail (400 px) erzeugen, `upload_state = stored`.
- Andere Geräte laden Thumbnails bei Bedarf und cachen sie (LRU, Größenlimit einstellbar).

## 8. Wann wird synchronisiert? Retries

| Auslöser | Verhalten |
|---|---|
| lokaler Schreibvorgang | Push nach 2 s Debounce (fasst Rundgang-Aktionen zusammen) |
| App-Start / Resume | Push + Pull |
| Netz wieder da (`connectivity_plus`) | Push + Pull |
| SSE-Signal (Vordergrund) | Pull |
| WorkManager | alle 15 min, nur mit Netz |
| manuell | „Jetzt synchronisieren“ (Pull-to-Refresh) |

Fehlerbehandlung:
- Netzwerk-/5xx-Fehler: exponentielles Backoff mit Jitter (2 s → 4 → 8 … max. 15 min), unbegrenzt.
- `401`: Refresh versuchen; scheitert er → Nutzer erneut anmelden lassen, **Outbox bleibt erhalten** und wird danach gesendet.
- `4xx` (Validierung/Berechtigung): nicht wiederholen → `failed_permanent` + sichtbarer Hinweis.
- Eine blockierende Operation hält nachfolgende Operationen **anderer** Datensätze nicht auf; Operationen **desselben** Datensatzes bleiben in Reihenfolge.

Sync-Status sichtbar, aber unaufdringlich: kleines Wolken-Icon in der App-Leiste (✓ synchron · ↻ läuft · ⏸ offline, 3 ausstehend · ⚠ Fehler).

## 9. Uhrzeiten

- `occurred_at` stammt vom Gerät (inkl. Zeitzonen-Offset) – fachlich korrekt, auch offline.
- `version`/`seq` stammen ausschließlich vom Server – Sync hängt **nicht** an Geräteuhren.
- Liegt `occurred_at` > 5 min in der Zukunft (falsche Geräteuhr), kappt der Server auf „jetzt“ und markiert das Event.

## 10. Web-Client

Nutzt dieselbe Sync-Engine mit Drift-WASM als Cache (Pull beim Laden, Push sofort). Die Outbox existiert auch hier, damit kurze Verbindungsabbrüche nichts verlieren. Mehrere Tabs teilen sich die DB über einen SharedWorker (Drift-Standard).

## 11. Umsetzungsstand (Phase 7)

| Thema | Umsetzung |
|---|---|
| Outbox-Verdichtung | Änderungen werden nur in **nie gesendete** Operationen gemischt. Eine einmal gesendete Operation bleibt unverändert – der Server hat sie womöglich schon angewendet (Antwort verloren) und beantwortet die Wiederholung als Duplikat, ohne die Nutzdaten erneut zu lesen. Gefunden durch den Chaos-Test. Ebenso wird eine gesendete Anlage beim Löschen nicht lokal verworfen, sondern das Löschen mitgeschickt. |
| Sendeversuche | zählen beim Entnehmen aus der Outbox (auch wenn die App mitten im Senden beendet wird) |
| Auslöser | lokales Schreiben (1,5 s), App wieder im Vordergrund, Netz wieder da (`connectivity_plus`), Server-Signal per SSE (Android im Vordergrund), Web: alle 30 s bei sichtbarem Tab, Android-Hintergrund: WorkManager alle 15 min bei Netz |
| Hintergrund-Sync | eigener Isolate; schreibt in dieselbe SQLite-Datei, die App lädt ihre Anzeigen beim Zurückkehren neu |
| Web, mehrere Tabs | nur der erste Tab öffnet die lokale Datenbank; weitere Tabs zeigen einen Hinweis (BroadcastChannel – funktioniert auch unter `http://`) |
| Gerät abgemeldet | Refresh antwortet `device.revoked` → die App löscht ihre lokalen Daten und zeigt einen Hinweis; erneutes Anmelden auf demselben Gerät hebt die Sperre auf |
| Kolonie gelöscht | Ereignisse, Intervalle, Codes der Kolonie werden auf allen Geräten mit entfernt |
| Konflikte | „Mehr → Synchronisierung“ zeigt übernommene und verworfene Werte, quittierbar |

**Tests:** `app/test/offline_sync_test.dart` – Chaos-Test mit fünf Seeds (zwei Geräte, 400 Zufallsaktionen, 25 % Verbindungsabbrüche, 20 % verlorene Antworten nach dem Speichern; danach müssen beide Geräte exakt dem Server entsprechen und jeder Datensatz genau einmal angelegt sein), Restore während Offline-Einträge warten, Kolonie-Löschung, Geräte-Abmeldung. Gegen den echten Server (`server_contract_test.dart`): zwei Geräte, genau-einmal, feldweises Zusammenführen, Konfliktprotokoll, Geräte-Abmeldung.
