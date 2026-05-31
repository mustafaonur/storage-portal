/**
 * premium.js  —  Advanced UX feature suite
 *
 * 1.  Top loading progress bar   (global fetch interceptor, trickle)
 * 2.  Hover preview card         (700ms hold shows vendor stats)
 * 3.  Recently visited           (localStorage, last 4 pages)
 * 4.  Breadcrumb navigation      (URL-based, animated separators)
 * 5.  Sparklines                 (history CSV, async, non-blocking)
 * 6.  Changes strip              (delta vs most recent history file)
 * 7.  Deep-link ?focus=          (scroll + highlight section zone)
 * 8.  Aria-label enhancement     (vendor cards get meaningful labels)
 *
 * window.premiumOnRender(STAT, totals) must be called from render()
 * in index.html to wire features 2, 5, 6, 7, 8.
 */
(function Premium() {
  'use strict';

  /* ── shared escape ─────────────────────────────────────────── */
  function esc(s) {
    return String(s)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;')
      .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  /* ════════════════════════════════════════════════════════════
     1. TOP LOADING PROGRESS BAR
     Wraps window.fetch globally. Trickles toward 90% while any
     request is in flight; jumps to 100% + fades when all done.
  ════════════════════════════════════════════════════════════ */
  var _bar, _pending = 0, _trickleTmr, _barPct = 0;

  function getBar() {
    if (!_bar) {
      _bar = document.createElement('div');
      _bar.id = 'top-progress-bar';
      document.body.insertBefore(_bar, document.body.firstChild);
    }
    return _bar;
  }

  function barSet(pct, instant) {
    _barPct = pct;
    var b = getBar();
    if (instant) b.style.transition = 'none';
    b.style.width = pct + '%';
    b.classList.remove('bar-hidden');
    if (instant) requestAnimationFrame(function() { b.style.transition = ''; });
  }

  function barComplete() {
    clearInterval(_trickleTmr);
    var b = getBar();
    b.classList.add('bar-done');
    setTimeout(function() {
      b.classList.add('bar-hidden');
      setTimeout(function() {
        b.classList.remove('bar-done', 'bar-hidden');
        barSet(0, true);
      }, 550);
    }, 180);
  }

  (function patchFetch() {
    var orig = window.fetch;
    window.fetch = function() {
      _pending++;
      if (_pending === 1) {
        clearInterval(_trickleTmr);
        barSet(5, true);
        _trickleTmr = setInterval(function() {
          /* Easing toward 90 — slows as it approaches */
          if (_barPct < 88) barSet(_barPct + (_barPct < 40 ? 4 : _barPct < 70 ? 2 : 0.6));
        }, 220);
      }
      var req = orig.apply(this, arguments);
      var done = function() {
        _pending = Math.max(0, _pending - 1);
        if (_pending === 0) barComplete();
      };
      req.then(done, done);
      return req;
    };
  })();

  /* ════════════════════════════════════════════════════════════
     2. HOVER PREVIEW CARD
     700ms hover on any .app-card[data-preview-data] shows a
     floating stat panel. Positioned to stay within viewport.
  ════════════════════════════════════════════════════════════ */
  var _preview = null, _hoverTimer = null, _prevCard = null;

  function mkPreview() {
    _preview = document.createElement('div');
    _preview.className = 'card-preview';
    document.body.appendChild(_preview);
  }

  function previewRow(label, val, cls) {
    return '<div class="card-preview-row">' +
      '<span class="card-preview-label">' + esc(label) + '</span>' +
      '<span class="card-preview-val ' + (cls || '') + '">' + esc(val) + '</span>' +
      '</div>';
  }

  function showPreview(card) {
    var raw = card.dataset.previewData;
    if (!raw) return;
    var d;
    try { d = JSON.parse(raw); } catch(e) { return; }

    var capCls = d.cap >= 80 ? 'crit' : d.cap >= 70 ? 'warn' : 'ok';
    var almCls = d.alarms > 0 ? 'crit' : 'ok';

    var html = '<div class="card-preview-name">' + esc(d.label) + '</div>';
    if (d.cap >= 0)      html += previewRow('Capacity', d.cap.toFixed(1) + '%', capCls);
    if (d.hosts > 0)     html += previewRow('Hosts', d.hosts.toLocaleString('tr-TR'), '');
    if (d.cabs > 0)      html += previewRow('Arrays', String(d.cabs), '');
    if (d.alarms !== undefined) html += previewRow('Alarms', String(d.alarms), almCls);
    _preview.innerHTML = html;

    /* Position: right of card; fall back to left if near viewport edge */
    var r  = card.getBoundingClientRect();
    var pw = 230, ph = _preview.offsetHeight || 140;
    var x  = r.right + 12;
    var y  = r.top;
    if (x + pw > window.innerWidth - 8)  x = r.left - pw - 12;
    if (y + ph > window.innerHeight - 8) y = Math.max(8, window.innerHeight - ph - 8);
    _preview.style.left = Math.round(x) + 'px';
    _preview.style.top  = Math.round(y) + 'px';
    _preview.classList.add('active');
  }

  function initHoverPreview() {
    if (!_preview) mkPreview();

    document.addEventListener('mouseover', function(e) {
      var card = e.target.closest && e.target.closest('.app-card[data-preview-data]');
      if (!card || card === _prevCard) return;
      _prevCard = card;
      clearTimeout(_hoverTimer);
      _hoverTimer = setTimeout(function() { showPreview(card); }, 700);
    });

    document.addEventListener('mouseout', function(e) {
      var card = e.target.closest && e.target.closest('.app-card');
      if (!card) return;
      clearTimeout(_hoverTimer);
      _prevCard = null;
      if (_preview) _preview.classList.remove('active');
    });
  }

  /* ════════════════════════════════════════════════════════════
     3. RECENTLY VISITED  (all pages except index)
  ════════════════════════════════════════════════════════════ */
  var RECENT_KEY = 'storage_portal.recent';
  var RECENT_MAX = 4;

  function getRecent() {
    try { return JSON.parse(localStorage.getItem(RECENT_KEY) || '[]'); }
    catch(e) { return []; }
  }
  function saveRecent(list) {
    try { localStorage.setItem(RECENT_KEY, JSON.stringify(list)); }
    catch(e) {}
  }

  function recordVisit() {
    var page = (window.location.pathname.split('/').pop() || 'index.html');
    if (!page || page === 'index.html') return;
    var title = document.title ? document.title.split('|')[0].replace('Storage Intelligence','').replace('Enterprise Storage Portal','').trim() : page;
    if (!title) title = page;
    var list = getRecent().filter(function(r) { return r.page !== page; });
    list.unshift({ page: page, title: title, ts: Date.now() });
    saveRecent(list.slice(0, RECENT_MAX));
  }

  function timeAgo(ms) {
    var d = Date.now() - ms;
    if (d < 90000)    return 'just now';
    if (d < 3600000)  return Math.floor(d / 60000) + 'm ago';
    if (d < 86400000) return Math.floor(d / 3600000) + 'h ago';
    return Math.floor(d / 86400000) + 'd ago';
  }

  function renderRecentlyVisited() {
    var container = document.getElementById('recently-visited-container');
    if (!container) return;
    var list = getRecent();
    if (!list.length) { container.style.display = 'none'; return; }

    var items = list.map(function(r) {
      return '<a href="./' + esc(r.page) + '" class="recent-item">' +
        '<span>' + esc(r.title) + '</span>' +
        '<span class="recent-item-time">' + timeAgo(r.ts) + '</span>' +
        '</a>';
    }).join('');

    container.innerHTML =
      '<div class="recently-visited">' +
      '<div class="recently-visited-label">↩ Jump back to</div>' +
      '<div class="recently-visited-list">' + items + '</div>' +
      '</div>';
  }

  /* ════════════════════════════════════════════════════════════
     4. BREADCRUMB  (all non-index pages)
  ════════════════════════════════════════════════════════════ */
  var PAGE_NAMES = {
    'pmax.html':'Dell PowerMax','huawei.html':'Huawei OceanStor',
    'pure-fa.html':'Pure FlashArray','pure-fb.html':'Pure FlashBlade',
    'netapp.html':'NetApp ONTAP','ecs.html':'Dell ECS',
    'hitachi.html':'Hitachi VSP','san.html':'Brocade SAN',
    'trend.html':'Trend Analysis','anomaly.html':'Anomaly Detection',
    'capacity-planner.html':'Capacity Planner','impact.html':'Impact Map',
    'lake.html':'Data Lake','zone-builder.html':'Zone Builder',
    'management.html':'Management','executive.html':'Executive Report',
    'portal.html':'System Portal','cabinet-finder.html':'Cabinet Finder',
    'cabinet-finder-v2.html':'Cabinet Finder v2',
    'hostsearch.html':'Host Search','hostwwnfinder.html':'WWN Finder',
    'WWNResolver.html':'WWN Resolver','portgroups.html':'Port Groups',
    'topology.html':'Topology'
  };

  function initBreadcrumb() {
    var page = window.location.pathname.split('/').pop() || 'index.html';
    if (!page || page === 'index.html') return;
    var name = PAGE_NAMES[page] || page;

    var crumb = document.createElement('nav');
    crumb.className = 'breadcrumb';
    crumb.setAttribute('aria-label', 'breadcrumb');
    crumb.innerHTML =
      '<a href="./index.html" class="breadcrumb-item">Dashboard</a>' +
      '<span class="breadcrumb-sep" style="--i:0" aria-hidden="true">›</span>' +
      '<span class="breadcrumb-item current" aria-current="page">' + esc(name) + '</span>';

    /* Inject after <header> inside .shell */
    var header = document.querySelector('.shell > header, .shell header');
    if (header && header.nextSibling) {
      header.parentNode.insertBefore(crumb, header.nextSibling);
    } else {
      var shell = document.querySelector('.shell');
      if (shell) shell.prepend(crumb);
    }
  }

  /* ════════════════════════════════════════════════════════════
     5. SPARKLINES  (index.html only, async history CSV fetch)
  ════════════════════════════════════════════════════════════ */
  function buildDates(n) {
    var out = [], base = new Date();
    for (var i = 1; i <= n; i++) {
      var d = new Date(base); d.setDate(base.getDate() - i);
      out.push(d.toISOString().split('T')[0]);
    }
    return out;
  }

  function parseCapCSV(text) {
    var lines = text.replace(/^\uFEFF/, '').split(/\r?\n/).filter(function(l){ return l.trim(); });
    if (lines.length < 2) return null;
    var hdrs = lines[0].split(',').map(function(h){ return h.replace(/^"|"$/g,'').trim(); });
    var tI = hdrs.indexOf('Total (TB)'), uI = hdrs.indexOf('Used (TB)');
    if (tI < 0 || uI < 0) return null;
    var tot = 0, used = 0;
    for (var i = 1; i < lines.length; i++) {
      var vals = splitCSVLine(lines[i]);
      tot  += parseFloat(vals[tI]) || 0;
      used += parseFloat(vals[uI]) || 0;
    }
    return tot > 0 ? { total: tot, used: used, pct: used / tot * 100 } : null;
  }

  function parseHostCSV(text) {
    var lines = text.replace(/^\uFEFF/, '').split(/\r?\n/).filter(function(l){ return l.trim(); });
    if (lines.length < 2) return null;
    var hdrs = lines[0].split(',').map(function(h){ return h.replace(/^"|"$/g,'').trim(); });
    var hI = hdrs.indexOf('Host Sayisi');
    if (hI < 0) return null;
    var hosts = 0;
    for (var i = 1; i < lines.length; i++) {
      var vals = splitCSVLine(lines[i]);
      hosts += parseFloat(vals[hI]) || 0;
    }
    return hosts > 0 ? { pct: hosts } : null;
  }

  function splitCSVLine(line) {
    var vals = [], cur = '', inQ = false;
    for (var i = 0; i < line.length; i++) {
      var c = line[i];
      if (c === '"') { inQ = !inQ; }
      else if (c === ',' && !inQ) { vals.push(cur.trim()); cur = ''; }
      else { cur += c; }
    }
    vals.push(cur.trim());
    return vals;
  }

  async function tryFetchHistory(template, dates, parser) {
    var results = [];
    await Promise.all(dates.map(async function(date) {
      try {
        var res = await fetch(template.replace('{d}', date), { cache: 'default' });
        if (!res.ok) return;
        var text = await res.text();
        var d = parser(text);
        if (d) { d.date = date; results.push(d); }
      } catch(e) { /* file not found — silent */ }
    }));
    return results.sort(function(a, b) { return a.date < b.date ? -1 : 1; });
  }

  function drawSparkline(points, strokeColor, container) {
    if (!points || points.length < 2) return;
    var W = 58, H = 22, P = 2;
    var vals = points.map(function(p) { return p.pct; });
    var mn = Math.min.apply(null, vals);
    var mx = Math.max.apply(null, vals);
    var rng = mx - mn || 1;

    var coords = vals.map(function(v, i) {
      var x = P + (W - P * 2) * (i / (vals.length - 1));
      var y = H - P - (H - P * 2) * ((v - mn) / rng);
      return x.toFixed(1) + ',' + y.toFixed(1);
    });

    /* Gradient area under line */
    var areaCoords = coords.slice();
    areaCoords.push((W - P).toFixed(1) + ',' + (H - P));
    areaCoords.unshift(P + ',' + (H - P));
    var gradId = 'spk' + Math.random().toString(36).slice(2, 7);

    var last  = vals[vals.length - 1];
    var prev  = vals[vals.length - 2];
    var delta = last - prev;
    var trend = delta > 0.5 ? 'up' : delta < -0.5 ? 'down' : 'flat';
    var arrow = trend === 'up' ? '▲' : trend === 'down' ? '▼' : '—';
    var isCapPct = last <= 100; // capacity% vs host count
    var label = isCapPct ? last.toFixed(1) + '%' : Math.round(last).toLocaleString('tr-TR');

    container.innerHTML =
      '<svg class="sparkline" viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '">' +
        '<defs><linearGradient id="' + gradId + '" x1="0" y1="0" x2="0" y2="1">' +
          '<stop offset="0%" stop-color="' + strokeColor + '" stop-opacity="0.25"/>' +
          '<stop offset="100%" stop-color="' + strokeColor + '" stop-opacity="0.02"/>' +
        '</linearGradient></defs>' +
        '<polygon class="sparkline-area" points="' + areaCoords.join(' ') + '" fill="url(#' + gradId + ')"/>' +
        '<polyline class="sparkline-line" points="' + coords.join(' ') + '" stroke="' + strokeColor + '"/>' +
      '</svg>' +
      '<span class="sparkline-trend trend-' + trend + '">' + arrow + ' ' + esc(label) + '</span>';
  }

  async function initSparklines() {
    var dates = buildDates(14);

    /* Combined capacity for the PB stat card */
    var byDate = {};
    var sources = [
      { t: './data/Hw/_history/Dorado_Dashboard_{d}.csv',  fn: parseCapCSV },
      { t: './data/Pure/_history/Pure_Dashboard_{d}.csv',   fn: parseCapCSV },
      { t: './data/Pmax/_history/PmaxPoolDash_{d}.csv',     fn: parseCapCSV },
    ];

    await Promise.all(sources.map(async function(s) {
      var pts = await tryFetchHistory(s.t, dates, s.fn);
      pts.forEach(function(p) {
        if (!byDate[p.date]) byDate[p.date] = { total: 0, used: 0 };
        byDate[p.date].total += p.total || 0;
        byDate[p.date].used  += p.used  || 0;
      });
    }));

    var combined = Object.keys(byDate).sort().slice(-7).map(function(dt) {
      var d = byDate[dt];
      return { date: dt, pct: d.total > 0 ? d.used / d.total * 100 : 0 };
    });

    var capContainer = document.getElementById('sparkline-cap');
    if (capContainer && combined.length >= 2) {
      drawSparkline(combined, 'var(--accent2)', capContainer);
    }

    /* Huawei host count for the Hosts stat card */
    var hwHosts = await tryFetchHistory(
      './data/Hw/_history/Dorado_Dashboard_{d}.csv',
      dates,
      parseHostCSV
    );
    var hostContainer = document.getElementById('sparkline-hosts');
    if (hostContainer && hwHosts.length >= 2) {
      drawSparkline(hwHosts.slice(-7), 'var(--accent3)', hostContainer);
    }
  }

  /* ════════════════════════════════════════════════════════════
     6. CHANGES STRIP  (delta vs most recent history file)
  ════════════════════════════════════════════════════════════ */
  async function initChangesStrip(stat) {
    var container = document.getElementById('changes-strip-container');
    if (!container) return;

    var dates = buildDates(14);
    var checks = [
      { label: 'HUAWEI', color: 'var(--accent3)', tpl: './data/Hw/_history/Dorado_Dashboard_{d}.csv',  cur: { used: stat.hwUsed, cap: stat.hwCap } },
      { label: 'PMAX',   color: 'var(--accent2)', tpl: './data/Pmax/_history/PmaxPoolDash_{d}.csv',    cur: { used: stat.pmUsed, cap: stat.pmCap } },
      { label: 'PURE FA',color: '#f67c00',         tpl: './data/Pure/_history/Pure_Dashboard_{d}.csv',  cur: { used: stat.puUsed, cap: stat.puCap } },
      { label: 'NETAPP', color: '#00b4d8',         tpl: './data/NetApp/_history/NetApp_Dashboard_{d}.csv', cur: { used: stat.naUsed, cap: stat.naCap } },
    ];

    var changes = [];

    await Promise.all(checks.map(async function(v) {
      for (var i = 0; i < dates.length; i++) {
        try {
          var res = await fetch(v.tpl.replace('{d}', dates[i]), { cache: 'default' });
          if (!res.ok) continue;
          var hist = parseCapCSV(await res.text());
          if (!hist || hist.total < 1) continue;

          var deltaUsed = v.cur.used - hist.used;
          var deltaCapPct = hist.total > 0
            ? (v.cur.used / v.cur.cap * 100) - (hist.used / hist.total * 100)
            : 0;

          /* Only show if meaningful (>0.5 TB or >0.5 pct) */
          if (Math.abs(deltaUsed) < 0.5) break;

          changes.push({
            label: v.label, color: v.color,
            deltaUsed: deltaUsed,
            deltaCapPct: deltaCapPct,
            date: dates[i]
          });
          break;
        } catch(e) { continue; }
      }
    }));

    if (!changes.length) return;

    /* Sort biggest delta first */
    changes.sort(function(a, b) { return Math.abs(b.deltaUsed) - Math.abs(a.deltaUsed); });

    var rows = changes.map(function(c) {
      var up   = c.deltaUsed > 0;
      var icon = up ? '▲' : '▼';
      var cls  = up ? 'change-up' : 'change-down';
      var abs  = Math.abs(c.deltaUsed);
      var unit = abs.toFixed(1) + ' TB';
      var pctStr = Math.abs(c.deltaCapPct) >= 0.1
        ? ' (' + (c.deltaCapPct > 0 ? '+' : '') + c.deltaCapPct.toFixed(1) + '%)'
        : '';

      return '<div class="change-row">' +
        '<span class="change-icon ' + cls + '">' + icon + '</span>' +
        '<span class="change-vendor" style="color:' + c.color + '">' + esc(c.label) + '</span>' +
        '<span class="change-desc">Used' + esc(pctStr) + '</span>' +
        '<span class="change-delta ' + cls + '">' +
          (up ? '+' : '-') + esc(unit) +
          '<span class="change-date">vs ' + esc(c.date) + '</span>' +
        '</span>' +
        '</div>';
    }).join('');

    container.innerHTML =
      '<div class="changes-strip">' +
      '<div class="changes-header" onclick="var b=this.nextElementSibling;b.classList.toggle(\'open\')">' +
        '<span>⚡ Changes since last scan</span>' +
        '<span class="changes-badge">' + changes.length + '</span>' +
      '</div>' +
      '<div class="changes-body">' + rows + '</div>' +
      '</div>';
  }

  /* ════════════════════════════════════════════════════════════
     7. DEEP-LINK  ?focus=analytics|storage|utilities|ops
  ════════════════════════════════════════════════════════════ */
  function initDeepLink() {
    try {
      var focus = new URLSearchParams(window.location.search).get('focus');
      if (!focus) return;
      var zone = document.querySelector('.zone-' + focus);
      if (!zone) return;
      setTimeout(function() {
        zone.scrollIntoView({ behavior: 'smooth', block: 'start' });
        zone.style.transition = 'outline .15s ease';
        zone.style.outline    = '1px solid rgba(232,184,75,.6)';
        setTimeout(function() { zone.style.outline = ''; }, 2000);
      }, 900);
    } catch(e) {}
  }

  /* ════════════════════════════════════════════════════════════
     8. VENDOR STAT MAP — data-preview-data + aria-labels
  ════════════════════════════════════════════════════════════ */
  var VENDOR_MAP = {
    'pmax.html':    { label: 'Dell PowerMax',    k: 'pm' },
    'huawei.html':  { label: 'Huawei OceanStor', k: 'hw' },
    'pure-fa.html': { label: 'Pure FlashArray',  k: 'pu' },
    'pure-fb.html': { label: 'Pure FlashBlade',  k: 'fb' },
    'netapp.html':  { label: 'NetApp ONTAP',      k: 'na' },
    'hitachi.html': { label: 'Hitachi VSP',       k: 'hi' },
    'ecs.html':     { label: 'Dell ECS',          k: 'ecs'},
    'san.html':     { label: 'Brocade SAN',       k: 'san'},
  };

  function populateCardData(stat) {
    document.querySelectorAll('.app-card[href]').forEach(function(card) {
      var base = (card.getAttribute('href') || '').replace('./', '').split('?')[0];
      var vm   = VENDOR_MAP[base];
      if (!vm) return;
      var k   = vm.k;
      var cap  = stat[k + 'Cap']    || 0;
      var used = stat[k + 'Used']   || 0;
      var d = {
        label:  vm.label,
        cap:    cap > 0 ? Math.round(used / cap * 1000) / 10 : -1,
        hosts:  stat[k + 'Hosts']  || 0,
        cabs:   stat[k + 'Cabs']   || 0,
        alarms: stat[k + 'Alarms'] || 0,
      };
      card.dataset.previewData = JSON.stringify(d);

      /* aria-label */
      var parts = [vm.label];
      if (d.cap >= 0)   parts.push(d.cap.toFixed(0) + '% capacity used');
      if (d.hosts > 0)  parts.push(d.hosts + ' hosts');
      if (d.alarms > 0) parts.push(d.alarms + ' alarm' + (d.alarms > 1 ? 's' : ''));
      card.setAttribute('aria-label', parts.join(' — '));
    });
  }

  function injectSparkContainers() {
    [
      { id: 'v-pb',    spId: 'sparkline-cap'   },
      { id: 'v-hosts', spId: 'sparkline-hosts' },
    ].forEach(function(item) {
      var el   = document.getElementById(item.id);
      var card = el && el.closest('.stat-card');
      if (card && !document.getElementById(item.spId)) {
        var sp = document.createElement('div');
        sp.className = 'sparkline-wrap';
        sp.id = item.spId;
        card.appendChild(sp);
      }
    });
  }

  /* ════════════════════════════════════════════════════════════
     PUBLIC HOOK — called from index.html render()
  ════════════════════════════════════════════════════════════ */
  window.premiumOnRender = function(stat) {
    populateCardData(stat);
    injectSparkContainers();
    renderRecentlyVisited();
    initDeepLink();
    /* Non-blocking async */
    initSparklines();
    initChangesStrip(stat);
  };

  /* ════════════════════════════════════════════════════════════
     BOOT  (runs on every page)
  ════════════════════════════════════════════════════════════ */
  function boot() {
    recordVisit();
    initBreadcrumb();
    initHoverPreview();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

})();
