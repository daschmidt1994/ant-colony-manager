# 13 – User Flows

Tap-Zählung: **Scan** = NFC-Tap oder QR-Scan, **T** = Tap auf dem Bildschirm. Ausgangslage, wenn nicht anders angegeben: Handy entsperrt, App im Hintergrund oder geschlossen.

## Übersicht: Aufwand pro Aktion

| Aktion | Ablauf | Aufwand | Zum Vergleich: Excel am Handy |
|---|---|---|---|
| Letzte Fütterung wiederholen | Scan → „wiederholen“ | **Scan + 1 T** | App öffnen, Datei, Zeile suchen, 3–4 Zellen tippen (~30–60 s) |
| Wasser | Scan → Wasser | **Scan + 1 T** | ~20 s |
| Kontrolle ohne Befund | Scan → Kontrolle | **Scan + 1 T** | ~20 s |
| Reinigung (Standardarten) | Scan → Reinigen → Speichern | **Scan + 2 T** | ~30 s |
| Neue Fütterung (1 Futter) | Scan → Füttern → Chip → Speichern | **Scan + 3 T** | ~45 s |
| Foto | Scan → Foto → Auslöser → ✓ | **Scan + 3 T** | nicht sinnvoll möglich |
| Rundgang, pro Kolonie | Scan → 1–2 Aktionen | **Scan + 1–3 T** | – |

Zielzeit Scan → Kolonie sichtbar: ≤ 1,5 s (App im Hintergrund), ≤ 3 s (Kaltstart).

---

## F1 – Erstinstallation bis zum ersten Scan

```text
Server:  git clone → cp .env.example .env → ./scripts/init-env.sh → docker compose up -d
            ↓
Browser: http://server:8080  → Setup-Token aus `docker compose logs app` einfügen
            ↓
         Admin-Konto anlegen → Instanzname/Zeitzone
            ↓
         „Erste Kolonie anlegen“ (S8) → Art wählen → Speichern
            ↓
         QR-Code ist automatisch da → „Etikett drucken“ (optional)
            ↓
         Einstellungen → „Android-App verbinden“ → QR wird angezeigt
            ↓
Android: APK installieren → App öffnen → „QR-Code aus Web-App scannen“
            ↓
         angemeldet, Erst-Sync (Fortschrittsbalken) → Dashboard
            ↓
         Kolonie öffnen → ⋮ → NFC-Tag zuweisen (F5) → fertig
```
Fehlerpfade: Server nicht erreichbar (anderes Netz / Firewall) → Hinweis mit Checkliste · selbstsigniertes Zertifikat → Link zur Anleitung · Setup-Token falsch → erneut eingeben, nach 5 Versuchen 1 min warten.

## F2 – Tag antippen und Fütterung wiederholen (Hauptworkflow)

```text
Handy an NFC-Tag
   ↓  Android startet App direkt mit /c/<token>          (kein Auswahldialog)
   ↓  Token lokal aufgelöst (offline ok)
S7 Kolonie-Startseite: Ampel + „⟳ 2× Schabe + Zuckerwasser wiederholen“
   ↓  1 T
Snackbar „Fütterung gespeichert · Rückgängig · Details“ + Vibration
   ↓  Ampel springt auf 🟢, Timeline zeigt Eintrag
Fertig. (Sync im Hintergrund)
```
Varianten:
- App im Vordergrund auf anderem Screen → gleicher Ablauf, Kolonie wird oben auf den Navigationsstapel gelegt (Zurück führt zum vorherigen Screen).
- Noch nie gefüttert → Button „wiederholen“ entfällt, stattdessen „Füttern“ hervorgehoben.
- Identische Fütterung vor < 2 min bereits gespeichert → Snackbar „Schon vor 40 s gespeichert – nochmal?“ statt Doppeleintrag.

## F3 – QR in der App scannen

```text
Dashboard/beliebig → ( ◉ ) SCAN  (1 T)
   ↓  Kamera + NFC aktiv
QR in den Rahmen
   ↓  Vibration
S7 der Kolonie
```
Fehler: deaktivierter Code → Karte „Code deaktiviert“ + [Neu zuweisen] · fremde Kolonie → „Nicht gefunden“ · beliebiger anderer QR → „Kein Kolonie-Code“ + [Im Browser öffnen].

## F4 – QR mit der Android-Kamera (ohne die App vorher zu öffnen)

```text
Kamera-App erkennt URL → Tap auf Link
   ├─ eigene APK (verifizierte App Links) → App öffnet → S7
   ├─ Standard-APK → Browser → S22 → [In der App öffnen] (1 T) → App → S7
   └─ keine App   → Browser → S22 → Login (falls nötig) → Kolonie im Web
```

## F5 – NFC-Tag zuweisen

```text
S7 → ⋮ → „NFC-Tag zuweisen“                     (2 T)
   ↓  S10 wartet auf Tag
Handy an Tag
   ├─ leer / fremder Inhalt → schreiben → zurücklesen → ✔
   ├─ gehört schon zu dieser Kolonie → „Bereits zugewiesen ✔“
   ├─ gehört zu anderer Kolonie → Dialog „Von Lasius #3 umhängen?“ → [Umhängen] → alter Link deaktiviert → schreiben
   ├─ schreibgeschützt → „Per Seriennummer registrieren?“ → nur UID gespeichert (funktioniert nur bei offener App)
   └─ Abbruch beim Schreiben → „Nochmal halten“ (Link bleibt vorbereitet)
   ↓
✔ „Tag zugewiesen“ → optional Bezeichnung → [Fertig] oder [Weiteren Tag]
```
Offline möglich: Link entsteht lokal, Sync später. Neue Kolonie: S8 → „Speichern & NFC zuweisen“ springt direkt in S10.

**Massenzuweisung** (viele Kolonien, z. B. bei Umstieg): Web/App → Kolonieliste → Auswahl → „NFC-Tags nacheinander beschreiben“ → App führt durch die Liste („Jetzt Tag für Messor #12 … ✔ → nächste: Lasius #3“).

## F6 – Pflege-Rundgang

```text
Dashboard → „PFLEGE-RUNDGANG STARTEN“ (1 T) → Auswahl (Standard: alle mit Aufgaben) → STARTEN (1 T)
   ↓
Rundgang-Karte „Scanne die erste Kolonie“ (NFC + Kamera aktiv, Display bleibt an)
   ↓
┌─► Scan → Rundgang-Karte der Kolonie (Ampel + Aktionen)
│      ↓ 1–3 T: z. B. „wie letztes Mal füttern“ + „Wasser“
│      ↓ Aktionen erhalten ✓, Fortschritt 8/14
└──── nächster Scan (= weiter)
   ↓ alle Soll-Kolonien gescannt → automatisch Abschluss-Angebot
   ↓ oder „Beenden“ (1 T)
Zusammenfassung: x/y kontrolliert, Zählung pro Aktion, Liste nicht gescannter Kolonien
   ↓ [Öffnen] je fehlender Kolonie oder [Als übersprungen markieren]
Fertig
```
Regeln:
- Scan einer Kolonie **ohne** Aktion zählt als „kontrolliert“ (Besuch), erzeugt aber kein Event, außer man tippt „Kontrolle“.
- Pause (App verlassen, Anruf) → Rundgang bleibt aktiv; beim Zurückkehren „Rundgang fortsetzen (7/14)“.
- Unterbrochener Rundgang > 12 h → wird automatisch beendet, Zusammenfassung bleibt abrufbar.
- Komplett offline nutzbar; die Zusammenfassung ist eine lokale Abfrage über `care_round_id`.

## F7 – Offline dokumentieren und synchronisieren

```text
Keller ohne Netz → Scan → Füttern (lokal gespeichert, Outbox +1)
   ↓  Sync-Symbol: Wolke durchgestrichen · 1
… weitere Aktionen (Outbox +n)
   ↓  WLAN wieder da
automatischer Push (Debounce 2 s) → Server bestätigt jede Operation
   ↓  Symbol ✓
Web-App (offen) erhält SSE-Signal → Pull → Fütterung erscheint ohne Neuladen
```
Sonderfälle: Anmeldung abgelaufen → Hinweis „Bitte neu anmelden, 12 Änderungen warten“ – nach Login werden sie gesendet · einzelne abgelehnte Operation → ⚠ in Sync-Details mit Erklärung, übrige laufen weiter.

## F8 – Erinnerung → Erledigt

```text
18:00 Benachrichtigung „7 Kolonien brauchen heute Aufmerksamkeit (3 überfällig)“
   ├─ Tap → Dashboard, Gruppe „Überfällig“ aufgeklappt
   └─ (Einzelbenachrichtigung) „Messor #12 – Protein seit 2 Tagen überfällig“
         ├─ [Erledigt] → Fütterung wie zuletzt wird im Hintergrund gespeichert, Benachrichtigung verschwindet
         └─ [Kolonie öffnen] → S7
```
„Erledigt“ bei Protein/KH wiederholt die letzte passende Fütterung; bei Wasser/Reinigung die zuletzt verwendeten Arten; bei eigenen Aufgaben wird die Aufgabe abgehakt.

## F9 – Winterruhe starten und beenden

```text
Kolonieliste (Web: Mehrfachauswahl, Mobile: Langdruck-Auswahl) → „Winterruhe starten“
   ↓ Sheet: Start (heute) · geplantes Ende · Zieltemperatur · Standort (z. B. „Kühlschrank“) · Erinnerungen [pausieren | reduzieren ×4 | normal]
   ↓ Speichern → Status „Winterruhe“, Event ❄ in jeder Timeline
Dashboard: Abschnitt „❄ Winterruhe · 8“ – „Lasius niger · seit 42 Tagen“
   ↓ geplantes Ende erreicht → Erinnerung „Winterruhe beenden?“
S7 → „Winterruhe beenden“ → Datum (heute) → Status zurück auf „aktiv“, normale Intervalle ab jetzt
```

## F10 – Nestwechsel

```text
S7 → Mehr → „Nestwechsel“ (2 T)
   ↓ altes Nest vorausgefüllt → neues Nest wählen oder „+ Neues Nest“ (Typ, Hersteller, Modell, Größe)
   ↓ Grund (Chips: zu klein · Schimmel · zu trocken · Umzug freiwillig · sonstiges) + Notiz + Fotos
   ↓ Speichern → Event 🏠 „Reagenzglas → Ytong Nest XL“, altes Nest wird „gelagert“
```

## F11 – Kolonie teilen (vorbereitet, MVP: nur Besitzer)

```text
S7 → ⋮ → Teilen → E-Mail + Rolle (Helfer | Betrachter) → Einladung (Mail oder Link)
   ↓ Empfänger registriert sich / meldet sich an → Kolonie erscheint bei ihm
Entzug: Teilen → Person → Entfernen → beim nächsten Sync verschwindet die Kolonie von seinen Geräten
```

## F12 – Etiketten für mehrere Kolonien drucken

```text
Web: Kolonieliste → Filter „Regal A“ → Alle auswählen → „Etiketten“
   ↓ Vorlage (z. B. Avery L7651) · Startfeld · Felder
   ↓ Vorschau → PDF erzeugen → drucken
   ↓ optional „NFC-Tags nacheinander beschreiben“ (F5 Massenzuweisung) mit dem Handy
```

## F13 – Problem melden und verfolgen

```text
S7 → Kontrolle → Details → Befund „Schimmel“ → Schweregrad (warnung) → Foto → Speichern
   ↓ Event ⚠ in Timeline, Warnung im Dashboard, Kolonie mit ⚠-Symbol in Listen
   ↓ spätere Kontrolle: „Problem ‚Schimmel' noch aktuell?“ [Behoben] [Besteht noch]
```

## F14 – Code verloren / Etikett beschädigt

```text
S11 → „Neu generieren“ → Warnung „Altes Etikett funktioniert danach nicht mehr“ → Bestätigen
   ↓ neuer Code → Etikett drucken
NFC-Tag defekt: S11 → Tag → „Entfernen“ → neuen Tag zuweisen (F5)
```

---

## Abnahmekriterien Phase 2 → Umsetzung

- [ ] Nach einem Scan sind Ampel und Quick Actions ohne Scrollen sichtbar (6"-Display, Schriftgröße Standard).
- [ ] F2 benötigt nach dem Scan genau **1 Tap**.
- [ ] F6: pro Kolonie ohne Sonderfälle **≤ 3 Taps**, kein „Weiter“-Button nötig.
- [ ] Alle Flows außer F1, F11 und F12 funktionieren vollständig offline.
- [ ] Keine Bestätigungsdialoge beim Dokumentieren (nur Undo).
- [ ] Dashboard bleibt bei 150 Kolonien auf einem Bildschirm überblickbar (Gruppen eingeklappt).
