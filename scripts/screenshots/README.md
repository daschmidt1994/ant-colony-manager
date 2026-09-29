# README-Screenshots neu erstellen

1. Web-App bauen, in den Server einbetten, Server mit leerer Datenbank starten
   (`SETUP_TOKEN=screenshot-setup-token-123`, `PUBLIC_APP_URL=http://127.0.0.1:8080`).
2. Beispieldaten über die API anlegen: `python3 seed.py http://127.0.0.1:8080 ids.json`
3. Screenshots (Playwright/Chromium): `npm i playwright && npx playwright install chromium`,
   dann `OUT=../../docs/screenshots IDS=ids.json node shoot.mjs`
