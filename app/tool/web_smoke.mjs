// Browser smoke test for the web app behind the real server (CSP, WASM,
// IndexedDB, no CDN). Signs in via the API (sets the HttpOnly cookie in the
// browser context), opens dashboard and colony page and takes screenshots.
// Fails on console errors or CSP violations.
import { chromium } from 'playwright';
import fs from 'node:fs';

const base = process.env.ACM_TEST_SERVER ?? 'http://127.0.0.1:8080';
const out = process.env.SHOT_DIR ?? 'screenshots';
fs.mkdirSync(out, { recursive: true });

const errors = [];
const browser = await chromium.launch();

async function session(viewport, name) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 2, locale: 'de-DE', colorScheme: 'dark' });
  const page = await ctx.newPage();
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(`[${name}] console: ${m.text()}`);
  });
  page.on('pageerror', (e) => errors.push(`[${name}] pageerror: ${e.message}`));
  await page.addInitScript(() => {
    document.addEventListener('securitypolicyviolation', (e) =>
      console.error(`CSP violation: ${e.violatedDirective} ${e.blockedURI}`));
  });
  return { ctx, page };
}

async function ready(page) {
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await page.waitForTimeout(4000); // first frames + initial sync
}

// Login page before signing in.
{
  const { ctx, page } = await session({ width: 412, height: 915 }, 'login');
  await page.goto(base + '/');
  await ready(page);
  await page.screenshot({ path: `${out}/1-login-mobile.png` });
  await ctx.close();
}

// Signed in: cookie via API login in the same browser context.
const colonyId = fs.readFileSync(process.env.COLONY_ID_FILE ?? 'colony_id', 'utf8').trim();
for (const [vp, tag] of [[{ width: 412, height: 915 }, 'mobile'], [{ width: 1280, height: 860 }, 'desktop']]) {
  const { ctx, page } = await session(vp, tag);
  const res = await page.request.post(base + '/api/v1/auth/login', {
    headers: { 'X-ACM-Client': 'web', 'Content-Type': 'application/json' },
    data: { email: 'contract@ants.test', password: 'Contract-Test-2026' },
  });
  if (!res.ok()) throw new Error('login failed: ' + res.status());
  await page.goto(base + '/');
  await ready(page);
  await page.screenshot({ path: `${out}/2-dashboard-${tag}.png` });
  await page.goto(base + '/colonies/' + colonyId);
  await ready(page);
  await page.screenshot({ path: `${out}/3-colony-${tag}.png` });
  await ctx.close();
}

await browser.close();
const relevant = errors.filter((e) => !e.includes('favicon'));
if (relevant.length) {
  console.error(relevant.join('\n'));
  process.exit(1);
}
console.log('web smoke test ok');
