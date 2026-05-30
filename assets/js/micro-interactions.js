/**
 * micro-interactions.js  v3
 *
 * Physical, handcrafted interactions:
 *   1. 3D card tilt + cursor spotlight (rAF lerp — feels weighted)
 *   2. Text scramble on section titles (domain-appropriate terminal feel)
 *   3. Card construction reveal (blur + overshoot, not just fade)
 *   4. Layer card slide-in from left
 *   5. Stat count-up with mechanical final-digit snap
 *   6. Layer bar fills on viewport entry
 *   7. Section title draw-in line
 */
(function MicroInteractions() {
  'use strict';

  /* ── utilities ── */
  function lerp(a, b, t) { return a + (b - a) * t; }
  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

  /* ─────────────────────────────────────────────────────────────
     1. 3D TILT + CURSOR SPOTLIGHT
     Each card tilts ±7° toward the cursor via perspective transform.
     A radial spotlight (CSS var --mx/--my) follows the cursor inside
     the card — makes it feel like you're examining it with a torch.
     Uses rAF lerp so motion has inertia, not snap.
  ───────────────────────────────────────────────────────────── */
  function initCardTilt() {
    var TILT_MAX = 7;
    var LERP_POS = 0.10;   // position tracking speed
    var LERP_OUT = 0.08;   // return-to-rest speed (slightly slower = spring feel)

    document.querySelectorAll('.app-card:not(.app-disabled)').forEach(function (card) {
      var cur = { rx: 0, ry: 0, mx: 50, my: 50 };
      var tgt = { rx: 0, ry: 0, mx: 50, my: 50 };
      var rafId = null;
      var inside = false;

      function tick() {
        var sp = inside ? LERP_POS : LERP_OUT;
        cur.rx = lerp(cur.rx, tgt.rx, sp);
        cur.ry = lerp(cur.ry, tgt.ry, sp);
        cur.mx = lerp(cur.mx, tgt.mx, sp);
        cur.my = lerp(cur.my, tgt.my, sp);

        var dist = Math.abs(cur.rx - tgt.rx) + Math.abs(cur.ry - tgt.ry);

        card.style.transform =
          'perspective(720px) rotateX(' + cur.rx.toFixed(3) + 'deg)' +
          ' rotateY(' + cur.ry.toFixed(3) + 'deg)' +
          ' translateZ(4px)';
        card.style.setProperty('--mx', cur.mx.toFixed(1) + '%');
        card.style.setProperty('--my', cur.my.toFixed(1) + '%');

        if (dist > 0.04 || inside) {
          rafId = requestAnimationFrame(tick);
        } else {
          card.style.transform = '';
          card.style.setProperty('--mx', '50%');
          card.style.setProperty('--my', '50%');
          rafId = null;
        }
      }

      card.addEventListener('mousemove', function (e) {
        var r = card.getBoundingClientRect();
        var x = clamp((e.clientX - r.left) / r.width,  0, 1);
        var y = clamp((e.clientY - r.top)  / r.height, 0, 1);
        tgt.ry =  (x - 0.5) * TILT_MAX * 2;
        tgt.rx = -(y - 0.5) * TILT_MAX * 2;
        tgt.mx = x * 100;
        tgt.my = y * 100;
        if (!rafId) rafId = requestAnimationFrame(tick);
      });

      card.addEventListener('mouseenter', function () { inside = true; });

      card.addEventListener('mouseleave', function () {
        inside = false;
        tgt.rx = 0; tgt.ry = 0; tgt.mx = 50; tgt.my = 50;
        if (!rafId) rafId = requestAnimationFrame(tick);
      });
    });
  }

  /* ─────────────────────────────────────────────────────────────
     2. TEXT SCRAMBLE — section titles resolve from random chars
     Fires once on first viewport entry. Charset uses uppercase +
     digits + symbols that feel like terminal/instrument readout.
     Each character resolves left-to-right as frames progress.
  ───────────────────────────────────────────────────────────── */
  var CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789▓▒░█▌▐';

  function scramble(el) {
    var original = el.dataset.originalText || el.textContent.trim();
    el.dataset.originalText = original;
    el.classList.add('scrambling');

    var totalFrames = 18;
    var frame       = 0;
    var interval    = setInterval(function () {
      var progress = frame / totalFrames;
      var resolved = Math.floor(progress * original.length);

      el.textContent = original.split('').map(function (ch, i) {
        if (ch === ' ') return ' ';
        if (i < resolved) return ch;
        return CHARS[Math.floor(Math.random() * CHARS.length)];
      }).join('');

      frame++;
      if (frame > totalFrames) {
        clearInterval(interval);
        el.textContent = original;
        el.classList.remove('scrambling');
        el.classList.add('title-visible'); // trigger the gradient rule draw-in
      }
    }, 42); // ~24fps scramble feels mechanical, not laggy
  }

  function initScramble() {
    var obs = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        scramble(entry.target);
        obs.unobserve(entry.target);
      });
    }, { threshold: 0.8 });

    document.querySelectorAll('.section-title').forEach(function (el) {
      obs.observe(el);
    });
  }

  /* ─────────────────────────────────────────────────────────────
     3 & 4. CARD CONSTRUCTION REVEAL (staggered, IntersectionObserver)
     App cards: blur + scale + translateY + overshoot (card-construct)
     Layer cards: slide from left (layer-construct)
  ───────────────────────────────────────────────────────────── */
  function initReveal() {
    var appObs = new IntersectionObserver(function (entries) {
      var visible = entries.filter(function (e) { return e.isIntersecting; });
      visible.forEach(function (entry, i) {
        var el = entry.target;
        setTimeout(function () {
          el.classList.remove('reveal-pending');
          el.classList.add('revealed');
        }, i * 60);
        appObs.unobserve(el);
      });
    }, { rootMargin: '0px 0px -40px 0px', threshold: 0.05 });

    var layerObs = new IntersectionObserver(function (entries) {
      var visible = entries.filter(function (e) { return e.isIntersecting; });
      visible.forEach(function (entry, i) {
        var el = entry.target;
        setTimeout(function () {
          el.classList.remove('reveal-pending');
          el.classList.add('revealed');
        }, i * 80);
        layerObs.unobserve(el);
      });
    }, { threshold: 0.15 });

    document.querySelectorAll('.app-card').forEach(function (c) {
      if (c.classList.contains('app-disabled')) return;
      c.classList.add('reveal-pending');
      appObs.observe(c);
    });

    document.querySelectorAll('.layer-card').forEach(function (c) {
      c.classList.add('reveal-pending');
      layerObs.observe(c);
    });
  }

  /* ─────────────────────────────────────────────────────────────
     5. STAT COUNT-UP — cubic ease-out with mechanical snap
     The last ~8% of the animation "snaps" to final value: the number
     briefly pauses at (target - 1) then jumps to target — like an
     odometer clunking into place rather than gliding.
  ───────────────────────────────────────────────────────────── */
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }

  function countUp(el, target, duration) {
    var isFloat  = (target % 1 !== 0);
    var decimals = isFloat ? 2 : 0;
    var snapAt   = 0.90; // point at which we do the mechanical "almost there" pause
    var snapped  = false;
    var start    = performance.now();

    function frame(now) {
      var elapsed  = now - start;
      var progress = Math.min(elapsed / duration, 1);
      var eased    = easeOutCubic(progress);
      var current  = eased * target;

      // Mechanical snap: hold at (target - step) for one frame before final value
      if (progress >= snapAt && !snapped && progress < 0.98) {
        snapped = true;
        var step = isFloat ? 0.01 : 1;
        var penultimate = Math.max(0, target - step);
        el.textContent = penultimate.toLocaleString('tr-TR', {
          minimumFractionDigits: decimals, maximumFractionDigits: decimals
        });
        setTimeout(function () {
          el.textContent = target.toLocaleString('tr-TR', {
            minimumFractionDigits: decimals, maximumFractionDigits: decimals
          });
        }, 80);
        return;
      }

      if (!snapped) {
        el.textContent = current.toLocaleString('tr-TR', {
          minimumFractionDigits: decimals, maximumFractionDigits: decimals
        });
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
      countUp(el, n, 1300);
    });
    var pb = document.getElementById('v-pb');
    if (pb) {
      var n = parseFloat(pb.textContent.replace(',', '.'));
      if (!isNaN(n) && n > 0) {
        pb.textContent = '0,00';
        countUp(pb, n, 1600);
      }
    }
  };

  /* ─────────────────────────────────────────────────────────────
     6. LAYER BAR FILL on scroll entry
  ───────────────────────────────────────────────────────────── */
  function initBarFills() {
    var obs = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.querySelectorAll('.layer-bar-fill').forEach(function (fill) {
          var tgt = fill.dataset.barTarget || '0%';
          fill.style.width = '0%';
          setTimeout(function () { fill.style.width = tgt; }, 200);
        });
        obs.unobserve(entry.target);
      });
    }, { threshold: 0.4 });

    document.querySelectorAll('.layer-card').forEach(function (card) {
      card.querySelectorAll('.layer-bar-fill').forEach(function (fill) {
        fill.dataset.barTarget = fill.style.width || '0%';
        fill.style.width = '0%';
      });
      obs.observe(card);
    });
  }

  /* ─────────────────────────────────────────────────────────────
     7. LAYER CARD: highlight value on hover
  ───────────────────────────────────────────────────────────── */
  function initLayerHover() {
    document.querySelectorAll('.layer-card').forEach(function (card) {
      var val = card.querySelector('.layer-value');
      if (!val) return;
      card.addEventListener('mouseenter', function () {
        val.style.transition = 'color .15s ease';
        val.style.color = 'var(--text-bright)';
      });
      card.addEventListener('mouseleave', function () {
        val.style.color = '';
      });
    });
  }

  /* ─────────────────────────────────────────────────────────────
     BOOT — delayed until loading overlay has cleared
  ───────────────────────────────────────────────────────────── */
  function boot() {
    initScramble();
    initLayerHover();

    // Physical interactions and reveals start after loading clears
    setTimeout(function () {
      initCardTilt();
      initReveal();
      initBarFills();
    }, 700);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

})();
