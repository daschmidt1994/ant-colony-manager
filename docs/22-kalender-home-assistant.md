# Kalender-Abo und Home Assistant

Eine private, **nur lesende** Adresse pro Benutzer, über die andere Programme deine Kolonien sehen:

- **Kalender (iCal):** alle Fälligkeiten in Google Kalender, Outlook, Thunderbird, Apple Kalender oder im Kalender von Home Assistant.
- **Status (JSON):** für Home Assistant – pro Kolonie Winterruhe an/aus, überfällige und heute fällige Pflege, letzter Messwert.

## Einrichten

App/Web → **Mehr → Kalender & Home Assistant → „Adresse erzeugen“**. Die Adressen werden **nur einmal angezeigt** (wie ein Passwort behandeln); darunter steht die fertige Home-Assistant-Konfiguration mit deinen Kolonien. „Neue Adresse erzeugen“ macht die alte sofort ungültig, „Ausschalten“ entfernt sie.

```
https://<server>/api/v1/feeds/acm_fk_…/calendar.ics
https://<server>/api/v1/feeds/acm_fk_…/status.json
```

Die Adresse enthält nur Lesezugriff auf die Kolonien, die du pflegst (Besitzer oder Pfleger – nicht nur „ansehen“); archivierte und abgegebene Kolonien fehlen. Einen Schreibzugriff gibt es darüber nicht.

## Kalender

| Eintrag | Wann |
|---|---|
| 🐜 *Aufgabe – Kolonie (#Nr, Art)* | nächster Termin jedes aktiven Pflegeplans; überfällige stehen **heute** mit „seit x Tagen überfällig“ |
| ❄ Winterruhe beginnen? | geplanter Beginn, solange sie nicht begonnen hat |
| ☀ Winterruhe beenden? | geplantes Ende einer laufenden oder geplanten Winterruhe |
| 📋 *Aufgabe* | offene einmalige Aufgaben mit Termin (30 Minuten) |

Pflege-Termine sind ganztägig und „frei“ (blockieren keine Zeit). Jeder Eintrag verlinkt auf die Kolonie in der Web-App. Kalender-Apps laden Abos selbst neu – Home Assistant und Thunderbird nach Einstellung, **Google teils nur alle 12–24 Stunden**.

**Home Assistant:** Einstellungen → Geräte & Dienste → Integration hinzufügen → **„Remote Calendar“** → Kalender-Adresse eintragen.

## Home Assistant: Status

Die App erzeugt die Konfiguration mit deinen Kolonie-Nummern. Aufbau:

```yaml
rest:
  - resource: "https://<server>/api/v1/feeds/acm_fk_…/status.json"
    scan_interval: 300
    sensor:
      - name: "Ameisen überfällig"
        unique_id: acm_overdue
        icon: mdi:ant
        value_template: "{{ value_json.overdue }}"
      - name: "Kolonie 3 überfällig"
        unique_id: acm_colony_3_overdue
        icon: mdi:ant
        value_template: "{{ value_json.by_number['3'].overdue | default(0) }}"
    binary_sensor:
      - name: "Kolonie 3 Winterruhe"
        unique_id: acm_colony_3_hibernating
        icon: mdi:snowflake
        value_template: "{{ value_json.by_number['3'].hibernating | default(false) }}"
```

Nach einem Neustart gibt es z. B. `sensor.ameisen_uberfallig`, `sensor.kolonie_3_uberfallig` und `binary_sensor.kolonie_3_winterruhe`.

### Heizmatte in der Winterruhe aus

Passend zum Thermostat aus [14-sensoren.md](14-sensoren.md): Startest du in ACM die Winterruhe, schaltet Home Assistant (spätestens nach 5 Minuten) den Thermostat aus – und nach der Winterruhe wieder ein.

```yaml
automation:
  - alias: Formicarium – Heizung folgt der Winterruhe
    mode: restart
    triggers:
      - trigger: state
        entity_id: binary_sensor.kolonie_3_winterruhe
        to: ["on", "off"]
    actions:
      - if:
          - condition: state
            entity_id: binary_sensor.kolonie_3_winterruhe
            state: "on"
        then:
          - action: climate.turn_off
            target:
              entity_id: climate.formicarium_heizung
        else:
          - action: climate.turn_on
            target:
              entity_id: climate.formicarium_heizung
```

### Ansage oder Push, wenn etwas überfällig ist

```yaml
automation:
  - alias: Ameisen – Pflege überfällig
    triggers:
      - trigger: numeric_state
        entity_id: sensor.ameisen_uberfallig
        above: 0
        for: { minutes: 30 }
    actions:
      - action: notify.notify
        data:
          title: Ameisen
          message: "{{ states('sensor.ameisen_uberfallig') }} Aufgaben überfällig"
```

## Status-Dokument

`GET /api/v1/feeds/<token>/status.json`:

```json
{
  "generated_at": "2026-09-29T18:00:00Z",
  "overdue": 1, "due_today": 2, "hibernating": 1,
  "colonies": [
    {
      "id": "…", "number": 3, "name": "Messor", "species": "Messor barbarus", "status": "active",
      "hibernating": false, "overdue": 1, "due_today": 0,
      "next_due": { "task": "Proteinfütterung", "at": "2026-09-27T08:00:00Z", "days": -2, "state": "overdue" },
      "winter": null,
      "temperature": 24.5, "humidity": 61, "measured_at": "2026-09-29T17:55:00Z"
    }
  ],
  "by_number": { "3": { "…": "dieselben Felder wie oben" } }
}
```

`hibernating` ist wahr, wenn eine Winterruhe begonnen und nicht beendet ist (oder der Status der Kolonie „Winterruhe“ lautet). `winter` enthält eine laufende oder geplante Winterruhe (`planned_start_on`, `started_on`, `planned_end_on`). Unbekannte Adressen antworten mit `404`; Abrufe sind pro IP begrenzt (Home Assistant alle 5 Minuten ist weit darunter).
