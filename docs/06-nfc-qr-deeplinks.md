# 06 – NFC, QR & Deep Links

## 1. Ein Link-Format für alles

```text
https://ants.example.com/c/7Kq2mZr9XbT4pLwA
└──── PUBLIC_APP_URL ───┘  └─ Token (16 Zeichen Base62, ≈ 95 Bit Zufall)
```

- **Token statt Kolonie-ID:** Tokens (`scan_links`) lassen sich **deaktivieren und neu generieren**, ohne die Kolonie zu verändern. Ein verlorenes/verkauftes Etikett wird einfach widerrufen.
- **Keine sensiblen Daten** auf Tag/QR: kein Name, keine Art, kein Fundort, keine Nutzer-ID.
- **Kein Recht durch Besitz des Links:** `/c/<token>` löst nur für angemeldete Nutzer mit Zugriff auf die Kolonie auf. Für alle anderen: „Nicht gefunden“ (kein Unterschied zwischen „gibt es nicht“ und „kein Zugriff“). Ein Link vergibt **niemals** Schreib- oder Leserechte.
- **Kurz** → QR-Code Version 3 (29×29 Module) bei Fehlerkorrektur M → auch als 15-mm-Etikett zuverlässig scanbar. NDEF-Größe ~40 Byte → passt auf jeden NTAG213.
- Der Host kommt aus `PUBLIC_APP_URL`. Ändert sich die Domain, bleiben Tokens gültig; die App akzeptiert zusätzlich alle in `LEGACY_APP_URLS` hinterlegten Hosts, und nur QR-Etiketten müssen ggf. neu gedruckt werden (NFC-Tags können in der App in einem Rutsch neu beschrieben werden).

## 2. Auflösung (online & offline)

```text
Token gescannt
   │
   ├─ lokal: SELECT colony_id FROM scan_links WHERE token=? AND active   (Drift, < 5 ms, offline)
   │     └─ gefunden → Kolonie öffnen ✔
   │
   ├─ nicht lokal, online: GET /api/v1/scan/{token}  → colony_id → Sync der Kolonie → öffnen
   │
   └─ nicht auflösbar:
         • deaktiviert  → „Dieser Code wurde deaktiviert. Neue Kolonie zuweisen?“
         • unbekannt, offline → „Unbekannter Code – wird beim nächsten Sync geprüft“
         • fremder Host → im Browser öffnen
```

Da `scan_links` Teil des Syncs sind, funktionieren **alle zugewiesenen Tags/QR-Codes vollständig offline**.

## 3. NFC-Konzept

### Tag-Empfehlung
| Tag | Nutzbar | Empfehlung |
|---|---|---|
| NTAG213 | 144 Byte | ✔ Standard, günstig, reicht völlig |
| NTAG215/216 | 504/888 Byte | ✔ |
| **On-Metal/Anti-Metall-Tags** | – | für Formicarien mit Metallteilen |
| MIFARE Classic | – | ✘ nicht NDEF-kompatibel auf vielen Geräten |

Aufkleber außen am Formicarium, ~3 cm Abstand zu Heizmatten/Metall.

### Tag-Inhalt (NDEF)
Genau **ein NDEF-URI-Record** (URI-Präfix-Code `0x04` = `https://`):
```text
[URI] ants.example.com/c/7Kq2mZr9XbT4pLwA
```
**Kein** Android Application Record (AAR): Ein AAR erzwingt die App und schickt ohne App in den Play Store – bei einer selbst verteilten App eine Sackgasse. Ohne AAR bleibt der Tag ein normaler Web-Link und funktioniert auch auf iPhones und fremden Handys (→ Browser → Login).

### Zuweisen

```text
Kolonie → „NFC-Tag zuweisen“
  ↓ App erzeugt scan_link (kind=nfc) lokal – offline möglich
  ↓ „Tag ans Handy halten“ (Reader Mode aktiv, Animation)
  ↓ Tag lesen:
      • leer/fremder Inhalt   → schreiben
      • bereits unser Link für DIESE Kolonie → „Schon zugewiesen ✔“
      • unser Link für ANDERE Kolonie → „Gehört zu Messor #7. Umhängen?“ → alter Link deaktiviert
      • schreibgeschützt      → nur UID registrieren (Fallback, s. u.)
  ↓ schreiben → zurücklesen & vergleichen (Verifikation)
  ↓ nfc_tags-Datensatz: uid_hash, tag_type, written_at
  ↓ optional: „Tag sperren“ (permanent, mit deutlicher Warnung) – Standard: aus
  ↓ Haptik + „Tag zugewiesen ✔“
```

**UID-Fallback:** Die Hardware-UID wird als `HMAC-SHA256(UID, INSTANCE_SECRET)` gespeichert. Damit erkennt die App auch Tags, die nicht beschreibbar sind oder deren Inhalt überschrieben wurde – allerdings nur, wenn die App im Vordergrund liest (UIDs lösen keinen System-Intent aus).

### Lesen – drei Situationen

| Situation | Mechanismus | Ergebnis |
|---|---|---|
| **App im Vordergrund** | `NfcAdapter.enableReaderMode` (via `nfc_manager`), Plattform-Sound unterdrückt, eigenes Haptik-Feedback | sofort, ohne Systemdialog; im Pflege-Rundgang dauerhaft aktiv |
| **App im Hintergrund / geschlossen** | Intent-Filter `NDEF_DISCOVERED`, `scheme=https`, `pathPrefix=/c/` | Android startet direkt die App (kein Auswahldialog), Route `/c/:token` |
| **App nicht installiert** | Android öffnet den URI im Browser | Web-App → Login → Kolonie |

```xml
<!-- AndroidManifest.xml (Ausschnitt) -->
<intent-filter>
    <action android:name="android.nfc.action.NDEF_DISCOVERED" />
    <category android:name="android.intent.category.DEFAULT" />
    <data android:scheme="https" android:host="*" android:pathPrefix="/c/" />
    <data android:scheme="http"  android:host="*" android:pathPrefix="/c/" />
</intent-filter>
```

Der NFC-Weg funktioniert **mit jeder Domain und auch mit `http://192.168.x.x`**, weil der NDEF-Dispatch keine Domain-Verifikation braucht. Die App prüft den Host gegen ihren konfigurierten Server; passt er nicht, wird der Link an den Browser weitergereicht.

Kaltstart-Optimierung: `/c/:token` wird direkt beim Start aufgelöst (Drift öffnen → Token-Lookup → Kolonie-Screen), das Dashboard wird *nicht* vorher geladen. Ziel < 3 s auf Mittelklasse-Geräten.

## 4. QR-Konzept

### QR-Codes pro Kolonie
- Beim Anlegen einer Kolonie entsteht automatisch ein `scan_link` (kind=qr).
- **Anzeigen**: Vollbild (für Scan von einem zweiten Gerät).
- **Herunterladen**: SVG/PNG (`/api/v1/scan-links/{id}/qr.svg`).
- **Drucken**: Etiketten-PDF (s. u.).
- **Neu generieren**: alter Token → `active=false`, neuer Token. Warnung: „Gedruckte Etiketten mit dem alten Code funktionieren dann nicht mehr.“
- **Deaktivieren**: ohne Ersatz.

### Scannen
| Weg | Ablauf |
|---|---|
| **In-App-Scanner** (Hauptweg) | großer „KOLONIE SCANNEN“-Button → `mobile_scanner` (Rückkamera, Autofokus, Taschenlampen-Toggle) → Token → lokal auflösen. Auch offline. |
| **Android-Kamera-App** | liest URL → siehe Abschnitt 5 (App Link bzw. Web) |
| **Ohne App** | Browser → Web-App → Login → Kolonie |

Der In-App-Scanner akzeptiert auch QR-Codes, die NFC-Links enthalten (gleiches Format), sowie den „App verbinden“-QR aus der Web-App.

## 5. Deep Links & App Links – die ehrliche Einschränkung

**Verifizierte Android App Links** (Kamera-App/Browser öffnet direkt die App) verlangen, dass die Domain **zur Build-Zeit** im Manifest steht und der Server unter `/.well-known/assetlinks.json` den Signatur-Fingerprint der APK ausliefert. Bei einer Self-Hosted-App kennt eine generische APK die Domain des Nutzers aber nicht.

Lösung in zwei Stufen:

| | Standard-APK (Release-Download) | Eigene APK („gebrandet“ für deine Domain) |
|---|---|---|
| NFC → App | ✔ (NDEF-Dispatch, s. o.) | ✔ |
| In-App-QR-Scan | ✔ | ✔ |
| Android-Kamera-QR → App | ↪ öffnet Web-Seite `/c/<token>` mit großem Button **„In der App öffnen“** (Intent-URL, ein zusätzlicher Tap) | ✔ direkt (verifizierter App Link) |
| Ohne App | Web-App | Web-App |
| Lokale IP / `http` | ✔ | App Links nur mit `https` |

- **Eigene APK**: GitHub-Actions-Workflow bzw. `scripts/build-apk.sh` mit `APP_LINK_HOST=ants.example.com` und eigenem Keystore. Der Server liefert `assetlinks.json` automatisch aus `ANDROID_APP_ID` + `ANDROID_CERT_SHA256`.
- **Intent-URL** auf der Web-Seite (Standard-APK):
  `intent://ants.example.com/c/<token>#Intent;scheme=https;package=at.antcolony.manager;S.browser_fallback_url=…;end`
  Ist die App nicht installiert, bleibt der Nutzer einfach in der Web-App.
- **Web-Seite `/c/<token>`** erkennt Android per User-Agent und zeigt den App-Button nur dort; ansonsten direkt die Web-Ansicht.

Da der **In-App-Scanner und NFC der primäre Workflow** sind, ist die Standard-APK voll alltagstauglich; die eigene APK ist ein Komfort-Upgrade.

**iOS (später):** Core NFC liest NDEF-URLs im Hintergrund (iPhone XS+) und öffnet Universal Links – dieselbe Build-Zeit-Einschränkung gilt (`apple-app-site-association`), dasselbe Link-Format funktioniert unverändert.

## 6. Etiketten

Erzeugung **clientseitig** mit dem Dart-Paket `pdf` (identisch in Web und Android, kein Server-Rendering, offline möglich).

```text
┌──────────────────────────┐
│ Messor barbarus          │
│ Kolonie #12              │
│  ┌────────┐              │
│  │ QR     │  Regal A /   │
│  │        │  Fach 3      │
│  └────────┘   ◉ NFC + QR │
└──────────────────────────┘
```

- **Vorlagen**: 25×25 mm, 38×25 mm, 50×30 mm, 62 mm Endlosband (Brother QL), A4-Bögen (z. B. Avery L7651 / L4732, Herma 4336), frei definierbar (Maße, Ränder, Spalten/Zeilen).
- **Modi**: einzelnes Etikett · Auswahl mehrerer Kolonien · kompletter Bogen · Startposition auf angebrochenem Bogen wählbar.
- **Felder** (ein-/ausblendbar): Art, Koloniename/Nummer, interner Code, Standort, NFC-Hinweis.
- QR immer mit Ruhezone ≥ 4 Module, minimale Kantenlänge 12 mm (Warnung darunter).
- Ausgabe: PDF (Download/Teilen) oder direkt drucken (`printing`).

## 7. Tests (vorgesehen für Phase 6)

| Szenario | Test |
|---|---|
| QR → richtige Kolonie | Widget-/Integrationstest: Token-Resolver mit lokaler DB, deaktivierte/fremde/unbekannte Tokens |
| NFC → richtige Kolonie | Unit-Test des NDEF-Parsers + Integrationstest mit gemocktem NFC-Plugin; manueller Gerätetest-Katalog |
| App offen + NFC | Reader Mode, Gerätetest |
| App geschlossen + NFC | `adb shell am start -a android.nfc.action.NDEF_DISCOVERED -d https://…/c/<token>` + Gerätetest |
| Kamera-QR → Deep Link → App | `adb shell am start -a android.intent.action.VIEW -d https://…/c/<token>` (eigene APK) |
| Ohne App → QR → Web | Playwright gegen `/c/<token>` (Login-Redirect, 404 bei fremder Kolonie) |
