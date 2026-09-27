# Anleitung: Installieren und auf dem Handy testen

Diese Anleitung führt vom leeren Rechner bis zum ausgefüllten Testbericht. Du brauchst:

- einen Rechner für den Server (Linux-PC, NAS, Raspberry Pi 4/5 o. ä.) mit **Docker** und **Docker Compose**
- ein **Android-Handy** (Android 8 oder neuer) im **selben WLAN** wie der Server
- einen Computer mit Browser für die Web-App (das kann der Server selbst sein)
- für die NFC-Tests: ein paar **NFC-Tags NTAG213 oder NTAG215** (Aufkleber genügen) und ein Handy mit NFC
- für die QR-Tests: einen Drucker (oder das Etikett einfach am Bildschirm anzeigen)

Zeitbedarf: Einrichtung etwa 20 Minuten, der Test selbst 1–2 Stunden. Einige Punkte (Hintergrund-Sync, Tages-Überblick nach Neustart) brauchen Wartezeit und lassen sich gut nebenher erledigen.

---

## 1. Server starten

Auf dem Server-Rechner im Terminal:

```bash
git clone https://github.com/daschmidt1994/ant-colony-manager.git
cd ant-colony-manager
./scripts/init-env.sh
```

`init-env.sh` legt die Datei `.env` an und trägt die IP-Adresse dieses Rechners als `PUBLIC_APP_URL` ein, z. B. `http://192.168.1.50:8080`. Diese Adresse brauchst du gleich im Browser und auf dem Handy. Prüfen mit:

```bash
grep PUBLIC_APP_URL .env
```

### Fertige Images

Die Images liegen öffentlich unter `ghcr.io/daschmidt1994/ant-colony-manager`; `docker compose up -d` lädt sie ohne Anmeldung. Meldet Docker `denied`, sind die Pakete noch nicht öffentlich geschaltet – dann baut Docker sie selbst (dauert einige Minuten, braucht mehr als 1 GB freien Arbeitsspeicher).

### Starten

```bash
docker compose up -d
docker compose ps
```

Nach etwa einer Minute sollten alle Dienste **healthy** sein.

### Admin-Konto anlegen

1. Setup-Code anzeigen:
   ```bash
   docker compose logs app | grep -A1 Setup-Code
   ```
2. Im Browser `http://<Server-IP>:8080/setup` öffnen (die Adresse aus `PUBLIC_APP_URL`).
3. Setup-Code, E-Mail, Name und Passwort eingeben → **Konto anlegen**.

Die Web-App ist jetzt bereit. Lege zum Warmwerden eine erste Kolonie an.

---

## 2. Android-App herunterladen

Die App wird bei jeder Änderung automatisch gebaut und als GitHub-Release veröffentlicht – Download **ohne GitHub-Konto**.

- **Direkt am Handy** diesen Link öffnen, er zeigt immer auf die neueste Version:
  <https://github.com/daschmidt1994/ant-colony-manager/releases/latest/download/app-arm64-v8a-release.apk>
- Alle Versionen: <https://github.com/daschmidt1994/ant-colony-manager/releases>
- Nur sehr alte Geräte brauchen stattdessen `app-armeabi-v7a-release.apk` (auf der Release-Seite).

---

## 3. App installieren

1. Die APK-Datei am Handy antippen (z. B. in **Dateien → Downloads**).
2. Android fragt nach der Erlaubnis, **Apps aus dieser Quelle** zu installieren → in den Einstellungen für die Dateien-App (bzw. den Browser) **zulassen**, zurück, **Installieren**.
3. Falls **Play Protect** warnt („unbekannte App“): **Details → Trotzdem installieren**. Die Warnung kommt, weil die App nicht aus dem Play Store stammt.

**Updates:** Eine neuere APK einfach genauso darüber installieren. Deine Daten bleiben erhalten, solange die APK aus der CI stammt (gleicher Signaturschlüssel). Eine vorhandene Installation vorher **nicht** deinstallieren, sonst sind noch nicht synchronisierte Einträge weg.

---

## 4. App mit dem Server verbinden

Der bequemste Weg ist ohne Passwort-Eingabe:

1. **Am Computer** in der Web-App: **Mehr → Android-App verbinden**. Es erscheint ein QR-Code.
2. **Am Handy** die App öffnen → **QR-Code aus der Web-App scannen** → Kamera erlauben → QR-Code scannen.
3. Die App meldet sich an und lädt alle Kolonien.

Alternative: Im ersten App-Bildschirm die **Server-Adresse** eingeben (genau wie `PUBLIC_APP_URL`, z. B. `http://192.168.1.50:8080`) → **Weiter** → mit E-Mail und Passwort anmelden.

Beim ersten Start fragt Android, ob die App **Benachrichtigungen** senden darf → **Zulassen**. Ohne diese Erlaubnis lassen sich die Erinnerungen nicht testen.

Empfehlung: Gleich unter **Mehr → Geräte & Sitzungen** dem Handy einen Namen geben (Stift bei „dieses Gerät“), siehe [15-anleitung-geraete.md](15-anleitung-geraete.md).

---

## 5. Test vorbereiten

- **Zwei bis drei Kolonien** anlegen, mindestens eine mit kurzen Intervallen (z. B. Wasser alle 2 Tage) und einem Standort, z. B. „Regal A“.
- **QR-Etikett:** **Mehr → Etiketten drucken** → Kolonie wählen → PDF drucken, oder die Vorschau einfach am Bildschirm lassen und abfotografieren.
- **NFC-Tag:** erst im Testpunkt C3 zuweisen.
- **Optional Sensor:** Für die Punkte H1/H2 genügt ein Computer mit `curl`; ein echter ESP32 ist nicht nötig. Siehe [14-sensoren.md](14-sensoren.md).
- **Energiesparen:** Bei Xiaomi, Huawei, Samsung & Co. für die App den Akku-Modus auf **„Nicht eingeschränkt“** stellen (App-Info → Akku). Sonst verzögert Android Hintergrund-Sync und Erinnerungen stark. Wenn du testen willst, wie es sich *mit* den Standardeinstellungen verhält, lass es und notiere das Ergebnis.

---

## 6. Testen mit der Testliste

Die Testliste ist eine Seite zum Abhaken: <https://claude.ai/artifact/U6kSNyDmEzmUrU3o5stgEM>

1. Die Seite am besten **am Computer** neben dem Handy öffnen (oder am Handy in einem zweiten Tab).
2. Oben **Handy und Android-Version** eintragen (z. B. „Pixel 7, Android 15“).
3. Die Punkte der Reihe nach durchgehen. Jeder Punkt sagt, **was du tun sollst** und **was passieren muss**. Dann tippen:
   - **OK** – passiert genau wie beschrieben
   - **Fehler** – etwas anderes passiert; im Feld darunter kurz notieren, *was* passiert ist (Meldungstext, bei welchem Schritt, ob es beim zweiten Versuch klappt)
   - **Übersprungen** – nicht testbar (z. B. kein NFC-Tag zur Hand)
4. Der Filter **„Noch nie auf Gerät getestet“** zeigt die wichtigsten Punkte. Wenig Zeit? Dann diese zuerst.
5. Der Fortschritt bleibt in diesem Browser gespeichert. Du kannst die Seite schließen und später weitermachen.

**Punkte mit Wartezeit** gleich zu Beginn anstoßen und später abhaken:

| Punkt | Wartezeit |
|---|---|
| D3 Hintergrund-Sync | 15–30 Minuten, App dabei geschlossen lassen |
| G1 Überfällige Aufgabe | App kurz in den Hintergrund und wieder öffnen, sonst bis zu 1 Stunde |
| G4 Tages-Überblick | Uhrzeit auf „in 5 Minuten“ stellen, bis zu ca. 15 Minuten Verzögerung sind normal |
| G5 Nach Neustart | wie G4, dazu Handy neu starten |

### Gute Fehlerbeschreibungen

Hilfreich ist zum Beispiel: *„C5: Tag angetippt bei geschlossener App → Android zeigt ‚Neues Tag gescannt, keine App unterstützt …‘ statt die Kolonie zu öffnen. Beim zweiten Mal gleich.“*

Wenig hilfreich ist dagegen: *„NFC geht nicht“*.

Bei Anzeige-Fehlern (abgeschnittener Text, falsche Zahlen) zusätzlich einen **Screenshot** machen (Ein/Aus + Leiser gleichzeitig) und im Chat anhängen.

---

## 7. Ergebnis zurückschicken

1. Auf der Testliste ganz unten **Befunde kopieren** tippen.
2. Den Text im Chat einfügen, bei Bedarf mit Screenshots.

Aus den Befunden werden die Korrekturen. Danach gibt es eine neue APK, die du wie in Schritt 3 **darüber installierst**. Die Testliste mit **Filter „Fehler“** zeigt dann genau die Punkte, die erneut geprüft werden müssen.

---

## Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| Handy findet den Server nicht („Server nicht erreichbar“) | Handy im **gleichen WLAN**? Nicht im Gäste-WLAN? Im Handy-Browser `http://<Server-IP>:8080` öffnen; geht das nicht, blockiert die Firewall des Servers Port 8080. |
| `docker compose ps` zeigt *unhealthy* | `docker compose logs app` – die fehlende oder falsche Einstellung steht direkt in der Meldung. |
| `denied` beim Starten der Images | Die Pakete sind (noch) nicht öffentlich – Docker baut dann selbst, das dauert. |
| Installation wird abgelehnt („App nicht installiert“) | Andere Variante probieren (`armeabi-v7a`), oder es ist eine ältere, anders signierte Version installiert: diese dann deinstallieren (Daten sind danach weg, vorher synchronisieren). |
| QR-Code der Web-App wird nicht erkannt | Bildschirmhelligkeit hoch, näher ran; notfalls Server-Adresse von Hand eingeben. |
| Keine Benachrichtigungen | Android-Einstellungen → Apps → Ant Colony Manager → Benachrichtigungen erlauben; Akku auf „Nicht eingeschränkt“. |
| QR-/NFC-Links zeigen eine falsche Adresse | `PUBLIC_APP_URL` in `.env` korrigieren, `docker compose up -d`. |

Mehr Hilfe zum Server: Abschnitt *Troubleshooting* in der [README](../README.md#troubleshooting).
