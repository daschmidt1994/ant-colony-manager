# Benutzer verwalten (Admins)

**Einstellungen → Server-Verwaltung → Benutzer** – nur für Administratoren.

Die Liste zeigt jedes Konto mit Name, E-Mail, Rolle, letzter Anmeldung, Zahl der Kolonien und Fotos samt
Speicherplatz. **Kolonien und Inhalte anderer sieht ein Admin hier nicht.**

## Einladen

**„+ Einladen“** erstellt einen Einladungslink (1, 7, 14 oder 30 Tage gültig):

- mit **E-Mail**: nur diese Adresse kann sich damit registrieren
- ohne E-Mail: der Link gilt für jede Person, die ihn bekommt

Der Link wird nur einmal angezeigt – kopieren und per Messenger oder Mail schicken. Offene Einladungen stehen
unten in der Liste und lassen sich **zurückziehen**. Bei `REGISTRATION_MODE=invite` (Standard) ist das der Weg zu
neuen Konten; alternativ SSO mit „Neue Konten automatisch anlegen“ ([docs/28](28-sso-share.md)).

## Aktionen je Konto (Menü ⋮)

| Aktion | Wirkung |
|---|---|
| **Passwort-Link erstellen** | Link zum Setzen eines neuen Passworts, 30 Minuten gültig, einmal – auch ohne eingerichteten E-Mail-Versand |
| **Zum Admin machen / Admin-Rechte entziehen** | Admins verwalten Server-Einstellungen und Benutzer; fremde Kolonien sehen auch sie nicht |
| **Deaktivieren / Wieder aktivieren** | sofort auf allen Geräten abgemeldet, Anmelden gesperrt; alle Daten bleiben |
| **Konto löschen** | endgültig, mit allen eigenen Kolonien, Fotos (auch die Dateien), Chroniken und Einstellungen. Zur Bestätigung die E-Mail des Kontos eintippen. Mit anderen geteilte Kolonien verschwinden auch für sie |

Für das eigene Konto gibt es keine dieser Aktionen – so sperrt sich niemand versehentlich aus; das erledigt bei
Bedarf ein anderer Admin. Löschen wird im Audit-Log festgehalten; rückgängig nur über ein Backup
([docs/09](09-backup-restore.md)). Im Zweifel lieber **deaktivieren**.
