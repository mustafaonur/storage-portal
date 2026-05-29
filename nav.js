/**
 * nav.js — Shared navigation component for Storage Portal
 *
 * Injects a consistent top-bar into every vendor/tool page:
 *   ← Portal  |  [sibling page links]  |  [page title]
 *
 * Usage: <script src="./nav.js"></script>
 * Call:  StorageNav.init({ title: 'Huawei Dorado', section: 'vendor' });
 *
 * The back-link CSS is already in storage-styles.css. This file adds
 * the nav-bar CSS and DOM injection only.
 */

const StorageNav = (() => {

  const PAGES = [
    { label: 'Huawei',    href: './huawei.html',   section: 'vendor' },
    { label: 'PowerMax',  href: './pmax.html',      section: 'vendor' },
    { label: 'Pure FA',   href: './pure-fa.html',   section: 'vendor' },
    { label: 'Pure FB',   href: './pure-fb.html',   section: 'vendor' },
    { label: 'NetApp',    href: './netapp.html',     section: 'vendor' },
    { label: 'ECS',       href: './ecs.html',        section: 'vendor' },
    { label: 'Hitachi',   href: './hitachi.html',    section: 'vendor' },
    { label: 'SAN',       href: './san.html',        section: 'vendor' },
    { label: 'Trend',     href: './trend.html',      section: 'analytics' },
    { label: 'Anomaly',   href: './anomaly.html',    section: 'analytics' },
    { label: 'Capacity',  href: './capacity-planner.html', section: 'analytics' },
    { label: 'Impact',    href: './impact.html',     section: 'analytics' },
    { label: 'Lake',      href: './lake.html',       section: 'analytics' },
    { label: 'Topology',  href: './topology.html',   section: 'tools' },
    { label: 'Zone Builder', href: './zone-builder.html', section: 'tools' },
    { label: 'WWN Resolver', href: './WWNResolver.html', section: 'tools' },
    { label: 'Host Finder',  href: './hostwwnfinder.html', section: 'tools' },
    { label: 'Cabinet Finder', href: './cabinet-finder.html', section: 'tools' },
    { label: 'Cabinet v2',  href: './cabinet-finder-v2.html', section: 'tools' },
    { label: 'Ops Hub',   href: './management.html', section: 'tools' },
  ];

  function injectCSS() {
    if (document.getElementById('sp-nav-style')) return;
    const s = document.createElement('style');
    s.id = 'sp-nav-style';
    s.textContent = `
      .sp-nav-bar {
        display: flex;
        align-items: center;
        gap: 0;
        margin-bottom: 14px;
        padding: 0 0 10px;
        border-bottom: 1px solid var(--border);
        flex-wrap: wrap;
        row-gap: 6px;
      }
      .sp-nav-home {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        font-size: 11px;
        color: var(--text-dim);
        text-decoration: none;
        letter-spacing: 1.5px;
        text-transform: uppercase;
        padding: 4px 10px 4px 0;
        border-right: 1px solid var(--border);
        margin-right: 10px;
        transition: color .2s;
        white-space: nowrap;
      }
      .sp-nav-home:hover { color: var(--accent2); }
      .sp-nav-section {
        font-size: 10px;
        color: var(--text-dim);
        letter-spacing: 2px;
        text-transform: uppercase;
        margin-right: 8px;
        opacity: .5;
      }
      .sp-nav-links {
        display: flex;
        flex-wrap: wrap;
        gap: 4px;
        align-items: center;
      }
      .sp-nav-link {
        font-size: 10px;
        color: var(--text-dim);
        text-decoration: none;
        padding: 3px 8px;
        border: 1px solid transparent;
        letter-spacing: .5px;
        transition: color .15s, border-color .15s;
        white-space: nowrap;
      }
      .sp-nav-link:hover { color: var(--accent2); border-color: var(--border); }
      .sp-nav-link.sp-nav-current {
        color: var(--accent);
        border-color: var(--accent);
        opacity: .85;
        cursor: default;
        pointer-events: none;
      }
    `;
    document.head.appendChild(s);
  }

  function init(opts = {}) {
    const { title = '', section = 'vendor', insertBefore = null } = opts;

    injectCSS();

    const currentHref = './' + window.location.pathname.split('/').pop();

    const bar = document.createElement('nav');
    bar.className = 'sp-nav-bar';
    bar.setAttribute('aria-label', 'Storage Portal navigation');

    // Home link
    const home = document.createElement('a');
    home.href = './index.html';
    home.className = 'sp-nav-home';
    home.setAttribute('aria-label', 'Portal ana sayfası');
    home.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>Portal`;
    bar.appendChild(home);

    // Section label
    if (section) {
      const sec = document.createElement('span');
      sec.className = 'sp-nav-section';
      sec.textContent = section;
      bar.appendChild(sec);
    }

    // Sibling links (same section only, to keep nav compact)
    const siblings = PAGES.filter(p => p.section === section);
    if (siblings.length > 1) {
      const links = document.createElement('div');
      links.className = 'sp-nav-links';
      siblings.forEach(p => {
        const a = document.createElement('a');
        a.href = p.href;
        a.className = 'sp-nav-link' + (p.href === currentHref ? ' sp-nav-current' : '');
        a.textContent = p.label;
        if (p.href === currentHref) a.setAttribute('aria-current', 'page');
        links.appendChild(a);
      });
      bar.appendChild(links);
    }

    // Inject into DOM
    const target = insertBefore
      ? document.querySelector(insertBefore)
      : (document.querySelector('.shell') || document.querySelector('main') || document.body.firstElementChild);

    if (target) {
      // Replace existing back-link if present
      const existing = target.querySelector('.back-link');
      if (existing) existing.replaceWith(bar);
      else target.prepend(bar);
    } else {
      document.body.prepend(bar);
    }
  }

  return { init, PAGES };
})();
