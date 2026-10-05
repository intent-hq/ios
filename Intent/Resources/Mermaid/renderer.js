(() => {
  'use strict';

  const mermaid = window.intentMermaid;
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

  function configuration(source) {
    const styles = getComputedStyle(document.documentElement);
    const color = name => styles.getPropertyValue(`--${name}`).trim();
    const foreground = color('foreground');
    const canvas = color('canvas');
    const surface = color('surface');
    const muted = color('muted');
    const border = color('border');
    const connector = color('connector');
    const metadata = color('metadata');
    const accent = color('accent');
    const fontFamily = 'Inter, system-ui, -apple-system, sans-serif';
    const htmlLabels = /^\s*(?:flowchart|graph)\s/m.test(source);

    // Match the desktop base theme and layout defaults. Security is deliberately
    // stricter here: diagrams are content, with no callbacks or external links.
    return {
      startOnLoad: false,
      securityLevel: 'strict',
      suppressErrorRendering: true,
      dompurifyConfig: {
        FORBID_TAGS: ['img', 'image', 'video', 'audio', 'iframe', 'object', 'embed'],
        FORBID_ATTR: ['src', 'srcset'],
      },
      maxTextSize: 50000,
      maxEdges: 500,
      secure: [
        'secure', 'securityLevel', 'startOnLoad', 'suppressErrorRendering',
        'maxTextSize', 'maxEdges', 'dompurifyConfig',
      ],
      theme: 'base',
      fontFamily,
      fontSize: 13,
      htmlLabels,
      layout: /^\s*(?:stateDiagram(?:-v2)?|erDiagram)\b/m.test(source) ? 'elk' : 'dagre',
      themeCSS: '.label, foreignObject { transition: none !important; }',
      flowchart: {
        useMaxWidth: false, curve: 'basis', diagramPadding: 8,
        nodeSpacing: 48, rankSpacing: 48, padding: 9, wrappingWidth: 120,
      },
      sequence: {
        useMaxWidth: false, wrap: true, mirrorActors: false,
        actorMargin: 0, diagramMarginX: 0, boxMargin: 8, boxTextMargin: 6,
        noteMargin: 4, messageMargin: 24, width: 96, wrapPadding: 6,
      },
      class: { defaultRenderer: 'dagre-d3', htmlLabels: false },
      state: { defaultRenderer: 'dagre-d3', nodeSpacing: 48, rankSpacing: 48, padding: 8 },
      themeVariables: {
        background: canvas,
        primaryColor: surface, primaryTextColor: foreground, primaryBorderColor: surface,
        secondaryColor: muted, secondaryTextColor: foreground, secondaryBorderColor: muted,
        tertiaryColor: canvas, tertiaryTextColor: foreground, tertiaryBorderColor: border,
        lineColor: connector, arrowheadColor: connector, textColor: foreground,
        mainBkg: surface, nodeBkg: surface, nodeBorder: surface, nodeTextColor: foreground,
        clusterBkg: canvas, clusterBorder: border, defaultLinkColor: connector,
        edgeLabelBackground: canvas, titleColor: foreground,
        actorBkg: surface, actorBorder: surface, actorTextColor: foreground,
        actorLineColor: border, signalColor: connector, signalTextColor: foreground,
        labelBoxBkgColor: muted, labelBoxBorderColor: border,
        labelTextColor: foreground, loopTextColor: foreground,
        activationBkgColor: accent, activationBorderColor: border,
        noteBkgColor: accent, noteBorderColor: border, noteTextColor: color('accent-foreground'),
        transitionColor: connector, transitionLabelColor: metadata,
        stateBkg: surface, stateLabelColor: foreground, labelBackgroundColor: canvas,
        compositeBackground: canvas, compositeTitleBackground: canvas, compositeBorder: border,
        classText: foreground, fillType0: surface, fillType1: muted, fontFamily,
      },
    };
  }

  function sizeDiagram(svg) {
    const bounds = svg.viewBox.baseVal;
    const width = bounds.width || svg.getBBox().width;
    const height = bounds.height || svg.getBBox().height;
    if (![width, height].every(value => Number.isFinite(value) && value > 0)) {
      throw new Error('The diagram has no visible content.');
    }
    // Keep text at its measured size. Wide diagrams scroll horizontally instead
    // of shrinking to fit a phone. WKWebView supplies inline and fullscreen pinch zoom.
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

  // Desktop's small open arrowheads; retain semantic diamonds/circles for UML.
  function styleArrowheads(svg) {
    for (const marker of svg.querySelectorAll('marker')) {
      const path = marker.querySelector('path');
      const shared = marker.id.endsWith('-arrowhead');
      const end = marker.id.includes('pointEnd') || marker.id.includes('barbEnd') || shared;
      if (!path || (!end && !marker.id.includes('pointStart'))) continue;
      marker.setAttribute('viewBox', '0 0 7 7');
      marker.setAttribute('markerWidth', '7');
      marker.setAttribute('markerHeight', '7');
      marker.setAttribute('refX', end ? '6.5' : '0.5');
      marker.setAttribute('refY', '3.5');
      marker.setAttribute('orient', shared ? 'auto-start-reverse' : 'auto');
      marker.setAttribute('markerUnits', 'userSpaceOnUse');
      marker.dataset.diagramChevron = 'true';
      path.setAttribute('d', end
        ? 'M 3.5 0.5 L 6.5 3.5 L 3.5 6.5'
        : 'M 3.5 0.5 L 0.5 3.5 L 3.5 6.5');
    }
  }

  window.renderMermaid = ({ source, dark = false, expanded = false, revision }) => {
    const currentGeneration = ++generation;
    const isCurrent = () => currentGeneration === generation;
    const render = async () => {
      // Let a newer Swift update replace work that has not started yet.
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
        mermaid.initialize(configuration(renderSource));
        staging.replaceChildren();
        const result = await mermaid.render(`diagram-${currentGeneration}`, renderSource, staging);
        if (!isCurrent()) return;
        // Only Mermaid's strict, sanitized output reaches HTML; never the source.
        staging.innerHTML = result.svg;
        const svg = staging.querySelector('svg');
        if (!svg) throw new Error('The diagram could not be rendered.');
        sizeDiagram(svg);
        styleArrowheads(svg);
        diagram.replaceChildren(svg);
        renderedGeneration = currentGeneration;
        renderedRevision = revision;
        await new Promise(resolve => requestAnimationFrame(resolve));
        if (isCurrent()) reportHeight();
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

  // The same render can gain a new viewport after rotation or native resizing.
  new ResizeObserver(reportHeight).observe(diagram);
  document.addEventListener('click', event => {
    if (event.target.closest?.('a')) event.preventDefault();
  }, true);
  post({ ready: true });
})();
