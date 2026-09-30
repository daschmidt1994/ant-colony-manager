# Ameisen mit KI zählen

Bei **„Größe & Brut“** zählt auf Wunsch eine KI (Anthropic Claude) die Ameisen auf Fotos der Kolonie – auch über mehrere Fotos, z. B. Vorder- und Rückseite des Nests oder Nest und Arena. Jedes Foto wird einzeln gezählt, die Zahlen werden addiert.

## Einrichten (Admin)

1. Bei [console.anthropic.com](https://console.anthropic.com) ein Konto anlegen, Guthaben aufladen und unter **API Keys** einen Schlüssel erzeugen.
2. App/Web → **Mehr → Server-Verwaltung → KI-Zählung**: „Zählen mit KI anbieten“ einschalten, Schlüssel eintragen, speichern. Der Schlüssel wird verschlüsselt gespeichert und nie angezeigt.
3. Modell: Standard `claude-opus-5-5` (am genauesten); günstiger `claude-sonnet-5-5`.

Die Kosten gehen auf das Anthropic-Konto – je nach Modell und Anzahl der Fotos einige Cent pro Zählung.

## Zählen

**Kolonie → Größe & Brut → „Mit KI zählen“** → bis zu 6 hochgeladene Fotos antippen (die Zahl zeigt die Reihenfolge) → „Fotos zählen“. Nach bis zu einer Minute:

- pro Foto die geschätzte Zahl mit Spanne, z. B. **120 (100–140)**, erkannte Königinnen und ein Hinweis, was das Zählen erschwert hat;
- **zusammen** die Summe mit Spanne;
- eine Warnung, falls die Fotos offenbar dieselben Ameisen zeigen (dann wäre die Summe zu hoch).

„Übernehmen“ trägt das Ergebnis ein – genau, wenn die Spanne geschlossen ist, sonst als Bereich (min–max). Vor dem Speichern lässt es sich noch ändern.

Gezählt werden erwachsene Ameisen (Arbeiterinnen, Soldaten, Königinnen, Geflügelte), keine Brut.

## Datenschutz

Nur die ausgewählten Fotos (in der 2048-px-Anzeigefassung, ohne Metadaten) gehen an Anthropic, sonst nichts. Ohne eingerichteten Schlüssel gibt es den Knopf nicht. Jede Zählung steht im Audit-Log des Servers.

## Schnittstelle

`POST /api/v1/colonies/{id}/ai-count` mit `{"photo_ids": [...]}` (1–6, hochgeladen, von dieser Kolonie; Bearbeitungsrecht nötig):

```json
{
  "photos": [
    {"photo_id": "…", "count": 120, "min": 100, "max": 140, "queens": 1, "note": ""},
    {"photo_id": "…", "count": 80, "min": 70, "max": 95, "queens": 0, "note": "Viele Ameisen verdeckt"}
  ],
  "total": 200, "min": 170, "max": 235, "overlap": false, "note": "", "model": "claude-opus-5-5"
}
```
