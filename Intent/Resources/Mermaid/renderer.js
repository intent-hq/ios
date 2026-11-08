(() => {
  'use strict';

  const pele = window.intentPele;
  const diagram = document.getElementById('diagram');
  const staging = document.getElementById('staging');
  let queue = Promise.resolve();
  let generation = 0;
  let renderedGeneration = 0;
  let renderedRevision;

  function post(message) {
    window.webkit?.messageHandlers?.mermaid?.postMessage(message);
  }

  function reportHeight() {
    if (renderedGeneration !== generation || renderedRevision === undefined) return;
    const height = Math.max(1, Math.ceil(diagram.getBoundingClientRect().height));
    post({ revision: renderedRevision, height });
  }

  function options(idPrefix) {
    const styles = getComputedStyle(document.documentElement);
    return {
      fontFamily: styles.getPropertyValue('--font').trim(),
      fontSize: parseFloat(styles.fontSize),
      idPrefix,
      responsive: false,
      autoDirection: false,
      links: false,
      images: false,
      limit: 50000,
      outputLimit: 4000000,
      maxEdges: 500,
    };
  }

  function sizeDiagram(svg, width, height) {
    if (![width, height].every(value => Number.isFinite(value) && value > 0)) {
      throw new Error('The diagram has no visible content.');
    }
    // Native scrolling and pinch zoom keep labels at their measured size.
    svg.setAttribute('width', String(width));
    svg.setAttribute('height', String(height));
    svg.style.width = `${width}px`;
    svg.style.height = `${height}px`;
    svg.style.maxWidth = 'none';
    svg.setAttribute('role', 'img');
    if (!svg.hasAttribute('aria-label') && !svg.hasAttribute('aria-labelledby')) {
      svg.setAttribute('aria-label', 'Mermaid diagram');
    }
    for (const anchor of svg.querySelectorAll('a')) {
      anchor.removeAttribute('href');
      anchor.removeAttribute('xlink:href');
      anchor.removeAttribute('target');
    }
  }

  window.renderMermaid = ({ source, dark = false, expanded = false, revision }) => {
    const currentGeneration = ++generation;
    const isCurrent = () => currentGeneration === generation;
    const render = async () => {
      await new Promise(resolve => setTimeout(resolve, 0));
      if (!isCurrent()) return;
      try {
        if (typeof source !== 'string' || !source.trim()) {
          throw new Error('The diagram is empty.');
        }
        if (source.length > 50000) throw new Error('The diagram is too large to render.');
        document.documentElement.classList.toggle('dark', Boolean(dark));
        document.documentElement.classList.toggle('expanded', Boolean(expanded));
        await Promise.all([
          document.fonts.load('400 13px Inter'),
          document.fonts.load('500 13px Inter'),
        ]);
        if (!isCurrent()) return;

        let renderSource = source;
        if (/^\s*stateDiagram(?:-v2)?\b/m.test(source) &&
            !/^\s*direction\s+(?:LR|RL|TB|BT)\b/m.test(source)) {
          renderSource = source.replace(/^(\s*stateDiagram(?:-v2)?\b[^\n]*)/m, '$1\n  direction TB');
        }
        const result = pele.render(renderSource, options(`diagram-${currentGeneration}`));
        staging.innerHTML = result.svg;
        const svg = staging.querySelector('svg');
        if (!svg) throw new Error('The diagram could not be rendered.');
        sizeDiagram(svg, result.width, result.height);
        diagram.replaceChildren(svg);
        renderedGeneration = currentGeneration;
        renderedRevision = revision;
        // A fullscreen web view can report completion before its first paint.
        reportHeight();
      } catch (error) {
        if (!isCurrent()) return;
        diagram.replaceChildren();
        renderedRevision = undefined;
        const message = error instanceof Error ? error.message : String(error);
        post({ revision, height: 1, error: message.slice(0, 600) });
      } finally {
        staging.replaceChildren();
      }
    };
    const result = queue.then(render, render);
    queue = result.catch(() => {});
    return result.then(() => null);
  };

  new ResizeObserver(reportHeight).observe(diagram);
  document.addEventListener('click', event => {
    if (event.target.closest?.('a')) event.preventDefault();
  }, true);
  post({ ready: true });
})();
