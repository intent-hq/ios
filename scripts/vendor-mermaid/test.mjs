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
const fixture = await mkdtemp(resolve(tmpdir(), 'intent-pele-'));
await cp(resolve(resources, 'Mermaid'), resolve(fixture, 'Mermaid'), { recursive: true });
for (const font of ['Inter-Regular.ttf', 'Inter-Medium.ttf']) {
  await copyFile(resolve(resources, 'Fonts/Inter', font), resolve(fixture, font));
}

const diagrams = {
  flowchart: 'flowchart TD\n  A[Write a note] --> B{Ready?}\n  B -->|Yes| C[Share it]\n  B -->|No| A',
  sequence: 'sequenceDiagram\n  participant Phone\n  participant Server\n  Phone->>Server: Read notes\n  Server-->>Phone: Notes',
  state: 'stateDiagram-v2\n  [*] --> Draft\n  Draft --> Published: Save\n  Published --> [*]',
  class: 'classDiagram\n  class Note {\n    +String title\n    +save()\n  }\n  Notebook --> Note',
  er: 'erDiagram\n  WORKSPACE ||--o{ NOTE : contains\n  NOTE {\n    string title\n    string body\n  }',
  pie: 'pie title Workspace activity\n  "Notes" : 45\n  "Tasks" : 35\n  "Reviews" : 20',
  xychart: 'xychart-beta\n  title "Completed tasks"\n  x-axis [Mon, Tue, Wed, Thu]\n  y-axis "Tasks" 0 --> 20\n  bar [5, 12, 8, 16]\n  line [4, 8, 12, 15]',
  gantt: 'gantt\n  title Release plan\n  dateFormat YYYY-MM-DD\n  section Build\n  App :a1, 2026-10-01, 3d\n  Tests :after a1, 2d',
  gitGraph: 'gitGraph\n  commit id: "Start"\n  branch feature\n  checkout feature\n  commit id: "Change"\n  checkout main\n  merge feature id: "Merge"',
  frontmatter: '---\ntitle: Offline workflow\nconfig:\n  layout: elk\n---\nflowchart LR\n  A[Offline] --> B[Local rendering]',
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
      assert.equal(await page.evaluate(() => typeof window.intentPele?.render), 'function');

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
      const tooManyEdges = `flowchart LR\n${Array.from({ length: 501 }, (_, i) => `N${i} --> N${i + 1}`).join('\n')}`;
      assert.ok((await render(tooManyEdges)).message.error, 'The 500-edge limit is enforced');
      assert.ok((await render(`---\nconfig:\n  maxEdges: 10000\n---\n${tooManyEdges}`)).message.error,
        'Frontmatter cannot raise the edge limit');
      assert.equal((await render(diagrams.flowchart)).message.error, undefined, 'Errors do not poison the queue');

      // Source is an argument, never executable page markup. Source directives
      // and frontmatter cannot enable links, images, or executable markup.
      const hostile = `%%{init: {"securityLevel":"loose"}}%%\nflowchart TD\nA["<img src='https://example.invalid/x' onerror='window.compromised=true'>"] --> B["</script><script>window.compromised=true</script>"]\nclick A call compromised()`;
      await render(hostile);
      assert.equal(await page.evaluate(() => window.compromised), undefined);
      assert.equal(await page.locator('#diagram script, #diagram [onerror], #diagram [onclick]').count(), 0);
      const securityCases = {
        link: 'flowchart LR\nA[Notes] --> B[Tasks]\nclick A href "https://example.invalid/notes" "Open notes"',
        image: 'flowchart LR\nA@{ img: "https://example.invalid/diagram.png", label: "External image", w: 80, h: 80 } --> B[Local]',
        frontmatter: '---\nconfig:\n  securityLevel: loose\n  links: true\n  images: true\n---\nflowchart LR\nA@{ img: "https://example.invalid/frontmatter.png", label: "Local", w: 80, h: 80 } --> B[Notes]\nclick B href "https://example.invalid/notes"',
        directive: '%%{init: {"securityLevel":"loose", "links":true, "images":true}}%%\nflowchart LR\nA@{ img: "https://example.invalid/directive.png", label: "Local", w: 80, h: 80 } --> B[Notes]\nclick B href "https://example.invalid/notes"',
      };
      for (const [kind, source] of Object.entries(securityCases)) {
        const result = await render(source);
        assert.equal(result.message.error, undefined, `${kind}: valid syntax still renders safely`);
        assert.equal(result.svg, true);
        assert.equal(await page.locator('#diagram a[*|href], #diagram image, #diagram img, #diagram script, #diagram foreignObject, #diagram [onclick], #diagram [onerror]').count(), 0,
          `${kind}: no active links, images, or executable content`);
      }
      assert.deepEqual(network, [], 'Diagrams must not request network resources');

      // Pele renders synchronously. Replace a request during asynchronous font
      // preparation instead, and prove the obsolete request never reaches Pele.
      const revisions = await page.evaluate(async () => {
        window.messages = [];
        const originalLoad = document.fonts.load;
        const originalRender = window.intentPele.render;
        const renderedSources = [];
        let started;
        const begun = new Promise(resolve => { started = resolve; });
        let finish;
        const gate = new Promise(resolve => { finish = resolve; });
        document.fonts.load = async (...args) => {
          started();
          await gate;
          return originalLoad.apply(document.fonts, args);
        };
        window.intentPele.render = (...args) => {
          renderedSources.push(args[0]);
          return originalRender(...args);
        };
        let timeout;
        try {
          const deadline = new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error('Font preparation must begin and finish')), 5000);
          });
          const old = window.renderMermaid({ source: 'flowchart TD\nA[Old]', revision: 'old' });
          await Promise.race([begun, deadline]);
          const newest = window.renderMermaid({ source: 'flowchart TD\nB[Newest]', revision: 'newest' });
          finish();
          await Promise.race([Promise.all([old, newest]), deadline]);
          return { messages: window.messages.map(message => message.revision), renderedSources };
        } finally {
          finish();
          clearTimeout(timeout);
          document.fonts.load = originalLoad;
          window.intentPele.render = originalRender;
        }
      });
      assert.ok(revisions.messages.includes('newest'));
      assert.ok(!revisions.messages.includes('old'), 'A stale in-flight render cannot publish height or content');
      assert.deepEqual(revisions.renderedSources, ['flowchart TD\nB[Newest]']);
      assert.match(await page.locator('#diagram').textContent(), /Newest/);

      for (const direction of ['LR', 'RL', 'TB', 'BT']) {
        await render(`flowchart ${direction}\nA[Origin] --> B[Destination]`);
        const positions = await page.evaluate(() => {
          const center = label => {
            const text = [...document.querySelectorAll('#diagram svg text')]
              .find(element => element.textContent.trim() === label);
            if (!text) throw new Error(`Missing node label: ${label}`);
            const bounds = text.getBoundingClientRect();
            return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
          };
          return { origin: center('Origin'), destination: center('Destination') };
        });
        const axis = ['LR', 'RL'].includes(direction) ? 'x' : 'y';
        const sign = ['LR', 'TB'].includes(direction) ? 1 : -1;
        assert.ok(sign * (positions.destination[axis] - positions.origin[axis]) > 0,
          `Explicit ${direction} direction survives a narrow viewport`);
      }

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
      const withoutAnimationFrames = await page.evaluate(async source => {
        const original = window.requestAnimationFrame;
        window.requestAnimationFrame = () => 0;
        let timeout;
        try {
          const deadline = new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error('Rendering must finish without animation frames')), 5000);
          });
          for (const revision of ['unpainted-first', 'unpainted-second']) {
            await Promise.race([window.renderMermaid({ source, revision, expanded: true }), deadline]);
          }
          return window.messages.filter(message => message.revision?.startsWith('unpainted-'));
        } finally {
          clearTimeout(timeout);
          window.requestAnimationFrame = original;
        }
      }, diagrams.flowchart);
      for (const revision of ['unpainted-first', 'unpainted-second']) {
        assert.ok(withoutAnimationFrames.some(message => message.revision === revision && message.height >= 800 && !message.error),
          'Offscreen rendering must report completion and leave the queue usable');
      }
      assert.match(await page.locator('meta[name=viewport]').getAttribute('content'), /user-scalable=yes/);
      if (process.env.MERMAID_SCREENSHOT_DIR) {
        const screenshots = resolve(process.env.MERMAID_SCREENSHOT_DIR);
        await mkdir(screenshots, { recursive: true });
        await page.setViewportSize({ width: 390, height: 360 });
        for (const dark of [false, true]) {
          for (const [kind, source] of Object.entries(diagrams)) {
            const result = await render(source, { dark });
            assert.equal(result.message.error, undefined, `${kind}: screenshot must contain a rendered diagram`);
            const path = resolve(screenshots, `pele-${name}-${kind}-${dark ? 'dark' : 'light'}.png`);
            await page.screenshot({ path, fullPage: true });
            console.log(`Screenshot: ${path}`);
          }
        }
      }
      assert.deepEqual(network, [], 'All diagrams and screenshots remain offline');
      assert.deepEqual(errors, [], 'No unhandled browser errors');
      console.log(`${name}: PASS — both themes, ${Object.keys(diagrams).length} fixtures, errors, security, limits, stale revisions, directions, sizing and expansion`);
    } finally {
      await browser.close();
    }
  }
} finally {
  await rm(fixture, { recursive: true, force: true });
}
