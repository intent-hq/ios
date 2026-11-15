import Foundation

nonisolated enum AgentBrowserJSON {
    /// Converts a WebKit-bridged JavaScript value into a JSON-serializable value.
    static func sanitize(_ value: Any?) -> Any {
        switch value {
        case nil, is NSNull: NSNull()
        case let string as String: string
        case let flag as Bool where isBoolean(value): flag
        case let number as Double: number.isFinite ? number : NSNull()
        case let date as Date: ISO8601DateFormatter().string(from: date)
        case let array as [Any]: array.map { sanitize($0) }
        case let dictionary as [String: Any]: dictionary.mapValues { sanitize($0) }
        case let value?: String(describing: value)
        }
    }

    /// Bridged JavaScript numbers also cast to `Bool`; only a CFBoolean is a real boolean.
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}

nonisolated enum AgentBrowserScripts {
    /// WebKit has no CDP accessibility domain; this approximates it from the DOM and ARIA:
    /// visible elements with a role or accessible name, nested, capped at 2,000 nodes.
    static let accessibilityTree = """
    (() => {
      const LIMIT = 2000;
      let count = 0;
      const implicit = { A: 'link', BUTTON: 'button', INPUT: 'textbox', SELECT: 'combobox', TEXTAREA: 'textbox',
        IMG: 'img', H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
        NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', FORM: 'form', UL: 'list',
        OL: 'list', LI: 'listitem', TABLE: 'table', TR: 'row', TD: 'cell', TH: 'columnheader', DIALOG: 'dialog',
        LABEL: 'label', P: 'paragraph' };
      const inputRole = el => ({ checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button',
        range: 'slider', search: 'searchbox' })[el.type] || 'textbox';
      const visible = el => {
        const style = getComputedStyle(el);
        return style.display !== 'none' && style.visibility !== 'hidden' && el.getAttribute('aria-hidden') !== 'true';
      };
      const nameOf = el => {
        const labelled = el.getAttribute('aria-labelledby');
        if (labelled) return labelled.split(/\\s+/).map(id => document.getElementById(id)?.textContent || '').join(' ').trim();
        const label = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder');
        if (label) return label.trim();
        if (el.labels && el.labels.length) return el.labels[0].textContent.trim();
        if (['A', 'BUTTON', 'LABEL', 'LI', 'TD', 'TH', 'P'].includes(el.tagName) || /^H[1-6]$/.test(el.tagName)) {
          return (el.innerText || '').trim().slice(0, 200);
        }
        return '';
      };
      const walk = el => {
        if (count >= LIMIT || !(el instanceof Element) || !visible(el)) return [];
        const role = el.getAttribute('role') || (el.tagName === 'INPUT' ? inputRole(el) : implicit[el.tagName]);
        const children = [...el.children].flatMap(walk);
        if (!role) return children;
        count += 1;
        const node = { role, name: nameOf(el) };
        if ('value' in el && typeof el.value === 'string' && el.value) node.value = el.value.slice(0, 200);
        if (el.disabled) node.disabled = true;
        if (el.checked) node.checked = true;
        if (/^H[1-6]$/.test(el.tagName)) node.level = Number(el.tagName[1]);
        if (children.length) node.children = children;
        return [node];
      };
      return { role: 'document', name: document.title, url: location.href, children: walk(document.body),
        truncated: count >= LIMIT };
    })()
    """
}
