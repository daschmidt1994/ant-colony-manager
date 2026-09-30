# Benachrichtigungen: App, ntfy, E-Mail

Unter **Mehr → Erinnerungen → Benachrichtigungen** wählst du pro Thema die
Kanäle, wie oft erinnert wird und wann Ruhe ist:

- **App** – Android-Benachrichtigung, direkt vom Handy berechnet (funktioniert
  offline, die Einstellung gilt auf allen deinen Geräten)
- **ntfy** und **E-Mail** – vom Server, auch wenn das Handy aus ist

## „Morgen“ – heute keine Zeit

Überfällige Pflege, einzelne Aufgaben und die Winterruhe-Erinnerung haben
einen Knopf **„Morgen“** (in der App-Benachrichtigung und in ntfy; in der App
auch durch langes Drücken auf die Aufgabe auf der Kolonie-Seite):

- Pflege gilt bis morgen als nicht fällig – morgen „heute fällig“, übermorgen
  wieder überfällig. Wird inzwischen gefüttert, läuft das Intervall normal weiter.
- Winterruhe: der geplante Beginn bzw. das geplante Ende rückt um einen Tag.
- In ntfy funktioniert der Knopf ohne Anmeldung (signierter Link, 7 Tage gültig).

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

## App-Benachrichtigungen kommen nicht an

Die Android-App berechnet Erinnerungen selbst aus den lokalen Daten (auch offline) – der Server schickt keine Push-Nachrichten. **Mehr → Benachrichtigungen → „App auf diesem Gerät“** zeigt, woran es liegt:

| Anzeige | Bedeutung / Abhilfe |
|---|---|
| Benachrichtigungen blockiert | Android-Berechtigung fehlt → „Erlauben“ (öffnet sonst die System-Einstellungen) |
| Akku: optimiert | Die stündliche Hintergrund-Prüfung kann ausfallen → App-Infos → Akku „Nicht eingeschränkt“. **Xiaomi/Redmi/POCO:** zusätzlich „Autostart“ an; die App nicht aus der Liste der letzten Apps wegwischen (das beendet sie samt geplanten Erinnerungen) |
| Letzte Prüfung / Fehler | Wann die App zuletzt geprüft hat und ein etwaiger Fehler; „Jetzt prüfen“ führt die Prüfung sofort aus |
| Nächster Tages-Überblick | Wann der nächste Überblick geplant ist – keiner, wenn aus oder zu diesem Zeitpunkt nichts fällig ist |
| Test-Benachrichtigung | Zeigt sofort eine Benachrichtigung – kommt sie nicht, liegt es an Android (Berechtigung, Kanal in den System-Einstellungen aus) |

Die App meldet Pflege erst, wenn sie **überfällig** ist; „heute fällig“ steht nur im Tages-Überblick. E-Mail und ntfy kommen vom Server und hängen davon nicht ab.

## Technik

- Einstellungen: `GET`/`PUT /api/v1/me/notifications`, Test: `POST /api/v1/me/notifications/test`
- Tabellen `notification_prefs` (nicht synchronisiert) und `notification_log`
  (was wann gemeldet wurde), Migration `0006_notifications.sql`
- Prüfung jede Minute im Server (`SendNotifications`, `SendDigests`)
