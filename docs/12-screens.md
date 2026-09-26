# 12 – Screens

Wireframes sind schematisch (Mobile ≈ 360 dp Breite). Farben/Abstände siehe [11-ux-grundlagen.md](11-ux-grundlagen.md).

Übersicht:

| # | Screen | Plattform | MVP |
|---|---|---|---|
| S1 | Server verbinden / Onboarding | Android | ✔ |
| S2 | Login | beide | ✔ |
| S3 | Registrierung / Einladung annehmen | beide | ✔ |
| S4 | Ersteinrichtung (Admin-Setup) | Web | ✔ |
| S5 | Dashboard | beide | ✔ |
| S6 | Kolonieliste | beide | ✔ |
| S7 | Kolonie-Startseite | beide | ✔ |
| S8 | Kolonie erstellen / bearbeiten | beide | ✔ |
| S9 | Scanner | beide (NFC nur Android) | ✔ |
| S10 | NFC-Tag zuweisen | Android | ✔ |
| S11 | QR-Code & Etiketten | beide | ✔ |
| S12 | Fütterung | beide | ✔ |
| S13 | Wasser | beide | ✔ |
| S14 | Reinigung | beide | ✔ |
| S15 | Kontrolle / Notiz / Messung / Problem | beide | ✔ |
| S16 | Fotos & Galerie | beide | ✔ |
| S17 | Timeline | beide | ✔ |
| S18 | Pflege-Rundgang (Start, Scan-Karte, Abschluss) | Android (Web: Liste) | ✔ |
| S19 | Statistiken (Kolonie + global) | beide | Phase 9 |
| S20 | Einstellungen & Stammdaten | beide | ✔ |
| S21 | Administration | Web | ✔ |
| S22 | Scan-Einstieg `/c/<token>` ohne App | Web | ✔ |

---

## S1 – Server verbinden (erster App-Start)

```text
┌──────────────────────────────┐
│                              │
│          🐜                  │
│   Ant Colony Manager         │
│   Deine Kolonien. Ein Scan.  │
│                              │
│ ┌──────────────────────────┐ │
│ │ ▣  QR-Code aus Web-App   │ │  ← empfohlen: Web → „Android-App verbinden“
│ │    scannen               │ │
│ └──────────────────────────┘ │
│                              │
│  oder Server-Adresse         │
│ ┌──────────────────────────┐ │
│ │ https://ants.example.com │ │
│ └──────────────────────────┘ │
│  [ Weiter ]                  │
│                              │
│  Lokales Netz? z. B.         │
│  http://192.168.1.50:8080    │
└──────────────────────────────┘
```
- „Weiter“ prüft `GET /api/v1/instance` → zeigt Instanzname + Version, dann Login (S2).
- Fehlertexte konkret: „Server nicht erreichbar – gleiches WLAN?“, „Zertifikat nicht vertrauenswürdig – siehe Anleitung für lokale Zertifikate“.
- Danach einmalig: Berechtigungen Benachrichtigungen + (bei Bedarf) Kamera, jeweils mit einem Satz Begründung.

## S2 – Login · S3 – Registrierung

```text
┌──────────────────────────────┐
│ ← ants.example.com           │
│                              │
│ Anmelden                     │
│ E-Mail     [               ] │
│ Passwort   [            👁 ] │
│                              │
│ [        Anmelden          ] │
│                              │
│ Passwort vergessen?          │
│ Einladung erhalten? Konto    │
│ erstellen                    │
└──────────────────────────────┘
```
- Registrierung: Name, E-Mail, Passwort (Stärke-Hinweis live), bei `invite` vorausgefüllt aus Einladungslink. Kein Captcha nötig (Rate-Limit + Einladung).
- Passwort vergessen → „Wenn ein Konto existiert, ist eine E-Mail unterwegs.“ Ohne SMTP: Hinweis „Bitte Administrator fragen“.

## S4 – Ersteinrichtung (Web, nur bei leerer Instanz)

Schritt 1: Setup-Token (aus `docker compose logs app`) · Schritt 2: Admin-Konto · Schritt 3: Instanzname, Zeitzone, Registrierungsmodus · Schritt 4: „Erste Kolonie anlegen“ oder „Später“.

## S5 – Dashboard

```text
┌──────────────────────────────────┐
│ Übersicht                 ↻  👤  │
│                                  │
│ ┌──────┐ ┌──────┐ ┌──────┐       │
│ │  42  │ │ ❄ 8  │ │ ⚠ 3  │       │
│ │aktiv │ │Winter│ │Warn. │       │
│ └──────┘ └──────┘ └──────┘       │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ 🔁 PFLEGE-RUNDGANG STARTEN    │ │
│ │    14 Kolonien brauchen dich  │ │
│ └──────────────────────────────┘ │
│                                  │
│ 🔴 ÜBERFÄLLIG · 3            ▾   │
│ ┌──────────────────────────────┐ │
│ │● Messor #12   Regal A/3      │ │
│ │ Messor barbarus              │ │
│ │ 🔴 Protein 2 T  🟡 Wasser     │ │
│ ├──────────────────────────────┤ │
│ │● Lasius #3    Regal B/1      │ │
│ │ 🔴 Wasser 1 T                │ │
│ └──────────────────────────────┘ │
│ 🟡 HEUTE · 11                ▾   │
│ ⚪ MORGEN · 6                 ▸   │
│ ⚪ DIESE WOCHE · 19           ▸   │
│ ❄ WINTERRUHE · 8             ▸   │
│   Lasius niger · seit 42 Tagen   │
│                                  │
│ LETZTE AKTIVITÄTEN               │
│ 18:04 Messor #12  Fütterung      │
│ 17:58 Camponotus #5  Wasser      │
├──────────────────────────────────┤
│  🏠   🐜    ( ◉ )   🔁   ☰         │
└──────────────────────────────────┘
```
- **Eine Zeile pro Kolonie** mit allen fälligen Aufgaben als Chips → bei 100 Kolonien bleibt die Liste kurz.
- Überfällig + Heute aufgeklappt, der Rest eingeklappt (Zustand gemerkt).
- Wischen nach rechts auf einer Zeile = Schnellmenü (Füttern wiederholen / Wasser / Kontrolle) ohne die Kolonie zu öffnen.
- Warnungen: offene Probleme, Sync-Fehler, Königin verstorben ohne Folgeaktion, lange keine Kontrolle.
- **Web:** drei Spalten – links Kennzahlen + Fälligkeitsgruppen, Mitte Liste, rechts Aktivitäten; zusätzlich Filter nach Standort.

## S6 – Kolonieliste

```text
┌──────────────────────────────────┐
│ Kolonien (58)          ⇅   ＋    │
│ ┌──────────────────────────────┐ │
│ │ 🔍 Name, Art, Gattung, #, Ort │ │
│ └──────────────────────────────┘ │
│ [Aktiv ✕] [Fällig] [Regal A ▾]   │
│ [Winterruhe] [Gründung] [Größe▾] │
│                                  │
│ ● Messor #12                  🔴 │
│   Messor barbarus · Regal A/3    │
│   500–1.000 · 👑1                │
│ ● Lasius #3                   🟡 │
│   Lasius niger · Regal B/1       │
│ ❄ Lasius #7                      │
│   Lasius flavus · Keller         │
│ …                                │
└──────────────────────────────────┘
```
- Suche lokal (FTS5) während des Tippens, < 100 ms; Treffer auch auf `#12`, internen Code, Standortpfad.
- Sortierung: Dringlichkeit (Standard), Name, Nummer, Art, Standort, zuletzt versorgt.
- Gruppierung optional nach Standort (einklappbare Regale).
- Archivierte/abgegebene/verstorbene über Filter „Archiv“.
- **Web:** Tabelle (Spalten wählbar: #, Name, Art, Gattung, Standort, Status, Größe, Königinnen, nächste Aufgabe, letzte Fütterung), Mehrfachauswahl → Massenaktionen: Etiketten drucken, Standort setzen, Status setzen, Intervalle übernehmen, Export.

## S7 – Kolonie-Startseite (Kernscreen)

```text
┌──────────────────────────────────┐
│ ←                    ▣ QR  ⋮     │
│ Messor barbarus                  │  (kursiv)
│ Kolonie #12 · Regal A / Ebene 3  │
│                                  │
│ 👑 1   🐜 500–1.000   🥚 viel     │
│ 🌡 25,4 °C   💧 61 %   · vor 2 T  │
│                                  │
│ NÄCHSTE AUFGABEN                 │
│ 🔴 Protein      2 Tage überfällig│
│ 🟡 Wasser       heute            │
│ 🟢 Reinigung    in 5 Tagen       │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ ⟳ 2× Schabe + Zuckerwasser    │ │  ← „Letzte Fütterung wiederholen“
│ │   wiederholen                 │ │     1 Tap = gespeichert
│ └──────────────────────────────┘ │
│ ┌─────────┐┌─────────┐┌────────┐ │
│ │ 🪲      ││ 💧      ││ 🧹     │ │
│ │ Füttern ││ Wasser  ││Reinigen│ │
│ └─────────┘└─────────┘└────────┘ │
│ ┌─────────┐┌─────────┐┌────────┐ │
│ │ 👁      ││ 📷      ││ ✎  ▾   │ │
│ │Kontrolle││ Foto    ││ Mehr   │ │  ← Notiz, Messung, Größe, Brut,
│ └─────────┘└─────────┘└────────┘ │     Problem, Nestwechsel, Königin
│                                  │
│ ❓ Fütterung von gestern          │  ← Annahme nachtragen
│   angenommen?  [Ja][Teils][Nein] │
│                                  │
│ TIMELINE                  Alle › │
│ Heute                            │
│  🪲 2 Schaben gefüttert  18:04   │
│ Gestern                          │
│  💧 Nest befeuchtet              │
│ Vor 4 Tagen                      │
│  🐜 Größe → 500–1.000            │
└──────────────────────────────────┘
```
- Oberer Block (Name bis Quick Actions) passt ohne Scrollen auf ein 6"-Display → **nach einem Scan ist sofort alles sichtbar**.
- Quick Actions im unteren Bildschirmdrittel sind bei gescrollter Seite als schwebende Leiste weiter verfügbar.
- **Annahme nachtragen**: Akzeptanz einer Fütterung ist oft erst Stunden später bekannt → erscheint bei der nächsten Öffnung innerhalb von 72 h, ein Tap.
- Menü ⋮: Bearbeiten, NFC-Tag zuweisen, QR/Etikett, Intervalle, Winterruhe starten/beenden, Teilen, Archivieren, Löschen.
- Tabs darunter (Web: rechte Spalte): Timeline · Fotos · Details · Nester · Statistik.
- **Winterruhe-Variante**: Kopf zeigt „❄ Winterruhe seit 42 Tagen · Ende geplant 15.03.“, Aufgaben entsprechend reduziert/pausiert, Quick Action „Winterruhe beenden“.

## S8 – Kolonie erstellen / bearbeiten

```text
┌──────────────────────────────────┐
│ ✕ Neue Kolonie        [Speichern]│
│                                  │
│ Art *                            │
│ [ Messor barb… ▾ ]  (Suche +     │
│   „Neue Art anlegen“)            │
│ Name        [ Messor #12      ]  │  ← Vorschlag: Gattung + nächste Nr.
│ Nummer      [ 12 ]   Code [MB-12]│
│ Standort    [ Regal A / Ebene 3▾]│
│ Status      (●Aktiv ○Gründung …) │
│ Königinnen  [ 1 ]  (●mono ○poly) │
│ Größe       [1–10][10–50][50–100]│
│             [100–500] … [exakt]  │
│                                  │
│ ▸ Herkunft (Fundort, Kauf, Züchter)
│ ▸ Pflegeintervalle               │
│    Protein 3 T · KH 5 T ·        │
│    Wasser 2 T · Reinigung 7 T    │  ← Vorlage aus Einstellungen
│ ▸ Notizen                        │
│                                  │
│ [  Speichern & NFC zuweisen   ]  │  ← direkt weiter zu S10
└──────────────────────────────────┘
```
- Pflicht nur **Art** (oder Freitext). Alles andere optional/aufklappbar → Anlegen in < 30 s.
- Nach dem Speichern wird der QR-Code automatisch erzeugt; zweiter Button „Speichern & NFC zuweisen“.
- Web: zusätzlich „Mehrere anlegen“ (CSV-Import, Phase 9).

## S9 – Scanner

```text
┌──────────────────────────────────┐
│ ✕                        🔦      │
│                                  │
│      ┌──────────────────┐        │
│      │                  │        │
│      │   Kamera-Bild    │        │
│      │   [ Rahmen ]     │        │
│      │                  │        │
│      └──────────────────┘        │
│                                  │
│   📶 NFC ist bereit –            │
│      Tag einfach antippen        │
│                                  │
│   Code manuell eingeben          │
└──────────────────────────────────┘
```
- Öffnet in < 300 ms (Kamera vorgewärmt), erkennt QR und NFC gleichzeitig.
- Treffer → Vibration → **direkt S7** der Kolonie (kein Zwischenschritt).
- Fehlerfälle als Karte über dem Kamerabild: „Code deaktiviert – [Neu zuweisen]“, „Gehört nicht zu deinen Kolonien“, „Kein Kolonie-Code (erkannt: https://…) – [Im Browser öffnen]“.

## S10 – NFC-Tag zuweisen

```text
┌──────────────────────────────────┐
│ ✕ NFC-Tag zuweisen               │
│ Messor #12                       │
│                                  │
│          ((( 📱 )))              │  ← Animation: Handy an Tag
│                                  │
│  Halte das Handy an den Tag.     │
│  Rückseite, Mitte oben.          │
│                                  │
│ ─────────────────────────────── │
│ ✔ Tag beschrieben & geprüft      │
│   NTAG213 · 42 / 137 Byte        │
│   Bezeichnung [Nest vorne     ]  │
│   ☐ Tag schreibschützen (endgültig)
│                                  │
│ [ Fertig ]  [ Weiteren Tag ]     │
└──────────────────────────────────┘
```
Zustände: Warten → Schreiben → Prüfen → Erfolg | Rückfrage („Tag gehört zu Lasius #3 – umhängen?“) | Fehler („Tag schreibgeschützt – nur per Seriennummer registrieren?“, „Zu früh entfernt – nochmal halten“, „NFC ist ausgeschaltet – [Einstellungen öffnen]“).

## S11 – QR-Code & Etiketten

```text
┌──────────────────────────────────┐
│ ← QR-Code · Messor #12           │
│      ┌──────────────┐            │
│      │   ▣▣▣ QR     │            │
│      └──────────────┘            │
│  …/c/7Kq2mZr9XbT4pLwA  aktiv     │
│                                  │
│ [ Etikett drucken ]              │
│ [ PNG ] [ SVG ] [ Teilen ]       │
│ Neu generieren · Deaktivieren    │
│                                  │
│ NFC-TAGS (2)                     │
│  Nest vorne   NTAG213  12.04.26  │
│  Arena        NTAG215  12.04.26  │
│  [+ Tag zuweisen]                │
└──────────────────────────────────┘
```

**Etiketten-Designer** (Web bevorzugt, auch mobil):
```text
┌─────────── Vorlage ──────────┬──────── Vorschau (A4) ────────┐
│ Format  [Avery L7651 38×21 ▾]│ ┌──┐┌──┐┌──┐┌──┐┌──┐           │
│ Start bei Feld [ 7 ]         │ │  ││  ││  ││  ││  │           │
│ Felder                       │ └──┘└──┘└──┘└──┘└──┘           │
│  ☑ Art  ☑ Name/Nr.           │ ┌──┐┌──┐ …                    │
│  ☑ Standort  ☐ Code          │                                │
│  ☑ „NFC + QR“-Hinweis        │                                │
│ Kolonien: 12 ausgewählt [▾]  │                                │
│ [ PDF erzeugen ] [ Drucken ] │                                │
└──────────────────────────────┴────────────────────────────────┘
```

## S12 – Fütterung (Bottom Sheet)

```text
┌──────────────────────────────────┐
│ Füttern · Messor #12   🕒 jetzt ▾│
│                                  │
│ ⟳ WIE LETZTES MAL                │
│ ┌──────────────────────────────┐ │
│ │ 2× Schabe (klein)            │ │
│ │ + Zuckerwasser        [ ✓ ]  │ │  ← 1 Tap speichert
│ └──────────────────────────────┘ │
│                                  │
│ PROTEIN                          │
│ (Schabe●)(Heimchen)(Fruchtfl.)   │  ← zuletzt für diese Kolonie zuerst
│ (Mehlwurm)(＋ mehr)              │
│   Schabe   [ − ]  2  [ + ]  klein▾
│ KOHLENHYDRATE                    │
│ (Zuckerwasser●)(Honig)(Jelly)(＋)│
│                                  │
│ Annahme  (?)(✓)(½)(✕)            │  ← Standard „unbekannt“
│ ✎ Notiz   📷 Foto                │
│                                  │
│ [          Speichern           ] │
└──────────────────────────────────┘
```
- Chip antippen = hinzufügen (Menge 1 bzw. zuletzt verwendet), nochmal = entfernen.
- „＋ mehr“ öffnet Suche über alle Futtermittel inkl. „Neues Futtermittel“.
- Zeit-Chip: jetzt · vor 1 h · heute Morgen · gestern · Datum/Uhrzeit.

## S13 – Wasser

**Tap auf „Wasser“ speichert sofort** mit den zuletzt verwendeten Arten (Standard: Tränke aufgefüllt):
```text
┌──────────────────────────────────┐
│ ✓ Wasser: Tränke aufgefüllt      │
│              Rückgängig  Details │
└──────────────────────────────────┘
```
„Details“ bzw. Langdruck öffnet das Sheet:
```text
│ Wasser · Messor #12    🕒 jetzt ▾│
│ (Tränke aufgefüllt●)(Nest befeuchtet)
│ (Wassertank aufgefüllt)(Wasser gewechselt)
│ ▸ Messwerte: 🌡 [25,4] °C  💧 [61] %
│ [ Speichern ]                    │
```

## S14 – Reinigung

Sheet (2 Taps), zuletzt verwendete Arten vorausgewählt:
```text
│ Reinigen · Messor #12  🕒 jetzt ▾│
│ (Futterreste●)(Müllplatz●)(Arena) │
│ (Scheiben)(Tränke)(Nest)          │
│ (Nest gewechselt → Nestwechsel)   │  ← leitet zu Nestwechsel-Dialog
│ ✎ Notiz   📷 Foto                 │
│ [ Speichern ]                     │
```

## S15 – Kontrolle, Notiz, Messung, Problem, Größe, Brut

- **Kontrolle**: 1 Tap = „Kontrolle, alles in Ordnung“ (Undo-Snackbar). „Details“: Befund-Chips (ruhig, aktiv, Brut sichtbar, Schimmel, Milben, tote Tiere, Ausbruchsgefahr) → negative Befunde erzeugen automatisch ein **Problem** mit Schweregrad.
- **Notiz**: Sheet mit Textfeld (Tastatur-Diktat nutzbar), optional als Problem markieren.
- **Messung**: Zahlenfelder mit Ziffernblock, letzte Werte vorausgefüllt, Ort (Nest/Arena/Raum).
- **Koloniegröße**: `RangePicker` (1–10 … 10.000+) oder „genau“ mit Zahlenfeld; zeigt vorherigen Wert.
- **Brut**: pro Stadium (Eier, Larven, Puppen, Nacktpuppen, Geschlechtstiere) Segment `– / wenig / mittel / viel` oder Zahl.
- **Königin**: hinzugefügt / verstorben / entfernt / beobachtet, Auswahl der Königin.
- **Nestwechsel**: altes Nest (vorbelegt) → neues Nest (Auswahl oder neu anlegen), Grund, Fotos.

## S16 – Fotos & Galerie

- „Foto“-Quick-Action öffnet direkt die Kamera; nach der Aufnahme: optional Notiz + Zuordnung (Ereignis/Königin/Nest), Standard = Kolonie. Speichern ohne weitere Nachfrage.
- Galerie: Raster 3 Spalten, nach Monat gruppiert, Filter (Nest, Königin, Ereignis), Vollbild mit Wischen und Pinch-Zoom, Upload-Status-Punkt bei noch nicht hochgeladenen Fotos.
- Web: Drag & Drop mehrerer Fotos, Download (einzeln/ZIP).

## S17 – Timeline

```text
│ Timeline · Messor #12            │
│ [Alle][🪲][💧][🧹][🌡][📷][🐜][⚠] │  ← Filter-Chips, mehrfach
│ SEPTEMBER 2026                   │
│ Heute                            │
│  🪲 18:04 2× Schabe + Zuckerw.  ✓ │
│         Anna · Rundgang          │
│  💧 17:58 Tränke aufgefüllt      │
│ Gestern                          │
│  📷 Foto (3)  [▫][▫][▫]          │
│  ⚠ Schimmel im Nest · warnung    │
│ …                                │
```
- Eintrag antippen → Details bearbeiten/löschen (mit Undo).
- Endloses Scrollen (lokal, paginiert), Sprung zu Datum.
- Autor wird nur angezeigt, wenn die Kolonie geteilt ist.

## S18 – Pflege-Rundgang

**Start**
```text
│ Pflege-Rundgang                  │
│ Welche Kolonien?                 │
│ (●Alle mit Aufgaben · 14)        │
│ (○Alle aktiven · 42)             │
│ (○Standort: [Regal A ▾] · 12)    │
│ [   RUNDGANG STARTEN   ]         │
```

**Aktiv (nach Scan)**
```text
┌──────────────────────────────────┐
│ Rundgang  7 / 14      ⏸  Beenden │
│ ▓▓▓▓▓▓▓░░░░░░░                   │
│                                  │
│ Messor barbarus · #12            │
│ Regal A / Ebene 3                │
│ 🔴 Protein 2 T  🟡 Wasser heute   │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ ⟳ Wie letztes Mal füttern     │ │
│ └──────────────────────────────┘ │
│ [ 🪲 Füttern ][ 💧 Wasser ✓ ]     │  ← ✓ = in diesem Rundgang erledigt
│ [ 🧹 Reinigen][ 👁 Kontrolle ]    │
│ [ ✎ Notiz   ][ 📷 Foto      ]    │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ ((( ))) NÄCHSTE KOLONIE      │ │
│ │ SCANNEN – oder Tag antippen  │ │
│ └──────────────────────────────┘ │
└──────────────────────────────────┘
```
- NFC-Reader bleibt aktiv: **nächsten Tag antippen = Weiter**, kein Button nötig.
- Bereits besuchte Kolonie erneut gescannt → Hinweis „Schon erledigt (Wasser, Füttern) – trotzdem öffnen?“.
- Kolonie außerhalb der Soll-Liste → wird ergänzt.
- „Offen“-Liste per Wischen nach oben: noch nicht gescannte Kolonien, sortiert nach Standort (Laufweg).
- Bildschirm bleibt an (Wakelock), solange der Rundgang aktiv ist.

**Abschluss**
```text
│ ✔ Pflege-Rundgang abgeschlossen  │
│ 28 / 30 Kolonien kontrolliert    │
│ 🪲 24 gefüttert  💧 18 Wasser     │
│ 🧹 6 gereinigt   ⚠ 1 Problem      │
│ Dauer 23 min                     │
│                                  │
│ NICHT GESCANNT (2)               │
│  Lasius #7   Keller      [Öffnen]│
│  Myrmica #2  Regal C/1   [Öffnen]│
│  [Als übersprungen markieren]    │
│ [ Fertig ]                       │
```

## S19 – Statistiken (Phase 9, Layout jetzt festgelegt)

- Kolonie: Zeitraum-Chips (7 T · 30 T · 3 M · 1 J · Gesamt); Karten: Koloniewachstum (Stufenlinie), Fütterungen pro Woche (gestapelte Balken Protein/KH), Wasser/Reinigung (Kalender-Heatmap), Temperatur/Luftfeuchte (Linie, Sensor + manuell), Brutentwicklung.
- Global: Kennzahlen (Kolonien, Arten, Gattungen, geschätzte Arbeiterinnen als Spanne, Fütterungen Woche/Monat, überfällig, Winterruhe), Verteilungen nach Art/Gattung/Standort (horizontale Balken).

## S20 – Einstellungen & Stammdaten

```text
│ Einstellungen                    │
│ KONTO      Anna · a@x.at      ›  │
│ GERÄTE & SITZUNGEN            ›  │
│ ERINNERUNGEN                     │
│   Tages-Überblick     18:00   ›  │
│   Überfällige einzeln   [●]      │
│   „Bald fällig“ ab    1 Tag   ›  │
│ PFLEGE                           │
│   Standard-Intervalle         ›  │
│   Futtermittel                ›  │
│   Standorte                   ›  │
│   Nester & Arenen             ›  │
│   Winterruhe-Verhalten        ›  │
│ DARSTELLUNG  Dunkel ▾            │
│ SYNCHRONISIERUNG                 │
│   ✓ vor 2 min · 0 ausstehend  ›  │
│   Fotos nur im WLAN     [●]      │
│ DATEN   Export · Papierkorb   ›  │
│ SERVER  ants.example.com v1.0 ›  │
│ Abmelden                         │
```
- **Standorte**: Baum mit Drag & Drop (Web) bzw. Einrück-Aktionen (Mobile); Anzahl Kolonien pro Knoten.
- **Synchronisierung**: Details mit ausstehenden Operationen, Konflikt-Hinweisen, „Jetzt synchronisieren“, „Neu laden vom Server“.

## S21 – Administration (Web)

Tabs: **Benutzer** (Liste, sperren, Admin-Rolle, Reset-Link) · **Einladungen** (Link erzeugen, Ablauf) · **Backups** (letzte Läufe, Größe, Verifikation, Anleitung Restore) · **System** (Version, Update verfügbar?, DB-/Foto-Speicher, Migrationsstand, HTTPS-/Konfigurationswarnungen).

## S22 – Scan-Einstieg ohne App (`/c/<token>` im Browser)

```text
┌──────────────────────────────────┐
│ 🐜 Ant Colony Manager            │
│                                  │
│ [ In der App öffnen ]            │  ← nur auf Android, Intent-Link
│                                  │
│ oder hier im Browser fortfahren: │
│ → Login  →  Kolonie              │
└──────────────────────────────────┘
```
Nicht angemeldet → Login → danach direkt zur Kolonie. Kein Zugriff → „Nicht gefunden“ ohne weitere Informationen.
