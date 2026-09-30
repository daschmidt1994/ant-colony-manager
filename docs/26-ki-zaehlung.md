# Ameisen mit KI zählen

Bei **„Größe & Brut“** zählt auf Wunsch eine KI – **Claude** (Anthropic), **ChatGPT** (OpenAI) oder ein Modell über **OpenRouter** – die Ameisen auf Fotos der Kolonie – auch über mehrere Fotos, z. B. Vorder- und Rückseite des Nests oder Nest und Arena. Jedes Foto wird einzeln gezählt, die Zahlen werden addiert.

## Einrichten (Admin)

App/Web → **Mehr → Server-Verwaltung → KI-Zählung**: Anbieter wählen, Schlüssel und Modell eintragen, „Zählen mit KI anbieten“ einschalten, speichern. Der Schlüssel wird verschlüsselt gespeichert und nie angezeigt; beim Wechsel des Anbieters braucht es dessen Schlüssel.

| Anbieter | Schlüssel | Modell |
|---|---|---|
| **Claude** (Anthropic) | [console.anthropic.com](https://console.anthropic.com) → API Keys, Guthaben unter Billing | Standard `claude-opus-5-5` (am genauesten), günstiger `claude-sonnet-5-5` |
| **ChatGPT** (OpenAI) | [platform.openai.com](https://platform.openai.com) → API keys, Guthaben unter Billing | ein Modell, das Bilder versteht – siehe [Modellliste](https://platform.openai.com/docs/models) |
| **OpenRouter** | [openrouter.ai](https://openrouter.ai) → Keys, Guthaben unter Credits | Modell-ID aus [openrouter.ai/models](https://openrouter.ai/models) mit Eingabe „image“, z. B. `anthropic/…`, `openai/…`, `google/…` |

ChatGPT und OpenRouter werden über dieselbe Schnittstelle (Chat Completions mit JSON-Schema) angesprochen. Nicht jedes Modell bei OpenRouter kann ein festes JSON-Format liefern – meldet die KI einen Fehler, ein anderes Modell wählen.

Die Kosten gehen auf das Konto beim Anbieter – je nach Modell und Anzahl der Fotos meist einige Cent pro Zählung. Fehlt Guthaben, sagt die App das so.

## Zählen

**Kolonie → Größe & Brut → „Mit KI zählen“** → bis zu 6 hochgeladene Fotos antippen (die Zahl zeigt die Reihenfolge) → „Fotos zählen“. Nach bis zu einer Minute:

- pro Foto die geschätzte Zahl mit Spanne, z. B. **120 (100–140)**, erkannte Königinnen und ein Hinweis, was das Zählen erschwert hat;
- **zusammen** die Summe mit Spanne;
- eine Warnung, falls die Fotos offenbar dieselben Ameisen zeigen (dann wäre die Summe zu hoch).

„Übernehmen“ trägt das Ergebnis ein – genau, wenn die Spanne geschlossen ist, sonst als Bereich (min–max). Vor dem Speichern lässt es sich noch ändern.

Gezählt werden erwachsene Ameisen (Arbeiterinnen, Soldaten, Königinnen, Geflügelte), keine Brut.

## Datenschutz

Nur die ausgewählten Fotos (in der 2048-px-Anzeigefassung, ohne Metadaten) gehen an den gewählten Anbieter, sonst nichts (bei OpenRouter weiter an den Anbieter des Modells). Ohne eingerichteten Schlüssel gibt es den Knopf nicht. Jede Zählung steht im Audit-Log des Servers.

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
