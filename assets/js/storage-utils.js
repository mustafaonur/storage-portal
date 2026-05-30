/**
 * storage-utils.js — Storage Portal Ortak Yardımcılar
 * Tüm HTML sayfaları bu dosyayı <script src> ile yükler.
 */

/* ════════════════════════════════════════════════════════════
   CSV PARSE
════════════════════════════════════════════════════════════ */
function parseCSV(text) {
  if (!text) return [];
  text = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = text.split('\n').filter(l => l.trim() !== '');
  if (lines.length < 2) return [];

  function detectDelim(line) {
    let comma = 0, semi = 0, q = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (c === '"') { q = !q; continue; }
      if (q) continue;
      if (c === ',') comma++;
      else if (c === ';') semi++;
    }
    return semi > comma ? ';' : ',';
  }
  const DELIM = detectDelim(lines[0]);

  function splitLine(line) {
    const cols = []; let cur = '', q = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (c === '"') {
        if (q && line[i + 1] === '"') { cur += '"'; i++; }
        else q = !q;
      } else if (c === DELIM && !q) { cols.push(cur); cur = ''; }
      else cur += c;
    }
    cols.push(cur);
    return cols.map(c => {
      let trimmed = c.trim();
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        trimmed = trimmed.substring(1, trimmed.length - 1);
      }
      return trimmed.replace(/""/g, '"');
    });
  }

  const headers = splitLine(lines[0]);
  return lines.slice(1).map(l => {
    const v = splitLine(l);
    const o = {};
    headers.forEach((h, i) => o[h] = v[i] ?? '');
    return o;
  });
}

/* ════════════════════════════════════════════════════════════
   SAYI PARSE (Türkçe/İngilizce uyumlu)
════════════════════════════════════════════════════════════ */
function toN(v) {
  if (v === undefined || v === null) return 0;
  let s = String(v).trim();
  if (!s || s === '-' || s.toUpperCase() === 'HATA') return 0;

  // Normalize negative sign (e.g. "- 150" → "-150")
  const neg = s.startsWith('-');
  if (neg) s = s.substring(1).trim();

  const hasDot   = s.includes('.');
  const hasComma = s.includes(',');

  if (hasDot && hasComma) {
    // Both present — last one is the decimal separator
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
      // Turkish/German: 1.234,56 → 1234.56
      s = s.replace(/\./g, '').replace(',', '.');
    } else {
      // English: 1,234.56 → 1234.56
      s = s.replace(/,/g, '');
    }
  } else if (hasComma) {
    const parts = s.split(',');
    // Ambiguous single comma: treat as decimal separator
    // (covers "1,5" and "1,234" — decimal is safer than dropping precision)
    s = s.replace(',', '.');
  } else if (hasDot) {
    const parts = s.split('.');
    if (parts.length > 2) {
      // Multiple dots = thousand separators: "1.234.567" → "1234567"
      s = s.replace(/\./g, '');
    }
    // Single dot: keep (standard decimal point)
  }

  s = s.replace(/[^\d.]/g, '');
  const n = parseFloat(s);
  if (isNaN(n)) return 0;
  return neg ? -n : n;
}

/* ════════════════════════════════════════════════════════════
   WWN ARAÇLARI (Güvenli Hale Getirildi)
════════════════════════════════════════════════════════════ */
function cleanWwn(s) {
  if (!s) return '';
  const hex = String(s).toLowerCase().replace(/[^0-9a-f]/g, '');
  if (hex.length < 16) return '';
  const targetHex = hex.substring(0, 16);
  const matches = targetHex.match(/.{2}/g);
  return matches ? matches.join(':') : '';
}

function isValidWwn(s) {
  if (!s) return false;
  const x = String(s).toLowerCase().replace(/[^0-9a-f]/g, '');
  return x.length === 16;
}

function expandWwnList(raw) {
  if (!raw) return [];
  const result = [];
  String(raw).split('|').forEach(chunk => {
    const hex = chunk.trim().toLowerCase().replace(/[^0-9a-f]/g, '');
    for (let i = 0; i + 16 <= hex.length; i += 16) {
      const part = hex.substring(i, i + 16);
      const matches = part.match(/.{2}/g);
      if (matches) {
        const w = matches.join(':');
        if (!result.includes(w)) result.push(w);
      }
    }
  });
  return result;
}

/* ════════════════════════════════════════════════════════════
   HTML ESCAPE & FORMATTERS
════════════════════════════════════════════════════════════ */
function esc(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function fmtTB(v, dec = 2) {
  const n = typeof v === 'number' ? v : toN(v);
  return n.toFixed(dec) + ' TB';
}

function fmtPct(v, dec = 1) {
  const n = typeof v === 'number' ? v : toN(v);
  return n.toFixed(dec) + '%';
}

function pctColorVar(pct) {
  if (pct >= 80) return 'var(--danger)';
  if (pct >= 70) return 'var(--warn)';
  return 'var(--accent3)';
}

function fmtGiB(v, dec = 2) {
  const n = typeof v === 'number' ? v : toN(v);
  if (n === 0) return '0 GiB';
  if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(dec) + ' PiB';
  if (n >= 1024) return (n / 1024).toFixed(dec) + ' TiB';
  return n.toFixed(dec) + ' GiB';
}

/* ════════════════════════════════════════════════════════════
   FETCH YARDIMCILARI (Konsolide Edildi)
════════════════════════════════════════════════════════════ */
async function fetchCSVText(url) {
  try {
    const r = await fetch(url, { cache: 'no-store' });
    if (!r.ok) return '';
    return await r.text();
  } catch { return ''; }
}

async function fetchCSVParsed(url) {
  return parseCSV(await fetchCSVText(url));
}

// Eski fetchCsv çağrıları için alias (takma ad) oluşturarak çakışmayı önlüyoruz
const fetchCsv = fetchCSVParsed;

/* ════════════════════════════════════════════════════════════
   TALEPLER / ROZETLER / UI
════════════════════════════════════════════════════════════ */
async function getCSVFreshness(url) {
  try {
    const r = await fetch(url, { method: 'HEAD', cache: 'no-store' });
    if (!r.ok) return null;
    const lm = r.headers.get('Last-Modified') || r.headers.get('last-modified');
    if (!lm) return null;
    const d = new Date(lm);
    return isNaN(d.getTime()) ? null : d;
  } catch { return null; }
}

function freshnessText(date) {
  if (!date) return { text: 'Bilinmiyor', color: 'var(--text-dim)', age: Infinity };
  const now = new Date();
  const diffMs = now - date;
  const diffMin = Math.floor(diffMs / 60000);
  const diffHr  = Math.floor(diffMin / 60);
  const diffDay = Math.floor(diffHr / 24);

  let text;
  if (diffMin < 1)       text = 'Az önce';
  else if (diffMin < 60) text = `${diffMin} dk önce`;
  else if (diffHr < 24)  text = `${diffHr} saat önce`;
  else if (diffDay === 1) text = 'Dün';
  else                    text = `${diffDay} gün önce`;

  let color = 'var(--accent3)';
  if (diffHr > 50)       color = 'var(--danger)';
  else if (diffHr > 26)  color = 'var(--warn)';

  return { text, color, age: diffHr, stamp: date.toLocaleString('tr-TR') };
}

async function renderFreshnessBadge(containerId, csvUrls, useOldest = false) {
  const el = document.getElementById(containerId);
  if (!el) return;
  const dates = await Promise.all(csvUrls.map(getCSVFreshness));
  const valid = dates.filter(d => d);
  if (valid.length === 0) {
    el.innerHTML = `<span style="font-size:10px;color:var(--text-dim)">⊘ Veri yok</span>`;
    return;
  }
  const target = useOldest
    ? new Date(Math.min(...valid.map(d => d.getTime())))
    : new Date(Math.max(...valid.map(d => d.getTime())));
  const f = freshnessText(target);
  el.innerHTML = `<span title="Son güncelleme: ${esc(f.stamp)}"
    style="font-size:10px;color:${f.color};display:inline-flex;align-items:center;gap:5px">
    <span style="width:6px;height:6px;border-radius:50%;background:${f.color};display:inline-block"></span>
    Veri: ${esc(f.text)}</span>`;
}

function spEmptyState(opts = {}) {
  const { type = 'no-data', title = '', message = '', hint = '', compact = false } = opts;
  const presets = {
    'no-data': {
      icon: `<svg viewBox="0 0 24 24" width="44" height="44" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M3 7v10a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-7l-2-2H5a2 2 0 0 0-2 2z"/><line x1="12" y1="11" x2="12" y2="15"/><line x1="10" y1="13" x2="14" y2="13"/></svg>`,
      color: 'var(--text-dim)',
      defTitle: 'Veri henüz hazır değil',
      defMsg: 'Tarama scripti çalıştırıldıktan sonra veriler burada görünecek.'
    },
    'no-filter': {
      icon: `<svg viewBox="0 0 24 24" width="44" height="44" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.5" y2="16.5"/></svg>`,
      color: 'var(--text-dim)',
      defTitle: 'Eşleşen kayıt yok',
      defMsg: 'Filtre kriterlerini değiştirmeyi deneyin.'
    },
    'all-good': {
      icon: `<svg viewBox="0 0 24 24" width="44" height="44" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="12" cy="12" r="9"/><path d="M8 12l2.5 2.5L16 9"/></svg>`,
      color: 'var(--accent3)',
      defTitle: 'Her şey yolunda',
      defMsg: 'Tespit edilen bir sorun yok.'
    },
    'error': {
      icon: `<svg viewBox="0 0 24 24" width="44" height="44" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="12" cy="12" r="9"/><line x1="12" y1="8" x2="12" y2="13"/><circle cx="12" cy="16.5" r="0.5" fill="currentColor"/></svg>`,
      color: 'var(--warn)',
      defTitle: 'Veri yüklenemedi',
      defMsg: 'Tarama scripti henüz çalıştırılmamış olabilir.'
    }
  };

  const p = presets[type] || presets['no-data'];
  return `<div class="sp-empty-rich${compact ? ' sp-empty-compact' : ''}" style="--ic:${p.color}">
    <div class="sp-empty-ic">${p.icon}</div>
    <div class="sp-empty-ttl">${esc(title || p.defTitle)}</div>
    <div class="sp-empty-msg">${esc(message || p.defMsg)}</div>
    ${hint ? `<div class="sp-empty-hint">${esc(hint)}</div>` : ''}
  </div>`;
}

function toast(msg, ms) {
  const t = document.getElementById('toast');
  if (!t) return;
  t.textContent = msg;
  t.classList.remove('sp-hidden');
  clearTimeout(t._toastT);
  t._toastT = setTimeout(() => t.classList.add('sp-hidden'), ms || 2200);
}

/**
 * dateRangeBack(n, format)
 * format: 'YYYY-MM-DD' (default) | 'YYYYMMDD'
 * Returns last n days oldest→newest.
 */
function dateRangeBack(n, format = 'YYYY-MM-DD') {
  const d = [], now = new Date();
  for (let i = n - 1; i >= 0; i--) {
    const dt = new Date(now);
    dt.setDate(dt.getDate() - i);
    const iso = dt.toISOString().slice(0, 10);
    d.push(format === 'YYYYMMDD' ? iso.replace(/-/g, '') : iso);
  }
  return d;
}

// Backward-compat alias used by trend.html and others
const dateRangeBackFormatted = (n) => dateRangeBack(n, 'YYYY-MM-DD');

/* ════════════════════════════════════════════════════════════
   EŞİKLER & KABİN YARDIMCILARI
════════════════════════════════════════════════════════════ */
const SP_THRESH = { WARN: 70, CRIT: 80 };

function spPctColor(p) {
  if (p >= SP_THRESH.CRIT) return 'var(--danger)';
  if (p >= SP_THRESH.WARN) return 'var(--warn)';
  return 'var(--accent3)';
}

function spBarClass(p) {
  if (p >= SP_THRESH.CRIT) return 'bar-crit';
  if (p >= SP_THRESH.WARN) return 'bar-high';
  if (p >= 50)             return 'bar-mid';
  return 'bar-low';
}

function spStatusBadge(p) {
  if (p >= SP_THRESH.CRIT) return '<span class="status-badge badge-err">CRITICAL</span>';
  if (p >= SP_THRESH.WARN) return '<span class="status-badge badge-warn">WARN</span>';
  return '<span class="status-badge badge-ok">OK</span>';
}

function spCabinetClass(p) {
  if (p >= SP_THRESH.CRIT) return 'cabinet-card error';
  if (p >= SP_THRESH.WARN) return 'cabinet-card warn-high';
  return 'cabinet-card';
}

function normalizeVersion(raw) {
  if (!raw) return '-';
  const s = String(raw).trim();
  if (!s || s === '-') return '-';
  const m = s.match(/\b(\d+\.\d+(?:\.\d+)?(?:[PpRr]\d+)?)\b/);
  if (m) return m[1];
  return s.replace(/[:].*$/, '').substring(0, 16).trim() || '-';
}

function spCabinetFooter(opts) {
  const dr  = (opts && opts.dr  != null) ? String(opts.dr).trim()  : '';
  const ver = (opts && opts.ver != null) ? String(opts.ver).trim() : '';
  const drTxt  = (dr  && dr  !== '-') ? ('DR ' + dr) : '—';
  const verTxt = (ver && ver !== '-') ? ver : '';
  if (!verTxt) {
    return `<div class="card-footer footer-center"><span class="footer-dr">${drTxt}</span></div>`;
  }
  return `<div class="card-footer"><span class="footer-dr">${drTxt}</span><span class="footer-ver">${verTxt}</span></div>`;
}

/* ════════════════════════════════════════════════════════════
   ÇOKLU CSV FETCH — Tüm sayfaların kullanması gereken merkezi API
   Kurallar: async fetch, no-store cache, hata yutma, sanitize
════════════════════════════════════════════════════════════ */

/**
 * fetchMany(urlMap) → { key: rows[] }
 * urlMap = { dorado: './data/Hw/Dorado_Dashboard.csv', pmax: './data/Pmax/PmaxPoolDash.csv', ... }
 * Tüm CSV'leri paralel indirir, parse eder, obje olarak döner.
 * Herhangi biri başarısız olursa key→[] döner (sessiz hata).
 */
async function fetchMany(urlMap) {
  const keys = Object.keys(urlMap);
  const texts = await Promise.all(
    keys.map(k => fetchCSVText(urlMap[k]).catch(() => ''))
  );
  const result = {};
  keys.forEach((k, i) => { result[k] = parseCSV(texts[i]); });
  return result;
}

/**
 * fetchOne(url) → rows[]
 * Tek CSV — fetchCSVParsed'in alias'ı, tutarlı isimlendirme için.
 */
const fetchOne = fetchCSVParsed;

/**
 * fetchHistory(urlTemplate, days) → { date: rows[] }
 * urlTemplate: './data/Hw/_history/Dorado_Dashboard_{D}.csv'  ({D} = YYYY-MM-DD)
 * Son N günün history dosyalarını paralel arar, bulunanları döner.
 */
async function fetchHistory(urlTemplate, days = 30, concurrency = 5) {
  const today = new Date();
  const dates = Array.from({ length: days }, (_, i) => {
    const d = new Date(today);
    d.setDate(d.getDate() - i - 1);
    return d.toISOString().slice(0, 10); // YYYY-MM-DD — matches _history file names
  });

  const result = {};

  // Batch fetches to avoid overwhelming UNC file shares with 30 simultaneous requests
  for (let i = 0; i < dates.length; i += concurrency) {
    const chunk = dates.slice(i, i + concurrency);
    await Promise.allSettled(chunk.map(async date => {
      const url = urlTemplate.replace('{D}', date);
      const text = await fetchCSVText(url).catch(() => '');
      if (text) result[date] = parseCSV(text);
    }));
  }

  return result;
}

/* ════════════════════════════════════════════════════════════
   ÇIKTI SANİTİZASYONU
   Tüm HTML render işlemlerinde kullanılmalı.
════════════════════════════════════════════════════════════ */
// esc() zaten tanımlı (satır 124). Alias:
const sanitize = typeof esc === 'function' ? esc : s => String(s == null ? '' : s);

/**
 * safeText(el, value) — DOM elementine metin güvenli yazar (innerHTML değil)
 */
function safeText(el, value) {
  if (!el) return;
  el.textContent = value == null ? '' : String(value);
}

/**
 * safeHTML(el, html) — Sanitize edilmiş HTML yazar
 * Yalnızca esc() ile çıktısı temizlenmiş stringler için kullanılmalı.
 */
function safeHTML(el, html) {
  if (!el) return;
  el.innerHTML = html == null ? '' : String(html);
}

/* ════════════════════════════════════════════════════════════
   PORTAL-WIDE STALE DATA DETECTOR
════════════════════════════════════════════════════════════ */

const STALE_THRESHOLD_HR = 25;

async function checkPortalFreshness(vendorUrls = []) {
  if (vendorUrls.length === 0) return;
  const dates = await Promise.all(vendorUrls.map(getCSVFreshness));
  const valid = dates.filter(d => d);
  if (valid.length === 0) return;

  const oldest = new Date(Math.min(...valid.map(d => d.getTime())));
  const f = freshnessText(oldest);

  if (f.age >= STALE_THRESHOLD_HR) {
    showStaleBanner(f);
  }
}

// ── PORTAL-WIDE STALE DATA AUTO-CHECK ────────────────────────────────
// Runs on every page. Each vendor page passes its own CSVs;
// analytics/tool pages use the master vendor list as a proxy for overall data age.
const _ALL_VENDOR_CSVS = [
  './data/Hw/Dorado_Dashboard.csv',
  './data/NetApp/NetApp_Dashboard.csv',
  './data/Pure/Pure_Dashboard.csv',
  './data/Pmax/PmaxPoolDash.csv',
  './data/Ecs/ECS_Dashboard.csv',
  './data/Hitachi/Hitachi_PROD.csv',
  './data/San/SAN_Director_Dashboard.csv'
];

/**
 * autoCheckFreshness(csvUrls)
 * Called once per page after data loads. If csvUrls is omitted or empty,
 * falls back to the master vendor list (used by analytics/tool pages).
 * Deduplicates — will not show the banner more than once per page load.
 */
function autoCheckFreshness(csvUrls) {
  const urls = (csvUrls && csvUrls.length) ? csvUrls : _ALL_VENDOR_CSVS;
  checkPortalFreshness(urls);
}

// Auto-trigger on DOMContentLoaded for pages that don't call it explicitly.
// Vendor pages call autoCheckFreshness() themselves after their data loads (better timing).
// Analytics and tool pages have no single CSV anchor so we fire it here.
window.addEventListener('DOMContentLoaded', () => {
  // Delay slightly so page-specific calls (if any) fire first and avoid double-banner
  setTimeout(() => {
    if (!document.getElementById('stale-data-banner')) {
      autoCheckFreshness(_ALL_VENDOR_CSVS);
    }
  }, 2000);
});

function showStaleBanner(freshness) {
  if (document.getElementById('stale-data-banner')) return;

  const banner = document.createElement('div');
  banner.id = 'stale-data-banner';
  banner.className = 'stale-banner';

  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.innerHTML = '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>';

  const msg = document.createElement('span');
  msg.textContent = `DİKKAT: Veriler güncel olmayabilir. Son güncelleme: ${esc(freshness.text)} (${esc(freshness.stamp)})`;

  const closeBtn = document.createElement('div');
  closeBtn.className = 'stale-banner-close';
  closeBtn.textContent = '✕';
  closeBtn.addEventListener('click', () => banner.remove());

  banner.append(svg, msg, closeBtn);
  document.body.prepend(banner);
}

/* ════════════════════════════════════════════════════════════
   PERFORMANCE HELPERS
════════════════════════════════════════════════════════════ */

/**
 * debounce(fn, ms) — delays fn until ms milliseconds after last call.
 * Use on search/filter inputs to avoid per-keystroke full table rebuilds.
 */
function debounce(fn, ms = 180) {
  let t;
  return function(...args) {
    clearTimeout(t);
    t = setTimeout(() => fn.apply(this, args), ms);
  };
}

/**
 * renderTableRows(tbodyEl, rows, rowBuilderFn)
 * Clears tbody and re-renders rows via DocumentFragment to minimise reflows.
 * rowBuilderFn(row, index) must return an HTMLElement (<tr>).
 * Rows > LAZY_THRESHOLD are rendered in a requestAnimationFrame to avoid
 * blocking the main thread on initial paint.
 */
const LAZY_THRESHOLD = 200;

function renderTableRows(tbodyEl, rows, rowBuilderFn) {
  if (!tbodyEl) return;
  tbodyEl.innerHTML = '';

  const frag = document.createDocumentFragment();
  const total = rows.length;

  if (total <= LAZY_THRESHOLD) {
    rows.forEach((r, i) => frag.appendChild(rowBuilderFn(r, i)));
    tbodyEl.appendChild(frag);
    return;
  }

  // Large dataset: render first chunk synchronously, rest in rAF
  const CHUNK = 100;
  rows.slice(0, CHUNK).forEach((r, i) => frag.appendChild(rowBuilderFn(r, i)));
  tbodyEl.appendChild(frag);

  let offset = CHUNK;
  function renderChunk() {
    if (offset >= total) return;
    const f2 = document.createDocumentFragment();
    rows.slice(offset, offset + CHUNK).forEach((r, i) => f2.appendChild(rowBuilderFn(r, offset + i)));
    tbodyEl.appendChild(f2);
    offset += CHUNK;
    requestAnimationFrame(renderChunk);
  }
  requestAnimationFrame(renderChunk);
}

/**
 * buildTr(cells) — builds a <tr> from an array of {text, cls, title, html} descriptors.
 * Always escapes text content. Use html only for pre-sanitized badge strings.
 */
function buildTr(cells, rowClass) {
  const tr = document.createElement('tr');
  if (rowClass) tr.className = rowClass;
  cells.forEach(cell => {
    const td = document.createElement('td');
    if (cell.cls) td.className = cell.cls;
    if (cell.title) td.title = cell.title;
    if (cell.html !== undefined) {
      td.innerHTML = cell.html; // caller is responsible for sanitization
    } else {
      td.textContent = cell.text != null ? String(cell.text) : '';
    }
    tr.appendChild(td);
  });
  return tr;
}

/* ════════════════════════════════════════════════════════════
   THEME TOGGLE — dark/light, persisted to localStorage
════════════════════════════════════════════════════════════ */

const SP_THEME_KEY = 'sp-theme';

function spGetTheme() {
  try { return localStorage.getItem(SP_THEME_KEY) || 'dark'; } catch { return 'dark'; }
}

function spSetTheme(t) {
  document.documentElement.setAttribute('data-theme', t === 'light' ? 'light' : '');
  try { localStorage.setItem(SP_THEME_KEY, t); } catch {}
  document.querySelectorAll('.theme-toggle').forEach(btn => {
    btn.textContent = t === 'light' ? '☾ DARK' : '☀ LIGHT';
    btn.title = t === 'light' ? 'Koyu temaya geç' : 'Açık temaya geç';
  });
}

function spToggleTheme() {
  spSetTheme(spGetTheme() === 'light' ? 'dark' : 'light');
}

/**
 * injectThemeToggle(containerId)
 * Inserts a theme toggle button into the given container element.
 * If containerId is omitted, appends to document.body.
 */
function injectThemeToggle(containerId) {
  const btn = document.createElement('button');
  btn.className = 'theme-toggle';
  btn.addEventListener('click', spToggleTheme);

  const target = containerId ? document.getElementById(containerId) : null;
  if (target) target.appendChild(btn);
  else document.body.appendChild(btn);
}

// Apply saved theme immediately on every page
(function applyThemeOnLoad() {
  const saved = spGetTheme();
  if (saved === 'light') {
    document.documentElement.setAttribute('data-theme', 'light');
  }
  // Inject toggle into header-meta if it exists (index.html), or nav area
  window.addEventListener('DOMContentLoaded', () => {
    spSetTheme(spGetTheme()); // sync button label

    // Auto-inject into header-meta if present
    const hm = document.querySelector('.header-meta, .hdr-right');
    if (hm) {
      const btn = document.createElement('button');
      btn.className = 'theme-toggle';
      btn.addEventListener('click', spToggleTheme);
      hm.prepend(btn);
      spSetTheme(spGetTheme());
    }
  });
})();
