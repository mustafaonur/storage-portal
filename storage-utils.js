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
  
  // Olası negatif sayı boşluklarını temizle (- 150 -> -150)
  if (s.startsWith('-')) {
    s = '-' + s.substring(1).trim();
  }

  if (s.includes('.') && s.includes(',')) {
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
      s = s.replace(/\./g, '').replace(',', '.');
    } else {
      s = s.replace(/,/g, '');
    }
  } else if (s.includes(',')) {
    s = s.replace(',', '.');
  }
  
  // Sadece rakamlar, nokta ve eksi işaretini koru
  s = s.replace(/[^\d.\-]/g, '');
  const parsed = parseFloat(s);
  return isNaN(parsed) ? 0 : parsed;
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
  el.innerHTML = `<span title="Son güncelleme: ${f.stamp}"
    style="font-size:10px;color:${f.color};display:inline-flex;align-items:center;gap:5px">
    <span style="width:6px;height:6px;border-radius:50%;background:${f.color};display:inline-block"></span>
    Veri: ${f.text}</span>`;
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

function dateRangeBack(n) {
  const d = [], now = new Date();
  for (let i = n - 1; i >= 0; i--) {
    const dt = new Date(now);
    dt.setDate(dt.getDate() - i);
    d.push(dt.toISOString().slice(0, 10).replace(/-/g, ''));
  }
  return d;
}

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
 * urlMap = { dorado: './Hw/Dorado_Dashboard.csv', pmax: './Pmax/PmaxPoolDash.csv', ... }
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
 * urlTemplate: './Hw/_history/Dorado_Dashboard_{D}.csv'  ({D} = YYYY-MM-DD)
 * Son N günün history dosyalarını paralel arar, bulunanları döner.
 */
async function fetchHistory(urlTemplate, days = 30) {
  const today = new Date();
  const dates = Array.from({ length: days }, (_, i) => {
    const d = new Date(today);
    d.setDate(d.getDate() - i - 1);
    return d.toISOString().slice(0, 10).replace(/-/g, '');
  });
  const result = {};
  await Promise.all(dates.map(async date => {
    const url = urlTemplate.replace('{D}', date);
    const text = await fetchCSVText(url).catch(() => '');
    if (text) result[date] = parseCSV(text);
  }));
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
