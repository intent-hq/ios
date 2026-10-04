// npm ci && npx playwright install chromium webkit && npm test
// Loads file:// URLs with an app-shaped resource folder, with no web server.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { cp, copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium, webkit } from 'playwright';

const directory = dirname(fileURLToPath(import.meta.url));
const resources = resolve(directory, '../../Intent/Resources');
const fixture = await mkdtemp(resolve(tmpdir(), 'intent-mermaid-'));
await cp(resolve(resources, 'Mermaid'), resolve(fixture, 'Mermaid'), { recursive: true });
for (const font of ['Inter-Regular.ttf', 'Inter-Medium.ttf']) {
  await copyFile(resolve(resources, 'Fonts/Inter', font), resolve(fixture, font));
}

const diagrams = {
  flowchart: 'flowchart TD\n  A[Write a note] --> B{Ready?}\n  B -->|Yes| C[Share it]\n  B -->|No| A',
  sequence: 'sequenceDiagram\n  participant Phone\n  participant Server\n  Phone->>Server: Read notes\n  Server-->>Phone: Notes',
  state: 'stateDiagram-v2\n  [*] --> Draft\n  Draft --> Published: Save\n  Published --> [*]',
  class: 'classDiagram\n  class Note {\n    +String title\n    +save()\n  }\n  Notebook --> Note',
  elk: '---\nconfig:\n  layout: elk\n---\nflowchart LR\n  A[Offline] --> B[ELK layout]',
};

const engines = { chromium, webkit };
const selected = (process.env.MERMAID_BROWSERS || 'chromium,webkit').split(',');
for (const name of selected) assert.ok(engines[name], `Unknown browser: ${name}`);

try {
  for (const name of selected) {
    const engine = engines[name];
    const browser = await engine.launch({ headless: true });
    try {
      const page = await browser.newPage({
        viewport: { width: 375, height: 360 }, isMobile: true, hasTouch: true,
      });
      const errors = [];
      const network = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('request', request => {
        if (/^https?:/.test(request.url())) network.push(request.url());
      });
      await page.addInitScript(() => {
        window.messages = [];
        window.webkit = { messageHandlers: { mermaid: {
          postMessage: message => window.messages.push(message),
        } } };
      });
      await page.goto(pathToFileURL(resolve(fixture, 'Mermaid/index.html')).href);
      assert.equal(await page.evaluate(() => window.messages.some(message => message.ready)), true);

      async function render(source, options = {}) {
        const revision = `${name}-${randomUUID()}`;
        await page.evaluate(args => window.renderMermaid(args), { source, revision, ...options });
        const result = await page.evaluate(revision => ({
          message: window.messages.findLast(message => message.revision === revision),
          svg: Boolean(document.querySelector('#diagram > svg')),
          height: document.getElementById('diagram').getBoundingClientRect().height,
        }), revision);
        assert.ok(result.message, 'Every finished render reports its revision');
        assert.ok(Number.isFinite(result.message.height) && result.message.height > 0);
        return result;
      }

      for (const dark of [false, true]) {
        for (const [kind, source] of Object.entries(diagrams)) {
          const result = await render(source, { dark });
          assert.equal(result.message.error, undefined, `${kind}: ${result.message.error}`);
          assert.equal(result.svg, true);
          assert.ok(Math.abs(result.height - result.message.height) <= 1);
          assert.equal(await page.evaluate(() => document.fonts.check('400 13px Inter')), true);
          assert.equal(await page.evaluate(() => document.documentElement.classList.contains('dark')), dark);
        }
      }

      const invalid = await render('flowchart TD\n  A[');
      assert.ok(invalid.message.error);
      assert.equal(invalid.svg, false);
      assert.ok((await render('')).message.error);
      assert.ok((await render('x'.repeat(50001))).message.error);
      assert.equal((await render(diagrams.flowchart)).message.error, undefined, 'Errors do not poison the queue');

      // Source is an argument, never executable page markup. Source directives
      // cannot relax strict mode or permit callbacks/network loads.
      const hostile = `%%{init: {"securityLevel":"loose"}}%%\nflowchart TD\nA["<img src='https://example.invalid/x' onerror='window.compromised=true'>"] --> B["</script><script>window.compromised=true</script>"]\nclick A call compromised()`;
      await render(hostile);
      assert.equal(await page.evaluate(() => window.compromised), undefined);
      assert.equal(await page.locator('#diagram script, #diagram [onerror], #diagram [onclick]').count(), 0);
      assert.equal(await page.evaluate(() => window.intentMermaid.mermaidAPI.getConfig().securityLevel), 'strict');
      assert.deepEqual(network, [], 'Diagrams must not request network resources');

      // Enqueue a replacement while an actual render is still unresolved.
      const revisions = await page.evaluate(async () => {
        window.messages = [];
        const original = window.intentMermaid.render;
        let started;
        const begun = new Promise(resolve => { started = resolve; });
        let finish;
        const gate = new Promise(resolve => { finish = resolve; });
        window.intentMermaid.render = async (...args) => {
          started();
          await gate;
          return original(...args);
        };
        const old = window.renderMermaid({ source: 'flowchart TD\nA[Old]', revision: 'old' });
        await begun;
        const newest = window.renderMermaid({ source: 'flowchart TD\nB[Newest]', revision: 'newest' });
        finish();
        await Promise.all([old, newest]);
        window.intentMermaid.render = original;
        return window.messages.map(message => message.revision);
      });
      assert.ok(revisions.includes('newest'));
      assert.ok(!revisions.includes('old'), 'A stale in-flight render cannot publish height or content');
      assert.match(await page.locator('#diagram').textContent(), /Newest/);

      const wide = 'flowchart LR\nA[First readable step] --> B[Second readable step] --> C[Third readable step] --> D[Fourth readable step]';
      await render(wide);
      const sizes = await page.evaluate(() => ({
        content: document.documentElement.scrollWidth,
        viewport: window.innerWidth,
        width: document.querySelector('#diagram > svg').getBoundingClientRect().width,
        native: document.querySelector('#diagram > svg').viewBox.baseVal.width,
        scale: window.visualViewport.scale,
      }));
      assert.ok(sizes.content > 375, 'Wide charts retain a scrollable width');
      assert.ok(Math.abs(sizes.width - sizes.native) <= 1, 'Labels are not shrunk to fit');
      assert.ok(Math.abs(sizes.scale - 1) < 0.01, 'Mobile viewport does not scale wide charts down');
      await page.setViewportSize({ width: 700, height: 800 });
      const expanded = await render(diagrams.flowchart, { expanded: true, dark: true });
      assert.ok(expanded.message.height >= 800);
      assert.match(await page.locator('meta[name=viewport]').getAttribute('content'), /user-scalable=yes/);
      assert.ok(await page.locator('marker[data-diagram-chevron=true]').count() > 0);
      assert.deepEqual(errors, [], 'No unhandled browser errors');
      if (process.env.MERMAID_SCREENSHOT_DIR) {
        const screenshots = resolve(process.env.MERMAID_SCREENSHOT_DIR);
        await mkdir(screenshots, { recursive: true });
        await page.setViewportSize({ width: 390, height: 360 });
        for (const dark of [false, true]) {
          await render(diagrams.flowchart, { dark });
          const path = resolve(screenshots, `mermaid-${name}-${dark ? 'dark' : 'light'}.png`);
          await page.screenshot({ path, fullPage: true });
          console.log(`Screenshot: ${path}`);
        }
      }
      console.log(`${name}: PASS — both themes, five layouts, errors, security, stale revisions, sizing and expansion`);
    } finally {
      await browser.close();
    }
  }
} finally {
  await rm(fixture, { recursive: true, force: true });
}
