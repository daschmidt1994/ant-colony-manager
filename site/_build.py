#!/usr/bin/env python3
"""Builds the homepage (site/index.html, site/en/index.html) from one template.
Edit the texts here, then run:  python3 site/_build.py
Published by .github/workflows/site.yml to https://daschmidt1994.github.io/ant-colony-manager/"""
import html
import pathlib

ROOT = pathlib.Path(__file__).parent
REPO = "https://github.com/daschmidt1994/ant-colony-manager"
FDROID = "https://daschmidt1994.github.io/ant-colony-manager/fdroid/repo"
FINGERPRINT = "BBCE52863C9584F4457D932A9FC0DF7EB5872B96E1940F502C747FF57EDB8863"
SITE = "https://daschmidt1994.github.io/ant-colony-manager/"

ANT = """<svg viewBox="0 0 512 512" aria-hidden="true"><rect width="512" height="512" rx="112" fill="#111315"/>
<g fill="#7DB36F" stroke="#7DB36F" stroke-linecap="round" stroke-linejoin="round">
<path d="M238 118 L214 74 L170 58 M274 118 L298 74 L342 58" fill="none" stroke-width="15"/>
<path d="M236 214 L186 186 L150 128 M276 214 L326 186 L362 128" fill="none" stroke-width="17"/>
<path d="M232 240 L168 246 L118 296 M280 240 L344 246 L394 296" fill="none" stroke-width="17"/>
<path d="M236 266 L184 312 L166 394 M276 266 L328 312 L346 394" fill="none" stroke-width="17"/>
<ellipse cx="256" cy="146" rx="46" ry="42" stroke="none"/><ellipse cx="256" cy="236" rx="31" ry="52" stroke="none"/>
<circle cx="256" cy="302" r="15" stroke="none"/><ellipse cx="256" cy="382" rx="64" ry="80" stroke="none"/></g></svg>"""


def icon(body):
    return (f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{body}</svg>')


ICONS = {
    "scan": icon('<path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3"/><path d="M8 12h8"/>'),
    "offline": icon('<path d="M4 9a13 13 0 0 1 16 0M7 12.5a8 8 0 0 1 10 0M10 16a3 3 0 0 1 4 0"/><circle cx="12" cy="19" r=".8" fill="currentColor"/>'),
    "due": icon('<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>'),
    "round": icon('<circle cx="6" cy="6" r="2"/><circle cx="18" cy="18" r="2"/><path d="M6 8v4a4 4 0 0 0 4 4h6"/>'),
    "bell": icon('<path d="M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>'),
    "book": icon('<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z"/><path d="M4 21V5M9 7h6"/>'),
    "chart": icon('<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>'),
    "camera": icon('<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>'),
    "shield": icon('<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/>'),
    "globe": icon('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>'),
    "sensor": icon('<path d="M10 14V5a2 2 0 1 1 4 0v9a4 4 0 1 1-4 0z"/><path d="M12 11v5"/>'),
    "tag": icon('<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="8.5" r="1.3"/>'),
    "home": icon('<path d="M3 11l9-7 9 7"/><path d="M5 10v10h14V10"/><path d="M10 20v-5h4v5"/>'),
    "calendar": icon('<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>'),
    "spark": icon('<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>'),
    "hand": icon('<path d="M3 13h4l4 3h4a2 2 0 0 0 0-4h-3"/><path d="M7 13l4-4h5l5 4"/><path d="M3 13v6h4"/>'),
    "backup": icon('<path d="M7 18a4 4 0 0 1-.6-8A6 6 0 0 1 18 9a4 4 0 0 1 0 9z"/><path d="M12 11v6M9.5 13.5L12 11l2.5 2.5"/>'),
    "box": icon('<path d="M3 7l9-4 9 4v10l-9 4-9-4z"/><path d="M3 7l9 4 9-4M12 11v10"/>'),
}
GITHUB = ('<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2a10 10 0 0 0-3.2 19.5c.5.1.7-.2.7-.5v-1.7'
          'c-2.8.6-3.4-1.3-3.4-1.3-.5-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.4 1.1 3 .8.1-.6.4-1.1.6-1.3'
          '-2.2-.3-4.6-1.1-4.6-5 0-1.1.4-2 1-2.7-.1-.3-.4-1.3.1-2.7 0 0 .8-.3 2.8 1a9.7 9.7 0 0 1 5 0c1.9-1.3 2.8-1 2.8-1 .6 1.4.2 '
          '2.4.1 2.7.6.7 1 1.6 1 2.7 0 3.9-2.4 4.7-4.6 5 .4.3.7.9.7 1.9v2.8c0 .3.2.6.7.5A10 10 0 0 0 12 2z"/></svg>')
DOWNLOAD = icon('<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>')

T = {
    "de": {
        "lang": "de", "other": "en", "other_label": "English", "base": "", "img": "img/de",
        "title": "Ant Colony Manager – Ameisenkolonien verwalten, selbst gehostet",
        "desc": "Ameisenkolonien pflegen mit NFC und QR: scannen, sehen was ansteht, mit einem Tap dokumentieren. "
                "Android-App und Web-App, offline-fähig, selbst gehostet, Open Source.",
        "nav": ["Funktionen", "Screenshots", "Installation", "F-Droid"],
        "eyebrow": "Selbst gehostet · Open Source · Deutsch & Englisch",
        "h1": "Deine Ameisenkolonien.<br>Ein Scan.",
        "lead": "Handy an den NFC-Tag halten oder den QR-Code scannen – die Kolonie ist offen, du siehst, was ansteht, "
                "und dokumentierst Fütterung, Wasser oder Reinigung mit einem Tap. Auch ohne Internet.",
        "flow": ["SCAN", "INFORMATION", "AKTION", "FERTIG"],
        "btn_fdroid": "App über F-Droid", "btn_github": "Auf GitHub", "btn_install": "Server installieren",
        "hero_alt": "Übersicht der App: Kolonien nach Dringlichkeit",
        "features_eyebrow": "Funktionen", "features_h": "Gebaut für den echten Pflegealltag",
        "features": [
            ("scan", "NFC-Tags & QR-Etiketten", "Pro Kolonie ein Tag oder Etikett – scannen öffnet sie sofort. Etiketten als PDF, auch als A4-Bogen."),
            ("due", "Fälligkeiten mit Ampel", "Protein, Kohlenhydrate, Wasser, Reinigung mit eigenem Intervall. Rot, gelb, grün – „Morgen“, wenn heute keine Zeit ist, oder aufschieben mit Grund: „Noch ausreichend Wasser“."),
            ("round", "Pflege-Rundgang", "Viele Kolonien nacheinander scannen und mit 1–2 Taps dokumentieren. Am Ende siehst du, was fehlt."),
            ("offline", "Offline zuerst", "Alles wird zuerst auf dem Gerät gespeichert und im Hintergrund synchronisiert – im Keller ohne Empfang geht nichts verloren."),
            ("bell", "Benachrichtigungen", "Per App, ntfy (auch eigener Server) oder E-Mail: Tages-Überblick, überfällige Pflege, Sensor-Alarm, Winterruhe."),
            ("book", "Artenkatalog", "Steckbriefe mit Klima, Winterruhe, Futter und Quellen – mit deinen Kolonien verknüpft. Dazu ein Futter-Ratgeber."),
            ("sensor", "Sensoren", "ESP32 & Co. senden Temperatur und Luftfeuchte direkt an deinen Server – mit Grenzwerten und Alarm."),
            ("chart", "Statistik & Bericht", "Fütterungen, Wachstum, Klima und Brut als Diagramm; Koloniebericht als PDF."),
            ("camera", "Fotos & Timeline", "Fotos aus Kamera oder Galerie – am Aufnahmetag in der Timeline. Wachstum im Vergleich und als Zeitraffer."),
            ("spark", "Ameisen mit KI zählen", "Fotos wählen – auch Vorder- und Rückseite des Nests – die KI zählt je Foto, die App addiert. Mit Claude, ChatGPT oder über OpenRouter."),
            ("home", "Home Assistant", "Jede Kolonie als Gerät per MQTT: überfällige Pflege, Winterruhe, Messwerte – mit Knöpfen „erledigt“ und Winterruhe-Schalter. Neue Kolonien erscheinen von selbst."),
            ("calendar", "Kalender-Abo", "Fälligkeiten in Google, Outlook oder Apple – mehrere Kalender, z. B. nur Winterruhe oder nur Fütterungen, jeder mit eigener Farbe."),
            ("hand", "Pflegevertretung", "Im Urlaub Kolonien zeitlich begrenzt an jemanden abgeben – mit Pflegeanweisungen. Du siehst, was erledigt wurde."),
            ("backup", "Backup außer Haus", "Jedes Backup zusätzlich auf Nextcloud, ein NAS (SMB, NFS) oder eine Storage Box – auf Wunsch verschlüsselt, Wiederherstellen per Skript."),
            ("box", "Futtervorrat & Widget", "Futtertiere und Zuchten mit Haltbarkeit und Nachbestell-Hinweis; „Ameisen – fällig“ als Widget auf dem Startbildschirm."),
        ],
        "shots_eyebrow": "Screenshots", "shots_h": "So sieht es aus",
        "shots": [("dashboard", "Übersicht"), ("colony", "Kolonie"), ("species-sheet", "Steckbrief"),
                  ("notifications", "Benachrichtigungen"), ("colony-stats", "Statistik"), ("timeline", "Timeline"),
                  ("species-catalog", "Artenkatalog")],
        "desktop_alt": "Die Web-App am Desktop",
        "how_eyebrow": "Loslegen", "how_h": "In drei Schritten",
        "steps": [
            ("Server starten", "Eine <code>docker compose</code>-Installation auf dem Heimserver, NAS oder Raspberry Pi – "
                                "fertige Vorlage für Unraid, Synology und Portainer."),
            ("App verbinden", "Android-App aus F-Droid installieren oder einfach die Web-App im Browser öffnen. "
                              "Anmelden per QR-Code aus der Web-App – ohne Passwort-Eingabe."),
            ("Kolonien markieren", "Kolonie anlegen, Etikett drucken oder NFC-Tag zuweisen – ab jetzt reicht ein Scan."),
        ],
        "install_h": "Installation", "install_p": "Voraussetzung: Docker mit Compose v2. Die Datenbank, Backups und Schlüssel richtet der Stack selbst ein.",
        "install_code": ('<span class="c"># herunterladen und starten</span>\n'
                         'git clone https://github.com/daschmidt1994/ant-colony-manager.git\n'
                         'cd ant-colony-manager\n./scripts/init-env.sh\ndocker compose up -d\n\n'
                         '<span class="c"># Setup-Code für das erste Konto</span>\n'
                         'docker compose logs app | grep -A1 Setup-Code'),
        "install_more": 'Danach <code>http://&lt;server&gt;:8080/setup</code> öffnen. Unraid, Synology, Portainer: '
                        f'<a href="{REPO}/blob/main/docs/17-unraid-dockhand.md">fertige Compose-Datei</a> · '
                        f'<a href="{REPO}#readme">ausführliche Anleitung</a>',
        "fdroid_h": "Android-App über F-Droid",
        "fdroid_steps": ["<a href=\"https://f-droid.org\">F-Droid</a> installieren (oder Droid-ify / Neo Store).",
                         "Einstellungen → Paketquellen → + und diesen QR-Code scannen oder den Link öffnen.",
                         "„Ant Colony Manager“ suchen und installieren – Updates kommen automatisch."],
        "fdroid_link": "Paketquelle hinzufügen", "fdroid_fp": "Fingerabdruck",
        "fdroid_apk": f'Ohne F-Droid: APK direkt aus den <a href="{REPO}/releases/latest">GitHub-Releases</a>.',
        "privacy_eyebrow": "Deine Daten", "privacy_h": "Selbst gehostet, ohne Umwege",
        "privacy": ["Läuft auf deiner Hardware – kein Konto bei uns, keine Cloud",
                    "Keine Telemetrie; nur eine abschaltbare Update-Prüfung gegen GitHub",
                    "Export als JSON, CSV und Fotos jederzeit",
                    "Tägliche Backups als normale Dateien, auf Wunsch zusätzlich außer Haus und verschlüsselt",
                    "KI-Zählung optional: nur die gewählten Fotos gehen an den Anbieter, den du einrichtest",
                    "Passwörter und Schlüssel verschlüsselt bzw. nur als Hash gespeichert",
                    "Open Source unter AGPL-3.0"],
        "footer": "Ein Hobbyprojekt für Ameisenhalter.",
        "foot_links": [("GitHub", REPO), ("Releases", f"{REPO}/releases"), ("Dokumentation", f"{REPO}/tree/main/docs"),
                       ("Lizenz AGPL-3.0", f"{REPO}/blob/main/LICENSE")],
    },
    "en": {
        "lang": "en", "other": "de", "other_label": "Deutsch", "base": "../", "img": "../img/en",
        "title": "Ant Colony Manager – self-hosted ant colony keeping",
        "desc": "Keep ant colonies with NFC and QR: scan, see what is due, record it with one tap. "
                "Android app and web app, works offline, self-hosted, open source.",
        "nav": ["Features", "Screenshots", "Install", "F-Droid"],
        "eyebrow": "Self-hosted · Open source · English & German",
        "h1": "Your ant colonies.<br>One scan.",
        "lead": "Hold your phone to the NFC tag or scan the QR code – the colony opens, you see what is due, "
                "and record feeding, water or cleaning with one tap. Even without internet.",
        "flow": ["SCAN", "INFORMATION", "ACTION", "DONE"],
        "btn_fdroid": "App via F-Droid", "btn_github": "On GitHub", "btn_install": "Install the server",
        "hero_alt": "App overview: colonies by urgency",
        "features_eyebrow": "Features", "features_h": "Built for everyday colony care",
        "features": [
            ("scan", "NFC tags & QR labels", "One tag or label per colony – scanning opens it right away. Labels as PDF, also as A4 sheets."),
            ("due", "Due dates at a glance", "Protein, carbohydrates, water, cleaning with their own interval. Red, yellow, green – “Tomorrow” when there's no time today, or defer with a reason: “Still enough water”."),
            ("round", "Care round", "Scan many colonies one after another and record with 1–2 taps. At the end you see what's missing."),
            ("offline", "Offline first", "Everything is saved on the device first and synced in the background – nothing gets lost in a basement without signal."),
            ("bell", "Notifications", "Via the app, ntfy (your own server too) or e-mail: daily overview, overdue care, sensor alarm, hibernation."),
            ("book", "Species catalogue", "Care sheets with climate, hibernation, food and sources – linked to your colonies. Plus a feeding guide."),
            ("sensor", "Sensors", "ESP32 & co. send temperature and humidity straight to your server – with limits and alarms."),
            ("chart", "Statistics & report", "Feedings, growth, climate and brood as charts; colony report as PDF."),
            ("camera", "Photos & timeline", "Photos from camera or gallery – on the day they were taken. Growth side by side and as a time-lapse."),
            ("spark", "Count ants with AI", "Choose photos – front and back of the nest too – the AI counts each, the app adds them up. With Claude, ChatGPT or via OpenRouter."),
            ("home", "Home Assistant", "Every colony as a device via MQTT: overdue care, hibernation, readings – with “done” buttons and a hibernation switch. New colonies appear by themselves."),
            ("calendar", "Calendar subscription", "Due dates in Google, Outlook or Apple – several calendars, e.g. only hibernation or only feedings, each in its own colour."),
            ("hand", "Care cover", "On holiday, hand colonies to someone for a period – with care instructions. You see what was done."),
            ("backup", "Off-site backup", "Every backup also to Nextcloud, a NAS (SMB, NFS) or a storage box – encrypted if you like, restore with a script."),
            ("box", "Food stock & widget", "Feeder insects and cultures with shelf life and reorder hint; “Ants – due” as a home screen widget."),
        ],
        "shots_eyebrow": "Screenshots", "shots_h": "Take a look",
        "shots": [("dashboard", "Overview"), ("colony", "Colony"), ("species-sheet", "Care sheet"),
                  ("notifications", "Notifications"), ("colony-stats", "Statistics"), ("timeline", "Timeline"),
                  ("species-catalog", "Species catalogue")],
        "desktop_alt": "The web app on the desktop",
        "how_eyebrow": "Get started", "how_h": "In three steps",
        "steps": [
            ("Start the server", "One <code>docker compose</code> install on your home server, NAS or Raspberry Pi – "
                                 "ready-made template for Unraid, Synology and Portainer."),
            ("Connect the app", "Install the Android app from F-Droid or just open the web app in the browser. "
                                "Sign in with a QR code from the web app – no password typing."),
            ("Tag your colonies", "Create a colony, print a label or assign an NFC tag – from now on one scan is enough."),
        ],
        "install_h": "Install", "install_p": "Requirement: Docker with Compose v2. The stack sets up database, backups and keys by itself.",
        "install_code": ('<span class="c"># download and start</span>\n'
                         'git clone https://github.com/daschmidt1994/ant-colony-manager.git\n'
                         'cd ant-colony-manager\n./scripts/init-env.sh\ndocker compose up -d\n\n'
                         '<span class="c"># setup code for the first account</span>\n'
                         'docker compose logs app | grep -A1 Setup-Code'),
        "install_more": 'Then open <code>http://&lt;server&gt;:8080/setup</code>. Unraid, Synology, Portainer: '
                        f'<a href="{REPO}/blob/main/docs/17-unraid-dockhand.md">ready-made compose file</a> · '
                        f'<a href="{REPO}#readme">full guide</a> (German)',
        "fdroid_h": "Android app via F-Droid",
        "fdroid_steps": ["Install <a href=\"https://f-droid.org\">F-Droid</a> (or Droid-ify / Neo Store).",
                         "Settings → Repositories → + and scan this QR code or open the link.",
                         "Search for “Ant Colony Manager” and install – updates arrive automatically."],
        "fdroid_link": "Add repository", "fdroid_fp": "Fingerprint",
        "fdroid_apk": f'Without F-Droid: the APK straight from the <a href="{REPO}/releases/latest">GitHub releases</a>.',
        "privacy_eyebrow": "Your data", "privacy_h": "Self-hosted, no detours",
        "privacy": ["Runs on your hardware – no account with us, no cloud",
                    "No telemetry; only an optional update check against GitHub",
                    "Export as JSON, CSV and photos at any time",
                    "Daily backups as plain files, optionally off-site and encrypted",
                    "AI counting is optional: only the chosen photos go to the provider you set up",
                    "Passwords and keys stored encrypted or only as a hash",
                    "Open source under AGPL-3.0"],
        "footer": "A hobby project for ant keepers.",
        "foot_links": [("GitHub", REPO), ("Releases", f"{REPO}/releases"), ("Documentation", f"{REPO}/tree/main/docs"),
                       ("License AGPL-3.0", f"{REPO}/blob/main/LICENSE")],
    },
}


def page(t):
    b = t["base"]
    other_href = b + ("en/" if t["other"] == "en" else "")
    feats = "\n".join(f'<div class="card">{ICONS[i]}<h3>{h}</h3><p>{p}</p></div>' for i, h, p in t["features"])
    shots = "\n".join(
        f'<figure><div class="phone"><img src="{t["img"]}/{f}.webp" width="520" height="1126" loading="lazy" alt="{html.escape(c)}"></div>'
        f'<figcaption>{c}</figcaption></figure>' for f, c in t["shots"])
    steps = "\n".join(f'<div class="card"><h3>{h}</h3><p>{p}</p></div>' for h, p in t["steps"])
    privacy = "\n".join(f"<li>{x}</li>" for x in t["privacy"])
    fsteps = "\n".join(f"<li>{x}</li>" for x in t["fdroid_steps"])
    foot = "\n".join(f'<a href="{u}">{n}</a>' for n, u in t["foot_links"])
    flow = ' <i>→</i> '.join(f"<span>{x}</span>" for x in t["flow"])
    nav = t["nav"]
    return f"""<!doctype html>
<html lang="{t['lang']}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
<meta name="description" content="{html.escape(t['desc'])}">
<meta property="og:title" content="Ant Colony Manager">
<meta property="og:description" content="{html.escape(t['desc'])}">
<meta property="og:image" content="{SITE}img/icon.png">
<meta property="og:type" content="website">
<link rel="alternate" hreflang="de" href="{SITE}">
<link rel="alternate" hreflang="en" href="{SITE}en/">
<link rel="icon" href="{b}img/icon.png">
<meta name="theme-color" content="#111315">
<link rel="stylesheet" href="{b}style.css">
</head>
<body>
<header class="top"><div class="wrap">
  <a class="brand" href="{b}{'' if t['lang'] == 'de' else 'en/'}">{ANT}<span>Ant Colony Manager</span></a>
  <nav class="nav">
    <a href="#features">{nav[0]}</a><a href="#screenshots">{nav[1]}</a><a href="#install">{nav[2]}</a><a href="#fdroid">{nav[3]}</a>
    <a class="lang" href="{other_href}" hreflang="{t['other']}">{t['other_label']}</a>
  </nav>
</div></header>

<main>
<section class="hero"><div class="wrap">
  <div>
    <div class="eyebrow">{t['eyebrow']}</div>
    <h1>{t['h1']}</h1>
    <p class="lead">{t['lead']}</p>
    <div class="flow">{flow}</div>
    <div class="buttons">
      <a class="btn primary" href="#fdroid">{DOWNLOAD}{t['btn_fdroid']}</a>
      <a class="btn" href="{REPO}">{GITHUB}{t['btn_github']}</a>
      <a class="btn" href="#install">{t['btn_install']}</a>
    </div>
  </div>
  <div class="phone"><img src="{t['img']}/dashboard.webp" width="520" height="1126" alt="{html.escape(t['hero_alt'])}"></div>
</div></section>

<section id="features"><div class="wrap">
  <div class="eyebrow">{t['features_eyebrow']}</div>
  <h2>{t['features_h']}</h2>
  <div class="grid">
{feats}
  </div>
</div></section>

<section id="screenshots" class="band"><div class="wrap">
  <div class="eyebrow">{t['shots_eyebrow']}</div>
  <h2>{t['shots_h']}</h2>
  <div class="shots">
{shots}
  </div>
  <img class="desktop" src="{t['img']}/desktop.webp" width="1400" height="875" loading="lazy" alt="{html.escape(t['desktop_alt'])}">
</div></section>

<section id="install"><div class="wrap">
  <div class="eyebrow">{t['how_eyebrow']}</div>
  <h2>{t['how_h']}</h2>
  <div class="steps">
{steps}
  </div>
  <div class="two" style="margin-top:48px">
    <div>
      <h3>{t['install_h']}</h3>
      <p class="muted">{t['install_p']}</p>
      <pre><code>{t['install_code']}</code></pre>
      <p class="muted">{t['install_more']}</p>
    </div>
    <div id="fdroid">
      <h3>{t['fdroid_h']}</h3>
      <div class="fdroid">
        <a href="{FDROID}?fingerprint={FINGERPRINT}"><img class="qr" src="{b}fdroid/repo/index.png" width="200" height="200" alt="QR {t['fdroid_link']}"></a>
        <ol class="muted">
{fsteps}
        </ol>
      </div>
      <p style="margin-top:16px"><a class="btn" href="{FDROID}?fingerprint={FINGERPRINT}">{t['fdroid_link']}</a></p>
      <p class="fp">{t['fdroid_fp']}: {FINGERPRINT}</p>
      <p class="muted">{t['fdroid_apk']}</p>
    </div>
  </div>
</div></section>

<section class="band"><div class="wrap">
  <div class="eyebrow">{t['privacy_eyebrow']}</div>
  <h2>{t['privacy_h']}</h2>
  <ul class="checks">
{privacy}
  </ul>
</div></section>
</main>

<footer><div class="wrap">
  <span>Ant Colony Manager · {t['footer']}</span>
  <nav>
{foot}
  </nav>
</div></footer>
</body>
</html>
"""


if __name__ == "__main__":
    (ROOT / "index.html").write_text(page(T["de"]), encoding="utf-8")
    (ROOT / "en").mkdir(exist_ok=True)
    (ROOT / "en" / "index.html").write_text(page(T["en"]), encoding="utf-8")
    print("site/index.html, site/en/index.html")
