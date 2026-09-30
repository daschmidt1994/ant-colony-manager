# Kalender-Abo und Home Assistant

- **Kalender-Abo (iCal):** alle Fälligkeiten in Google Kalender, Outlook, Thunderbird, Apple Kalender oder im Kalender von Home Assistant – über eine private, **nur lesende** Adresse pro Benutzer.
- **Home Assistant (MQTT):** jede Kolonie als eigenes Gerät – Winterruhe an/aus, überfällige und heute fällige Pflege, nächste Pflege, letzter Messwert. **Neue Kolonien erscheinen von selbst**, archivierte oder abgegebene verschwinden wieder. Keine YAML-Konfiguration, kein Neustart.

## Kalender-Abo

App/Web → **Mehr → Kalender-Abo → „Adresse erzeugen“**. Die Adresse wird **nur einmal angezeigt** (wie ein Passwort behandeln). „Neue Adresse erzeugen“ macht die alte sofort ungültig, „Ausschalten“ entfernt sie.

```
https://<server>/api/v1/feeds/acm_fk_…/calendar.ics
```

Die Adresse enthält nur Lesezugriff auf die Kolonien, die du pflegst (Besitzer oder Pfleger – nicht nur „ansehen“); archivierte und abgegebene Kolonien fehlen. Einen Schreibzugriff gibt es darüber nicht.

| Eintrag | Wann |
|---|---|
| 🐜 *Aufgabe – Kolonie (#Nr, Art)* | nächster Termin jedes aktiven Pflegeplans; überfällige stehen **heute** mit „seit x Tagen überfällig“ |
| ❄ Winterruhe beginnen? | geplanter Beginn, solange sie nicht begonnen hat |
| ☀ Winterruhe beenden? | geplantes Ende einer laufenden oder geplanten Winterruhe |
| 📋 *Aufgabe* | offene einmalige Aufgaben mit Termin (30 Minuten) |

**Was im Kalender steht, wählst du selbst:** unter „Im Kalender anzeigen“ die Arten an- oder abwählen – Fütterung, Proteinfütterung, Kohlenhydratfütterung, Wasser, Reinigung, Kontrolle, eigene Pflegepläne, Winterruhe, einmalige Aufgaben. Z. B. nur „Winterruhe“ oder nur die Fütterungen. Die Auswahl gilt sofort für die bestehende Adresse (Kalender-Apps zeigen es beim nächsten Abruf) und bleibt beim Erzeugen einer neuen Adresse erhalten.

Pflege-Termine sind ganztägig und „frei“ (blockieren keine Zeit). Jeder Eintrag verlinkt auf die Kolonie in der Web-App. Kalender-Apps laden Abos selbst neu – Home Assistant und Thunderbird nach Einstellung, **Google teils nur alle 12–24 Stunden**.

**Home Assistant:** Einstellungen → Geräte & Dienste → Integration hinzufügen → **„Remote Calendar“** → Kalender-Adresse eintragen.

## Home Assistant über MQTT

Der ACM-Server meldet die Kolonien per **MQTT Discovery** bei Home Assistant an und hält ihren Zustand aktuell (alle 30 Sekunden, nach einer Änderung in der App nach wenigen Sekunden).

### Einrichten

1. In Home Assistant muss die **MQTT-Integration** laufen, meist mit dem **Mosquitto-Broker**-Add-on. Für ACM am besten einen eigenen Home-Assistant-Benutzer anlegen (z. B. `acm`) – mit dem meldet sich der Server beim Broker an.
2. In ACM als Administrator: **Mehr → Server-Verwaltung → Home Assistant (MQTT)**
   - **MQTT-Broker:** Adresse des Brokers, z. B. `192.168.178.199` oder `mqtt://192.168.178.199:1883` (Port 1883 ist Standard, `mqtts://…:8883` für TLS)
   - **Benutzer / Passwort** des Brokers (das Passwort wird verschlüsselt gespeichert)
   - **Discovery-Präfix:** `homeassistant` (nur ändern, wenn es in Home Assistant geändert wurde)
   - „Kolonien an Home Assistant senden“ einschalten, **Speichern**, **Verbindung testen**.
3. In Home Assistant erscheinen unter **Einstellungen → Geräte & Dienste → MQTT** das Gerät „Ameisen“ (Summen) und je Kolonie ein Gerät „Name (#Nr)“.

Gesendet werden die Kolonien des Administrators, der die Einstellungen gespeichert hat (Besitzer oder Pfleger – wie beim Kalender). Der ACM-Server muss den Broker im Netz erreichen (bei Docker: `192.168.x.x`, nicht `localhost`).

**Ausschalten** entfernt alle ACM-Geräte wieder aus Home Assistant. Ist ACM gestoppt, zeigen die Entitäten „nicht verfügbar“ (Last Will).

### Entitäten

Pro Kolonie (`3` = Kolonie-Nummer):

| Entität | Inhalt |
|---|---|
| `binary_sensor.acm_colony_3_hibernation` | Winterruhe an/aus |
| `sensor.acm_colony_3_overdue` | Anzahl überfälliger Pflege-Aufgaben |
| `sensor.acm_colony_3_due_today` | heute fällig |
| `sensor.acm_colony_3_next_due` | Zeitpunkt der nächsten Pflege (Attribute: `task`, `days`, `state`) |
| `sensor.acm_colony_3_next_task` | Name der nächsten Pflege, z. B. „Proteinfütterung“ |
| `sensor.acm_colony_3_temperature`, `…_humidity` | letzter Messwert – nur, wenn die Kolonie Messwerte hat |

Summen (Gerät „Ameisen“): `sensor.acm_overdue`, `sensor.acm_due_today`, `sensor.acm_hibernating`, `sensor.acm_colonies`.

Die Geräte hängen an der Kolonie, nicht an der Nummer: Umbenennen ändert nur den Anzeigenamen, die Entitäten bleiben. Entitäts-IDs kannst du in Home Assistant jederzeit selbst ändern.

### Heizmatte in der Winterruhe aus

Passend zum Thermostat aus [14-sensoren.md](14-sensoren.md): Startest du in ACM die Winterruhe, schaltet Home Assistant den Thermostat aus – und nach der Winterruhe wieder ein.

```yaml
automation:
  - alias: Formicarium – Heizung folgt der Winterruhe
    mode: restart
    triggers:
      - trigger: state
        entity_id: binary_sensor.acm_colony_3_hibernation
        to: ["on", "off"]
    actions:
      - if:
          - condition: state
            entity_id: binary_sensor.acm_colony_3_hibernation
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
        entity_id: sensor.acm_overdue
        above: 0
        for: { minutes: 30 }
    actions:
      - action: notify.notify
        data:
          title: Ameisen
          message: "{{ states('sensor.acm_overdue') }} Aufgaben überfällig"
```

### MQTT-Themen

Alle Nachrichten sind *retained* (QoS 1):

| Thema | Inhalt |
|---|---|
| `homeassistant/device/acm_<kolonie-id>/config` | Discovery je Kolonie (leer = Gerät entfernen) |
| `homeassistant/device/acm_summary/config` | Discovery der Summen |
| `ant-colony-manager/colony/<kolonie-id>/state` | Zustand einer Kolonie |
| `ant-colony-manager/state` | Summen `{overdue, due_today, hibernating, colonies}` |
| `ant-colony-manager/status` | `online` / `offline` |

Zustand einer Kolonie:

```json
{
  "name": "Messor", "number": 3, "species": "Messor barbarus", "status": "active",
  "hibernating": false, "overdue": 1, "due_today": 0,
  "next_due_at": "2026-09-27T08:00:00Z", "next_task": "Proteinfütterung",
  "next_due": { "task": "Proteinfütterung", "days": -2, "state": "overdue" },
  "temperature": 24.5, "humidity": 61, "measured_at": "2026-09-29T17:55:00Z"
}
```

`hibernating` ist wahr, wenn eine Winterruhe begonnen und nicht beendet ist (oder der Status der Kolonie „Winterruhe“ lautet). Startet Home Assistant neu (`homeassistant/status` = `online`), sendet ACM alles noch einmal.

### Umstieg von der früheren REST-Konfiguration

Die Status-Adresse `…/status.json` und der `rest:`-Block in `configuration.yaml` gibt es nicht mehr. Den `rest:`-Block mit `acm_…` aus `configuration.yaml` löschen, Home Assistant neu starten und in Automationen die neuen Entitäten eintragen (z. B. `binary_sensor.kolonie_3_winterruhe` → `binary_sensor.acm_colony_3_hibernation`).
