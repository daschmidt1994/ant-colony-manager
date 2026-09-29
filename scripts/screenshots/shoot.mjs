// README screenshots of the web app (phone size, dark theme + one desktop view).
import { chromium } from 'playwright';
import fs from 'node:fs';

const base = process.env.BASE ?? 'http://127.0.0.1:8080';
const out = process.env.OUT ?? 'out';
const ids = JSON.parse(fs.readFileSync(process.env.IDS ?? 'ids.json', 'utf8'));
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();

async function signedIn(viewport) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 2.5, locale: 'de-DE', colorScheme: 'dark' });
  const page = await ctx.newPage();
  const res = await page.request.post(base + '/api/v1/auth/login', {
    headers: { 'X-ACM-Client': 'web', 'Content-Type': 'application/json' },
    data: { email: 'anna@ameisen.test', password: 'Formicarium-2026!' },
  });
  if (!res.ok()) throw new Error('login failed ' + res.status());
  return { ctx, page };
}

async function shot(page, path, file, wait = 3500) {
  await page.goto(base + path);
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await page.waitForTimeout(wait);
  await page.screenshot({ path: `${out}/${file}.png` });
  console.log('ok', file);
}

{
  const { ctx, page } = await signedIn({ width: 412, height: 892 });
  await shot(page, '/', 'dashboard', 7000); // first load: initial sync
  await shot(page, '/colonies', 'colonies');
  await shot(page, '/colonies/' + ids.messor, 'colony');
  await shot(page, '/colonies/' + ids.messor + '/stats', 'colony-stats');
  await shot(page, '/colonies/' + ids.messor + '/timeline', 'timeline');
  await shot(page, '/species', 'species-catalog');
  await shot(page, '/species/' + ids.species, 'species-sheet');
  await shot(page, '/settings/notifications', 'notifications');
  await ctx.close();
}
{
  const { ctx, page } = await signedIn({ width: 1280, height: 800 });
  await shot(page, '/', 'desktop-dashboard', 7000);
  await ctx.close();
}
await browser.close();
