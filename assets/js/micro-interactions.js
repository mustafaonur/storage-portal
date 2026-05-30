/**
 * micro-interactions.js  v4
 * Physical, handcrafted, domain-specific premium interactions.
 *
 * Systems:
 *   1.  3D card tilt + cursor spotlight (rAF lerp)
 *   2.  Text scramble on section titles
 *   3.  Card construction reveal (blur + overshoot)
 *   4.  Stat count-up with mechanical snap
 *   5.  Layer ring / bar fills on viewport entry
 *   6.  G+key keyboard navigation (Gmail-style)
 *   7.  Right-click context menu on cards
 *   8.  Ambient idle scan beam
 */
(function MicroInteractions() {
  'use strict';

  /* ── utilities ─────────────────────────────────────────────── */
  function lerp(a, b, t) { return a + (b - a) * t; }
  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }
  function esc(s) {
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  /* ═══════════════════════════════════════════════════════════
     1. 3D CARD TILT + CURSOR SPOTLIGHT
  ═══════════════════════════════════════════════════════════ */
  function initCardTilt() {
    var TILT   = 7;
    var T_IN   = 0.10;
    var T_OUT  = 0.08;

    document.querySelectorAll('.app-card:not(.app-disabled)').forEach(function (card) {
      var cur = { rx: 0, ry: 0, mx: 50, my: 50 };
      var tgt = { rx: 0, ry: 0, mx: 50, my: 50 };
      var raf = null;
      var inside = false;

      function tick() {
        var sp = inside ? T_IN : T_OUT;
        cur.rx = lerp(cur.rx, tgt.rx, sp);
        cur.ry = lerp(cur.ry, tgt.ry, sp);
        cur.mx = lerp(cur.mx, tgt.mx, sp);
        cur.my = lerp(cur.my, tgt.my, sp);

        card.style.transform =
          'perspective(720px) rotateX(' + cur.rx.toFixed(2) + 'deg)' +
          ' rotateY(' + cur.ry.toFixed(2) + 'deg) translateZ(4px)';
        card.style.setProperty('--mx', cur.mx.toFixed(1) + '%');
        card.style.setProperty('--my', cur.my.toFixed(1) + '%');

        var d = Math.abs(cur.rx - tgt.rx) + Math.abs(cur.ry - tgt.ry);
        if (d > 0.04 || inside) { raf = requestAnimationFrame(tick); }
        else {
          card.style.transform = '';
          card.style.setProperty('--mx', '50%');
          card.style.setProperty('--my', '50%');
          raf = null;
        }
      }

      card.addEventListener('mousemove', function (e) {
        var r = card.getBoundingClientRect();
        var x = clamp((e.clientX - r.left) / r.width, 0, 1);
        var y = clamp((e.clientY - r.top)  / r.height, 0, 1);
        tgt.ry =  (x - 0.5) * TILT * 2;
        tgt.rx = -(y - 0.5) * TILT * 2;
        tgt.mx = x * 100; tgt.my = y * 100;
        if (!raf) raf = requestAnimationFrame(tick);
      });
      card.addEventListener('mouseenter', function () { inside = true; });
      card.addEventListener('mouseleave', function () {
        inside = false;
        tgt.rx = 0; tgt.ry = 0; tgt.mx = 50; tgt.my = 50;
        if (!raf) raf = requestAnimationFrame(tick);
      });
    });
  }

  /* ═══════════════════════════════════════════════════════════
     2. TEXT SCRAMBLE — section titles
  ═══════════════════════════════════════════════════════════ */
  var CHARSET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789▓▒░█▌▐';

  function scramble(el) {
    var orig = el.dataset.origText || el.textContent.trim();
    el.dataset.origText = orig;
    el.classList.add('scrambling');
    var frames = 18, frame = 0;
    var iv = setInterval(function () {
      var progress = frame / frames;
      var resolved = Math.floor(progress * orig.length);
      el.textContent = orig.split('').map(function (ch, i) {
        if (ch === ' ') return ' ';
        if (i < resolved) return ch;
        return CHARSET[Math.floor(Math.random() * CHARSET.length)];
      }).join('');
      frame++;
      if (frame > frames) {
        clearInterval(iv);
        el.textContent = orig;
        el.classList.remove('scrambling');
        el.classList.add('title-visible');
      }
    }, 42);
  }

  function initScramble() {
    var obs = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        scramble(e.target);
        obs.unobserve(e.target);
      });
    }, { threshold: 0.8 });
    document.querySelectorAll('.section-title').forEach(function (el) { obs.observe(el); });
  }

  /* ═══════════════════════════════════════════════════════════
     3. CARD CONSTRUCTION REVEAL
  ═══════════════════════════════════════════════════════════ */
  function initReveal() {
    var appObs = new IntersectionObserver(function (entries) {
      entries.filter(function (e) { return e.isIntersecting; }).forEach(function (e, i) {
        var el = e.target;
        setTimeout(function () {
          el.classList.remove('reveal-pending');
          el.classList.add('revealed');
        }, i * 60);
        appObs.unobserve(el);
      });
    }, { rootMargin: '0px 0px -40px 0px', threshold: 0.05 });

    var layObs = new IntersectionObserver(function (entries) {
      entries.filter(function (e) { return e.isIntersecting; }).forEach(function (e, i) {
        var el = e.target;
        setTimeout(function () {
          el.classList.remove('reveal-pending');
          el.classList.add('revealed');
        }, i * 80);
        layObs.unobserve(el);
      });
    }, { threshold: 0.15 });

    document.querySelectorAll('.app-card').forEach(function (c) {
      if (c.classList.contains('app-disabled')) return;
      c.classList.add('reveal-pending');
      appObs.observe(c);
    });
    document.querySelectorAll('.layer-card').forEach(function (c) {
      c.classList.add('reveal-pending');
      layObs.observe(c);
    });
  }

  /* ═══════════════════════════════════════════════════════════
     4. STAT COUNT-UP — mechanical snap at 90%
  ═══════════════════════════════════════════════════════════ */
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }

  function countUp(el, target, dur) {
    dur = dur || 1300;
    var isFloat = target % 1 !== 0;
    var dec     = isFloat ? 2 : 0;
    var snapped = false;
    var t0      = performance.now();

    function frame(now) {
      var progress = Math.min((now - t0) / dur, 1);
      var eased    = easeOutCubic(progress);

      if (progress >= 0.90 && !snapped) {
        snapped = true;
        var step = isFloat ? 0.01 : 1;
        var pen  = Math.max(0, target - step);
        el.textContent = pen.toLocaleString('tr-TR', { minimumFractionDigits: dec, maximumFractionDigits: dec });
        setTimeout(function () {
          el.textContent = target.toLocaleString('tr-TR', { minimumFractionDigits: dec, maximumFractionDigits: dec });
        }, 80);
        return;
      }
      if (!snapped) {
        el.textContent = (eased * target).toLocaleString('tr-TR', { minimumFractionDigits: dec, maximumFractionDigits: dec });
      }
      if (progress < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  window.triggerStatCountUps = function () {
    ['v-hosts', 'v-cabs', 'v-alarms'].forEach(function (id) {
      var el = document.getElementById(id);
      if (!el) return;
      var n = parseFloat(el.textContent.replace(/\./g, '').replace(',', '.'));
      if (isNaN(n) || n <= 0) return;
      el.textContent = '0';
      countUp(el, n, 1200);
    });
    var pb = document.getElementById('v-pb');
    if (pb) {
      var n = parseFloat(pb.textContent.replace(',', '.'));
      if (!isNaN(n) && n > 0) { pb.textContent = '0,00'; countUp(pb, n, 1550); }
    }
  };

  /* ═══════════════════════════════════════════════════════════
     5. RING / BAR FILL on viewport entry
     Rings: stroke-dashoffset stored as data-ring-target
     Bars:  style.width stored as data-bar-target
  ═══════════════════════════════════════════════════════════ */
  function initFills() {
    var CIRC = 113.097;
    var obs = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        // rings
        e.target.querySelectorAll('.layer-ring-fill').forEach(function (ring) {
          var t = ring.dataset.ringTarget;
          if (t === undefined) return;
          ring.style.strokeDashoffset = String(CIRC);
          setTimeout(function () { ring.style.strokeDashoffset = t; }, 180);
        });
        // bars (fallback for pages not using rings)
        e.target.querySelectorAll('.layer-bar-fill').forEach(function (fill) {
          var t = fill.dataset.barTarget || '0%';
          fill.style.width = '0%';
          setTimeout(function () { fill.style.width = t; }, 180);
        });
        obs.unobserve(e.target);
      });
    }, { threshold: 0.35 });

    document.querySelectorAll('.layer-card').forEach(function (card) {
      // cache ring targets
      card.querySelectorAll('.layer-ring-fill').forEach(function (ring) {
        ring.dataset.ringTarget = ring.style.strokeDashoffset || String(CIRC);
        ring.style.strokeDashoffset = String(CIRC);
      });
      // cache bar targets
      card.querySelectorAll('.layer-bar-fill').forEach(function (fill) {
        fill.dataset.barTarget = fill.style.width || '0%';
        fill.style.width = '0%';
      });
      obs.observe(card);
    });
  }

  /* ═══════════════════════════════════════════════════════════
     6. G+KEY KEYBOARD NAVIGATION  (Gmail-style)
     Press G, then a letter within 1.5s to navigate.
     Shows a HUD indicator while waiting.
  ═══════════════════════════════════════════════════════════ */
  var SHORTCUTS = {
    'h': './huawei.html',
    'p': './pmax.html',
    's': './san.html',
    'f': './pure-fa.html',
    'b': './pure-fb.html',
    'n': './netapp.html',
    'e': './ecs.html',
    'i': './hitachi.html',
    't': './trend.html',
    'a': './anomaly.html',
    'c': './capacity-planner.html',
    'l': './lake.html',
    'z': './zone-builder.html',
    'm': './management.html',
    'x': './executive.html'
  };

  function initKeyboardNav() {
    // Add shortcut badges to cards
    var badgeMap = {
      'huawei.html':           'G H',
      'pmax.html':             'G P',
      'san.html':              'G S',
      'pure-fa.html':          'G F',
      'pure-fb.html':          'G B',
      'netapp.html':           'G N',
      'ecs.html':              'G E',
      'hitachi.html':          'G I',
      'trend.html':            'G T',
      'anomaly.html':          'G A',
      'capacity-planner.html': 'G C',
      'lake.html':             'G L',
      'zone-builder.html':     'G Z',
      'management.html':       'G M',
      'executive.html':        'G X'
    };

    document.querySelectorAll('.app-card[href]').forEach(function (card) {
      var href = card.getAttribute('href') || '';
      var base = href.replace('./', '').split('/').pop();
      if (badgeMap[base]) {
        var badge = document.createElement('div');
        badge.className = 'card-shortcut';
        badge.textContent = badgeMap[base];
        card.appendChild(badge);
      }
    });

    // HUD element
    var hud = document.createElement('div');
    hud.id = 'g-mode-hud';
    hud.textContent = 'G — waiting for key…';
    document.body.appendChild(hud);

    var gMode = false;
    var gTimer = null;

    function exitGMode() {
      gMode = false;
      hud.classList.remove('active');
      clearTimeout(gTimer);
    }

    document.addEventListener('keydown', function (e) {
      // Don't fire when typing in inputs
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) return;

      if (!gMode && e.key === 'g') {
        e.preventDefault();
        gMode = true;
        hud.classList.add('active');
        gTimer = setTimeout(exitGMode, 1500);
        return;
      }

      if (gMode) {
        e.preventDefault();
        var dest = SHORTCUTS[e.key.toLowerCase()];
        exitGMode();
        if (dest) window.location.href = dest;
      }
    });
  }

  /* ═══════════════════════════════════════════════════════════
     7. RIGHT-CLICK CONTEXT MENU
  ═══════════════════════════════════════════════════════════ */
  function initContextMenu() {
    var menu = document.createElement('div');
    menu.className = 'ctx-menu';
    menu.style.display = 'none';
    document.body.appendChild(menu);

    var activeCard = null;

    function show(x, y, card) {
      activeCard = card;
      var href = card.getAttribute('href') || '#';
      var name = (card.querySelector('.app-card-name') || {}).textContent || '';

      menu.innerHTML = [
        '<div class="ctx-item" data-action="open">',
        '  <span class="ctx-icon">↗</span> Open',
        '  <span class="ctx-kbd">Enter</span>',
        '</div>',
        '<div class="ctx-item" data-action="tab">',
        '  <span class="ctx-icon">⊞</span> Open in new tab',
        '  <span class="ctx-kbd">⌘↗</span>',
        '</div>',
        '<div class="ctx-divider"></div>',
        '<div class="ctx-item" data-action="copy">',
        '  <span class="ctx-icon">⎘</span> Copy link',
        '</div>',
        '<div class="ctx-item" data-action="csv">',
        '  <span class="ctx-icon">⇩</span> View CSV source',
        '</div>'
      ].join('');

      // Position: keep within viewport
      menu.style.display = 'block';
      var mw = menu.offsetWidth, mh = menu.offsetHeight;
      var vw = window.innerWidth, vh = window.innerHeight;
      menu.style.left = (x + mw > vw ? vw - mw - 8 : x) + 'px';
      menu.style.top  = (y + mh > vh ? vh - mh - 8 : y) + 'px';
    }

    function hide() {
      menu.style.display = 'none';
      activeCard = null;
    }

    document.addEventListener('contextmenu', function (e) {
      var card = e.target.closest('.app-card:not(.app-disabled)');
      if (!card || !card.getAttribute('href') || card.getAttribute('href') === '#') return;
      e.preventDefault();
      show(e.clientX, e.clientY, card);
    });

    menu.addEventListener('click', function (e) {
      var item = e.target.closest('.ctx-item');
      if (!item || !activeCard) return;
      var action = item.dataset.action;
      var href = activeCard.getAttribute('href') || '#';
      var abs = new URL(href, window.location.href).href;

      if (action === 'open')  { hide(); window.location.href = href; }
      if (action === 'tab')   { hide(); window.open(href, '_blank'); }
      if (action === 'copy')  {
        navigator.clipboard && navigator.clipboard.writeText(abs);
        item.querySelector('.ctx-icon').textContent = '✓';
        setTimeout(hide, 700);
      }
      if (action === 'csv') {
        hide();
        // Best-effort: open the vendor's primary dashboard CSV
        var csvMap = {
          'huawei.html':           './data/Hw/Dorado_Dashboard.csv',
          'pmax.html':             './data/Pmax/PmaxPoolDash.csv',
          'pure-fa.html':          './data/Pure/Pure_Dashboard.csv',
          'pure-fb.html':          './data/Pure/FB_Dashboard.csv',
          'netapp.html':           './data/NetApp/NetApp_Dashboard.csv',
          'ecs.html':              './data/Ecs/ECS_Dashboard.csv',
          'san.html':              './data/San/SAN_Director_Dashboard.csv',
          'hitachi.html':          './data/Hitachi/Hitachi_PROD.csv'
        };
        var base = href.replace('./', '');
        var csv  = csvMap[base];
        if (csv) window.open(csv, '_blank');
      }
    });

    document.addEventListener('click',   function (e) { if (!menu.contains(e.target)) hide(); });
    document.addEventListener('keydown',  function (e) { if (e.key === 'Escape') hide(); });
    document.addEventListener('scroll',   hide, { passive: true });
  }

  /* ═══════════════════════════════════════════════════════════
     8. AMBIENT IDLE SCAN BEAM
     Appears after 15s of inactivity. Any interaction hides it.
  ═══════════════════════════════════════════════════════════ */
  function initScanBeam() {
    var beam = document.createElement('div');
    beam.className = 'scan-beam';
    document.body.appendChild(beam);

    var timer = null;

    function goActive()  { beam.classList.add('active'); }
    function goIdle()    {
      beam.classList.remove('active');
      clearTimeout(timer);
      timer = setTimeout(goActive, 15000);
    }

    ['mousemove', 'keydown', 'click', 'scroll', 'touchstart'].forEach(function (ev) {
      document.addEventListener(ev, goIdle, { passive: true });
    });
    goIdle(); // arm immediately
  }


  /* ═══════════════════════════════════════════════════════════
     BOOT
  ═══════════════════════════════════════════════════════════ */
  function boot() {
    initScramble();
    initKeyboardNav();
    initContextMenu();
    initScanBeam();

    setTimeout(function () {
      initCardTilt();
      initReveal();
      initFills();
    }, 700);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

})();
