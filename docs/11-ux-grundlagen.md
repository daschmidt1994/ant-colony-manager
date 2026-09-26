# 11 – UX-Grundlagen & Designsystem

## 1. Leitlinien

| # | Regel | Konsequenz |
|---|---|---|
| 1 | **Scan ist die Haupt-Navigation** | Scan-Button auf jedem Hauptscreen erreichbar; im Rundgang ist der nächste Scan gleichzeitig „Weiter“ |
| 2 | **Häufiges mit 1 Tap, Seltenes mit 2** | Wasser/Kontrolle: sofort gespeichert. Füttern/Reinigung: Sheet mit vorausgewählten Standardwerten |
| 3 | **Rückgängig statt Nachfrage** | keine „Wirklich speichern?“-Dialoge; Snackbar 6 s mit **Rückgängig** + **Details** |
| 4 | **Voreinstellungen lernen** | jede Kolonie merkt sich die zuletzt benutzten Futtermittel, Mengen, Wasser- und Reinigungsarten |
| 5 | **Daumenzone** | Primäraktionen im unteren Drittel, große Flächen (≥ 56 dp, Quick Actions 72 dp), Bottom Sheets statt neuer Seiten |
| 6 | **Offline ist kein Fehlerzustand** | keine Warnbanner; nur ein dezentes Sync-Symbol |
| 7 | **Status nie nur über Farbe** | Ampel immer mit Symbol + Text („2 Tage überfällig“), farbenblind-tauglich |
| 8 | **Skaliert auf 100+ Kolonien** | Dashboard gruppiert pro *Kolonie* (nicht pro Aufgabe), Abschnitte einklappbar, Suche überall |
| 9 | **Zeitpunkt ist „jetzt“** | Nachtragen über Zeit-Chip („vor 1 h“, „gestern“, Datum wählen), nie ein Pflichtfeld |

## 2. Farben (Design-Tokens)

Anthrazit/Schwarz als Grundlage, **Moosgrün** als Akzent, **Honig/Ocker** als Zweitakzent. Kontraste für Text ≥ 4,5 : 1 (WCAG AA).

| Token | Dunkel (Standard) | Hell | Verwendung |
|---|---|---|---|
| `bg` | `#111315` | `#F5F5F1` | Hintergrund |
| `surface` | `#1A1D20` | `#FFFFFF` | Karten |
| `surface-2` | `#23272B` | `#ECECE6` | Sheets, Eingabefelder |
| `border` | `#2F3439` | `#D9DAD3` | Trennlinien |
| `text` | `#E9EBE6` | `#1B1E1C` | Fließtext |
| `text-muted` | `#9CA39D` | `#5D645F` | Sekundärtext |
| `accent` | `#7DB36F` (Moos) | `#3E7536` | Primärbuttons, aktive Navigation |
| `on-accent` | `#0E1A0B` | `#FFFFFF` | Text auf Akzent |
| `accent-2` | `#D8A94A` (Honig) | `#8C6414` | Kohlenhydrate, Hervorhebungen |
| `ok` 🟢 | `#5DB36A` | `#2E7D32` | alles okay |
| `soon` 🟡 | `#E2B340` | `#9A6B00` | bald fällig / heute |
| `overdue` 🔴 | `#E5655B` | `#C62828` | überfällig |
| `winter` ❄ | `#7FB4D9` | `#2F6F9E` | Winterruhe |

Kategorie-Farben (Timeline-Icons, Charts): Protein = Rotbraun `#C9785B` (bewusst vom Ampel-Rot unterscheidbar), Kohlenhydrate = `accent-2`, Wasser = `winter`, Reinigung = `text-muted`.

Theme: System / Hell / Dunkel (Einstellung). Standard ist **Dunkel** – angenehmer in abgedunkelten Ameisenräumen.

## 3. Typografie & Icons

- Schrift: **Inter** (gebündelt, keine externen Fonts), Zahlen mit Tabellenziffern (`tnum`) für Messwerte und Zähler.
- Skala: Titel 28/Bold · Kolonie-Name 22/SemiBold · Abschnitt 13/SemiBold/Versal (Letter-Spacing +0,6) · Text 16 · Sekundär 14 · Chip 14/Medium.
- Wissenschaftliche Namen immer *kursiv* (Konvention), Gattung + Art.
- Icons: **Material Symbols Rounded** (gebündelt) + ein kleines eigenes Set (Ameise, Königin, Brut, Nest, Reagenzglas). Emojis nur in Push-Texten, nicht in der UI.

| Ereignis | Icon | Ereignis | Icon |
|---|---|---|---|
| Fütterung Protein | `pest_control` (Insekt) | Koloniegröße | eigenes „Ameise“ |
| Fütterung KH | `water_drop` in Honigfarbe | Brut | eigenes „Ei“ |
| Wasser | `water_drop` | Nestwechsel | `home_work` |
| Reinigung | `mop` | Winterruhe | `ac_unit` |
| Kontrolle | `visibility` | Notiz | `sticky_note_2` |
| Messung | `thermostat` / `humidity_percentage` | Problem | `warning` |
| Foto | `photo_camera` | Königin | eigenes „Krone“ |

## 4. Abstände, Formen, Bewegung

- 4-dp-Raster; Seitenrand 16 dp; Kartenabstand 12 dp.
- Radien: Karten 16 dp, Buttons 14 dp, Chips 10 dp, Sheets 24 dp oben.
- Keine Schatten im Dunkelmodus (Flächen über `surface`-Stufen), leichte Schatten im Hellmodus.
- Animationen ≤ 200 ms; Scan-Erfolg: kurze Vibration (`HapticFeedback.mediumImpact`) + Häkchen-Animation. „Animationen reduzieren“ des Systems wird respektiert.

## 5. Navigation

### Mobile (Android, < 600 dp)

```text
┌──────────────────────────────────┐
│  Inhalt                          │
│                                  │
│                                  │
├──────────────────────────────────┤
│  🏠        🐜      ( ◉ )    🔁      ☰  │
│ Übersicht Kolonien  SCAN  Rundgang Mehr │
└──────────────────────────────────┘
```
- Scan in der Mitte als großer runder Button (64 dp), öffnet den **kombinierten Scanner** (Kamera für QR; NFC ist währenddessen ebenfalls aktiv).
- NFC ist zusätzlich auf *allen* Screens aktiv, solange die App im Vordergrund ist (Reader Mode) → Tag antippen öffnet von überall die Kolonie.
- „Mehr“: Statistiken, Standorte, Futtermittel, Etiketten, Export, Einstellungen.

### Tablet (600–900 dp)
Navigation Rail links, Kolonieliste und Kolonie nebeneinander im Querformat.

### Web/Desktop (≥ 900 dp)
```text
┌────────┬─────────────────────────────────────────────────────┐
│ 🐜 ACM  │  🔍 Suche (Strg+K)                  ↻ synchron   👤 │
│        ├─────────────────────────────────────────────────────┤
│ Übersicht                                                    │
│ Kolonien│                                                    │
│ Aufgaben│              Inhalt (Master-Detail)                │
│ Rundgang│                                                    │
│ Statistik                                                    │
│ Etiketten                                                    │
│ Stammdaten                                                   │
│ ───────│                                                    │
│ Einstellungen                                                │
│ Admin  │                                                    │
└────────┴─────────────────────────────────────────────────────┘
```
Tastaturkürzel: `Strg+K` Suche/Befehle · `N` neue Kolonie · `F`/`W`/`R` auf Kolonieseite = Füttern/Wasser/Reinigung · `J/K` nächste/vorige Kolonie.

## 6. Wiederverwendbare Komponenten

| Komponente | Beschreibung |
|---|---|
| `ScanFab` | runder Scan-Button, pulsiert kurz bei NFC-Bereitschaft |
| `QuickActionGrid` | 2 × 3 Kacheln à 72 dp, Icon + Label + Unterzeile („zuletzt vor 2 T“) |
| `DueChip` | Ampel-Chip: Symbol + Aufgabe + relative Zeit („Protein · 2 T überfällig“) |
| `ColonyTile` | Listenzeile: Statuspunkt, Name, *Art*, Standort, max. 3 DueChips |
| `ActionSheet` | Bottom Sheet mit Primärbutton unten („Speichern“), Zeit-Chip oben rechts |
| `ChipSelector` | Mehrfachauswahl (Wasser-/Reinigungsarten), zuletzt benutzte vorausgewählt |
| `Stepper` | Menge −/+ mit großer Zahl, Langdruck = schneller zählen |
| `RangePicker` | Schätzbereiche (1–10 … 10.000+) als horizontale Chip-Leiste |
| `UndoSnackbar` | „Wasser gespeichert · Rückgängig · Details“ |
| `SyncBadge` | ✓ / ↻ / Wolke durchgestrichen + Zahl / ⚠ |
| `EmptyState` | Illustration + eine klare Aktion |

## 7. Sprache & Texte

- Du-Form, kurz, fachlich korrekt („Nestwechsel“, „Winterruhe“, „Gyne“ nur im Glossar).
- Aktionen als Verben: „Füttern“, „Wasser“, „Reinigen“, „Kontrolle“.
- Relative Zeiten („vor 2 Tagen“, „heute 18:04“), absolute Datumsangaben im Detail (`12.04.2026`).
- Zahlen im deutschen Format (`25,4 °C`, `1.000`).

## 8. Barrierefreiheit

Schriftskalierung bis 200 % ohne abgeschnittene Buttons, TalkBack-Labels für alle Icons und Ampeln, Fokusreihenfolge im Web, Kontraste AA, keine rein farbcodierten Informationen, Scan auch per manueller Code-Eingabe möglich.
