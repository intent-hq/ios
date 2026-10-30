import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import { chromium, webkit } from 'playwright';

const resources = new URL('../../Intent/Resources/Highlights/', import.meta.url);
const bundle = await readFile(new URL('highlights.bundle.js', resources), 'utf8');
function runtime(wasm = WebAssembly) {
  const context = vm.createContext({ window: {}, WebAssembly: wasm, TextEncoder, TextDecoder, TransformStream, atob });
  vm.runInContext(bundle, context);
  return context.window.intentHighlights;
}
const api = runtime();
await api.ready;
const highlight = async (source, path = 'demo.swift', dark = false) =>
  JSON.parse(JSON.stringify(await api.highlight({ source, path, dark })));

test('shipped assets match provenance', async () => {
  const vendor = JSON.parse(await readFile(new URL('vendor.json', resources)));
  const hash = bytes => createHash('sha256').update(bytes).digest('hex');
  for (const [name, expected] of Object.entries(vendor.assets)) {
    const bytes = await readFile(new URL(name, resources));
    assert.equal(hash(bytes), expected.sha256, name);
    assert.equal(bytes.length, expected.bytes, name);
  }
  assert.equal(hash(await readFile(new URL('package-lock.json', import.meta.url))), vendor.packageLockSha256);
  assert.equal(hash(await readFile(new URL('entry.js', import.meta.url))), vendor.entrySha256);
});

test('common extensions, aliases and special filenames resolve offline', async () => {
  for (const [path, language] of Object.entries({
    'src/App.SWIFT': 'swift', 'main.ts': 'typescript', 'view.tsx': 'tsx',
    'main.mts': 'typescript', 'main.cts': 'typescript', 'main.js': 'javascript',
    'main.cjs': 'javascript', 'view.jsx': 'jsx', 'lib.rs': 'rust',
    'main.py': 'python', 'types.pyi': 'python', 'main.go': 'go',
    'package.json': 'json', 'run.sh': 'bash', '.zshrc': 'bash',
    'source.c': 'c', 'source.h': 'c', 'source.cpp': 'cpp', 'source.hpp': 'cpp',
    'ci.yml': 'yaml', 'style.css': 'css', 'README.md': 'markdown',
    'Dockerfile': 'dockerfile', 'Containerfile.dev': 'dockerfile',
    'Makefile': 'makefile', 'CMakeLists.txt': 'cmake', '.env.local': 'dotenv',
    'Gemfile': 'ruby', 'C:\\src\\main.swift': 'swift',
  })) {
    const result = await highlight('value = 42', path);
    assert.equal(result.language, language, path);
    assert.ok(result.runs.length > 0, path);
  }
});

test('unknown paths and empty or invalid input return plain text', async () => {
  for (const path of ['LICENSE', 'image.png', 'source.unknown', 'notes.txt', 'constructor', 'file.__proto__']) {
    assert.deepEqual(await highlight('let value = 42', path), { language: null, runs: [] });
  }
  assert.deepEqual((await highlight('')).runs, []);
  assert.deepEqual((await highlight('a\0b')).runs, []);
  assert.equal((await api.highlight()).runs.length, 0);
  assert.equal((await api.highlight({ source: 42 })).runs.length, 0);
});

test('UTF-16 ranges preserve Unicode, BOM, CRLF and multiline lexer state', async () => {
  const source = '\uFEFFlet café = "😀e\u0301"\r\n/* first\r\nsecond 😀 */\r\nlet message = """\r\nhello 😀\r\nworld\r\n"""\r\n';
  const result = await highlight(source);
  assert.ok(result.runs.length > 8);
  let previousEnd = 0;
  for (const run of result.runs) {
    assert.ok(run.location >= previousEnd);
    assert.ok(run.length > 0 && run.location + run.length <= source.length);
    assert.match(run.color, /^#[a-f\d]{6}$/i);
    assert.ok(Number.isInteger(run.fontStyle) && run.fontStyle >= 0 && run.fontStyle <= 15);
    previousEnd = run.location + run.length;
  }
  const colorAt = text => {
    const position = source.indexOf(text);
    return result.runs.find(run => run.location <= position && run.location + run.length > position)?.color;
  };
  assert.equal(colorAt('first'), colorAt('second'));
  assert.equal(colorAt('hello'), colorAt('world'));
  assert.notEqual(colorAt('second'), colorAt('let'));
  assert.notEqual(colorAt('world'), colorAt('let'));
  assert.equal(result.runs.find(run => run.location === source.lastIndexOf('let'))?.length, 4);
});

test('light and dark themes differ without changing token ranges', async () => {
  const source = 'let name = "Pierre" // comment\n';
  const light = await highlight(source);
  const dark = await highlight(source, 'demo.swift', true);
  assert.deepEqual(light.runs.map(({ location, length }) => [location, length]),
    dark.runs.map(({ location, length }) => [location, length]));
  assert.notDeepEqual(light.runs.map(run => run.color), dark.runs.map(run => run.color));
});

test('source bytes, line length and token count have bounded fallbacks', async () => {
  assert.equal((await highlight('x\n'.repeat(262_145))).runs.length, 0);
  assert.equal((await highlight('😀\n'.repeat(110_000))).runs.length, 0);
  assert.equal((await highlight('x'.repeat(10_001))).runs.length, 0);
  assert.ok((await highlight('// ' + 'x'.repeat(9_997))).runs.length > 0);
  assert.ok((await highlight('let a=1\n'.repeat(14_000))).runs.length > 0);
  assert.equal((await highlight('let a=1\n'.repeat(20_000))).runs.length, 0);
  // A fallback does not poison the shared engine.
  assert.ok((await highlight('let value = 1')).runs.length > 0);
});

test('WebAssembly initialization failure remains a usable plain-text API', async () => {
  const broken = runtime({ Module() { throw new Error('Wasm unavailable'); } });
  assert.equal(await broken.ready, false);
  assert.equal(broken.status, 'failed');
  assert.equal((await broken.highlight({ source: 'let a = 1', path: 'a.swift' })).runs.length, 0);
});

for (const name of (process.env.HIGHLIGHTS_BROWSERS ?? 'chromium,webkit').split(',')) {
  test(`${name}: shipped file page works offline and never inserts source into DOM`, async () => {
    const browserType = { chromium, webkit }[name];
    assert.ok(browserType, `Unknown browser: ${name}`);
    const browser = await browserType.launch({ headless: true });
    try {
      const context = await browser.newContext({ offline: true });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      const requests = [];
      page.on('request', request => requests.push(request.url()));
      await page.goto(new URL('index.html', resources).href);
      assert.equal(await page.evaluate(() => window.intentHighlights.ready), true);
      for (const dark of [false, true]) {
        const result = await page.evaluate(async dark => {
          const source = 'const markup = "</script><img src=https://example.invalid onerror=alert(1)>😀";\r\n/* first\r\nsecond */';
          const highlighted = await window.intentHighlights.highlight({ source, path: 'demo.ts', dark });
          return { highlighted, body: document.body.innerHTML };
        }, dark);
        assert.ok(result.highlighted.runs.length > 0);
        assert.equal(result.body.trim(), '');
      }
      assert.deepEqual(errors, []);
      assert.ok(requests.every(url => url.startsWith('file:')), requests.join('\n'));
      // CSP, rather than offline mode alone, must prohibit network and eval.
      await context.setOffline(false);
      const security = await page.evaluate(async () => {
        const directives = [];
        document.addEventListener('securitypolicyviolation', event => directives.push(event.violatedDirective));
        try { await fetch('https://example.invalid/blocked'); } catch {}
        const script = document.createElement('script');
        script.textContent = 'window.sourceScriptExecuted = true';
        document.head.append(script);
        await new Promise(resolve => setTimeout(resolve, 50));
        return { directives, inlineBlocked: window.sourceScriptExecuted !== true };
      });
      assert.ok(security.directives.includes('connect-src'));
      assert.equal(security.inlineBlocked, true);
      const failedPage = await context.newPage();
      await failedPage.addInitScript(() => { window.WebAssembly = undefined; });
      await failedPage.goto(new URL('index.html', resources).href);
      assert.equal(await failedPage.evaluate(() => window.intentHighlights.ready), false);
      assert.equal(await failedPage.evaluate(async () =>
        (await window.intentHighlights.highlight({ source: 'let a = 1', path: 'a.swift' })).runs.length), 0);
    } finally {
      await browser.close();
    }
  });
}
