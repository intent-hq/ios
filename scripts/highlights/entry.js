import pierreLight from '@pierre/highlights/themes/pierre-light';
import pierreDark from '@pierre/highlights/themes/pierre-dark';

const limits = Object.freeze({ sourceBytes: 512 * 1024, lineLength: 10_000, runs: 60_000 });
const extensions = new Map(Object.entries({
  ts: 'typescript', mts: 'typescript', cts: 'typescript', tsx: 'tsx',
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'jsx',
  py: 'python', pyi: 'python', rs: 'rust', sh: 'bash', bash: 'bash', zsh: 'bash',
  h: 'c', cc: 'cpp', cxx: 'cpp', hpp: 'cpp', hh: 'cpp', hxx: 'cpp',
  yml: 'yaml', md: 'markdown', htm: 'html', rb: 'ruby',
}));
const filenames = new Map(Object.entries({
  dockerfile: 'dockerfile', containerfile: 'dockerfile', makefile: 'makefile',
  gnumakefile: 'makefile', 'cmakelists.txt': 'cmake', gemfile: 'ruby',
  rakefile: 'ruby', '.bashrc': 'bash', '.bash_profile': 'bash', '.zshrc': 'bash',
  '.zprofile': 'bash', '.profile': 'bash', '.env': 'dotenv',
}));
let engine;
let status = 'loading';
// The upstream default entry compiles embedded Wasm during evaluation. Keep it
// inside a guarded import so unavailable/blocked Wasm still leaves a usable API.
const ready = import('@pierre/highlights').then(module => {
  engine = module;
  status = 'ready';
  return true;
}).catch(() => {
  status = 'failed';
  return false;
});

function languageForPath(path) {
  if (typeof path !== 'string' || !engine) return null;
  const name = path.replaceAll('\\', '/').split('/').pop().toLowerCase();
  let language = filenames.get(name);
  if (!language && name.startsWith('.env.')) language = 'dotenv';
  if (!language && /^(dockerfile|containerfile)\./.test(name)) language = 'dockerfile';
  if (!language && name.includes('.')) {
    const suffix = name.split('.').pop();
    language = extensions.get(suffix) ?? suffix;
  }
  if (!language || ['plain', 'plaintext', 'text', 'txt'].includes(language)) return null;
  return engine.isSupportedLanguage(language) ? language : null;
}

function withinBudget(source) {
  // UTF-16 length is a cheap lower bound before allocating encoded bytes.
  if (source.length > limits.sourceBytes || source.includes('\0')) return false;
  if (new TextEncoder().encode(source).length > limits.sourceBytes) return false;
  let length = 0;
  for (let index = 0; index < source.length; index++) {
    const code = source.charCodeAt(index);
    if (code === 10 || code === 13) length = 0;
    else if (++length > limits.lineLength) return false;
  }
  return true;
}

async function highlight({ source, path, dark = false } = {}) {
  if (typeof source !== 'string' || !withinBudget(source)) return { language: null, runs: [] };
  await ready;
  const language = languageForPath(path);
  const plain = { language, runs: [] };
  if (!language || !source.length) return plain;
  try {
    const result = engine.codeToTokens(source, {
      lang: language, theme: dark ? pierreDark : pierreLight,
      tokenizeMaxLineLength: limits.lineLength + 1,
    });
    const runs = [];
    let previousEnd = 0;
    for (const line of result.tokens) {
      for (const token of line) {
        const location = token.offset;
        const length = token.content.length;
        if (!length) continue;
        const color = token.color ?? result.fg;
        const fontStyle = token.fontStyle ?? 0;
        // Never send malformed ranges or CSS values across the native bridge.
        if (!Number.isSafeInteger(location) || location < previousEnd ||
            location + length > source.length ||
            source.slice(location, location + length) !== token.content ||
            !/^#[\da-f]{6}$/i.test(color) ||
            !Number.isInteger(fontStyle) || fontStyle < 0 || fontStyle > 15) return plain;
        if (runs.length >= limits.runs) return plain;
        runs.push({ location, length, color, fontStyle });
        previousEnd = location + length;
      }
    }
    return { language, runs };
  } catch {
    return plain;
  }
}

window.intentHighlights = Object.freeze({ highlight, ready, limits, get status() { return status; } });
