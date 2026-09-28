# Benachrichtigungen per ntfy und E-Mail

Unter **Mehr → Erinnerungen → Benachrichtigungen per ntfy und E-Mail** wählst
du pro Thema den Kanal, wie oft erinnert wird und wann Ruhe ist. Die
Nachrichten kommen vom Server – auch wenn das Handy aus ist. Die
Android-App erinnert zusätzlich selbst (unverändert).

| Thema | Wann | Wiederholen, solange es besteht |
|---|---|---|
| Tages-Überblick | täglich zur Überblick-Uhrzeit, nur wenn etwas ansteht | – |
| Pflege überfällig | sobald eine Aufgabe überfällig ist; eine Nachricht je Kolonie | nur einmal · 6 h · 12 h · täglich |
| Sensor-Alarm | Messwert außerhalb der Grenzwerte (letzte 2 Stunden) | nur einmal · stündlich · 6 h · 12 h · täglich |
| Winterruhe | am geplanten Tag ab der Überblick-Uhrzeit | nur einmal · täglich |

Ist der Anlass vorbei (gefüttert, Messwert wieder normal, Winterruhe
umgeschaltet), beginnt die Zählung beim nächsten Mal von vorn.

**Ruhezeiten** (z. B. 22:00–07:00): keine Meldungen, danach kommen sie
gesammelt. Sensor-Alarme können trotzdem durchkommen (Schalter).

## ntfy einrichten

1. App **ntfy** installieren (F-Droid oder Play Store).
2. In der App **Topic abonnieren**:
   - **ntfy.sh** (öffentlich, kostenlos): einen schwer zu erratenden Namen
     wählen – wer den Namen kennt, kann mitlesen. Im Ant Colony Manager erzeugt
     der Würfel neben dem Feld einen zufälligen Namen.
   - **eigener ntfy-Server** (z. B. als Docker-Container auf dem Unraid):
     Server in der ntfy-App hinzufügen, Topic abonnieren, Zugriff per Token.
3. Im Ant Colony Manager eintragen:
   - **Server**: `https://ntfy.sh` (Standard) oder die Domain deines eigenen
     ntfy-Servers, z. B. `https://ntfy.meinedomain.at` (auch mit Unterpfad oder
     `http://192.168.1.10:8090` im Heimnetz)
   - **Topic**: z. B. `ameisen` (Buchstaben, Ziffern, `_`, `-`)
4. **Token** für einen eigenen Server mit Zugriffsschutz: `tk_…` (in ntfy mit
   `ntfy token add <benutzer>` erzeugen) oder `benutzer:passwort`.
   Es bleibt auf dem Server und wird nie an die Apps zurückgeschickt.
5. **Testnachricht senden**. Kommt nichts an: Adresse und Topic in der
   ntfy-App vergleichen; „ntfy lehnt ab (403)“ heißt Token/Berechtigung prüfen.

Sensor-Alarme kommen mit hoher Priorität, der Tages-Überblick mit niedriger.
Ein Tipp auf die Nachricht öffnet die Kolonie in der Web-App.

## E-Mail

Nur verfügbar, wenn der Server einen E-Mail-Versand hat – als Administrator
in der App unter **Mehr → Server-Verwaltung → E-Mail-Versand** einrichten. In der Testinstanz leer lassen, sonst kommen Nachrichten doppelt.

## Technik

- Einstellungen: `GET`/`PUT /api/v1/me/notifications`, Test: `POST /api/v1/me/notifications/test`
- Tabellen `notification_prefs` (nicht synchronisiert) und `notification_log`
  (was wann gemeldet wurde), Migration `0006_notifications.sql`
- Prüfung jede Minute im Server (`SendNotifications`, `SendDigests`)
