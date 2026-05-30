/**
 * micro-interactions.js
 * Handcrafted animation layer — count-ups, scroll reveals,
 * section title draw-ins, bar fills. No framework dependency.
 */
(function MicroInteractions() {
  'use strict';

  /* ─────────────────────────────────────────────────────────────
     1. STAT COUNT-UP
     Numbers animate from 0 → final value with cubic ease-out.
     Triggered when the stat card scrolls into view.
  ───────────────────────────────────────────────────────────── */
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }

  function countUp(el, target, duration) {
    duration = duration || 1300;
    const isFloat   = (target % 1 !== 0);
    const decimals  = isFloat ? 2 : 0;
    const startTime = performance.now();

    function frame(now) {
      const elapsed  = now - startTime;
      const progress = Math.min(elapsed / duration, 1);
      const eased    = easeOutCubic(progress);
      const current  = eased * target;

      el.textContent = current.toLocaleString('tr-TR', {
        minimumFractionDigits: decimals,
        maximumFractionDigits: decimals
      });

      if (progress < 1) requestAnimationFrame(frame);
      else el.textContent = target.toLocaleString('tr-TR', {
        minimumFractionDigits: decimals,
        maximumFractionDigits: decimals
      });
    }
    requestAnimationFrame(frame);
  }

  /**
   * Called by index.html render() after stat values are set.
   * Captures the rendered number, resets to 0, then count-up animates.
   */
  window.triggerStatCountUps = function () {
    const intTargets  = ['v-hosts', 'v-cabs', 'v-alarms'];
    const floatTarget = 'v-pb';

    intTargets.forEach(function (id) {
      var el = document.getElementById(id);
      if (!el) return;
      // Parse locale-formatted number (tr-TR uses . as thousands sep)
      var raw = el.textContent.replace(/\./g, '').replace(',', '.');
      var n   = parseFloat(raw);
      if (isNaN(n) || n <= 0) return;
      el.textContent = '0';
      countUp(el, n, 1200);
    });

    var pbEl = document.getElementById(floatTarget);
    if (pbEl) {
      var raw = pbEl.textContent.replace(',', '.');
      var n   = parseFloat(raw);
      if (!isNaN(n) && n > 0) {
        pbEl.textContent = '0,00';
        countUp(pbEl, n, 1500);
      }
    }
  };

  /* ─────────────────────────────────────────────────────────────
     2. STAGGERED CARD REVEAL (IntersectionObserver)
     Cards enter with a 55ms stagger so the grid feels assembled,
     not dumped. Runs once per card — unobserves after trigger.
  ───────────────────────────────────────────────────────────── */
  var cardObserver = new IntersectionObserver(function (entries) {
    // Group entries that fire simultaneously, stagger within group
    var visible = entries.filter(function (e) { return e.isIntersecting; });
    visible.forEach(function (entry, i) {
      var el = entry.target;
      var delay = i * 55;
      setTimeout(function () {
        el.classList.remove('reveal-pending');
        el.classList.add('revealed');
      }, delay);
      cardObserver.unobserve(el);
    });
  }, { rootMargin: '0px 0px -50px 0px', threshold: 0.06 });

  function initCardReveal() {
    document.querySelectorAll('.app-card').forEach(function (card) {
      // Skip cards already animated by the page's own fadeInUp
      if (card.classList.contains('app-disabled')) return;
      card.classList.add('reveal-pending');
      cardObserver.observe(card);
    });
  }

  /* ─────────────────────────────────────────────────────────────
     3. SECTION TITLE DRAW-IN LINE
     The ::after gradient-rule extends when the title scrolls in.
  ───────────────────────────────────────────────────────────── */
  var titleObserver = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('title-visible');
      titleObserver.unobserve(entry.target);
    });
  }, { threshold: 0.7 });

  function initTitleLines() {
    document.querySelectorAll('.section-title').forEach(function (el) {
      titleObserver.observe(el);
    });
  }

  /* ─────────────────────────────────────────────────────────────
     4. LAYER BAR FILL ON SCROLL
     Captures current bar widths, resets to 0%, animates on entry.
  ───────────────────────────────────────────────────────────── */
  var barObserver = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.querySelectorAll('.layer-bar-fill').forEach(function (fill) {
        var target = fill.dataset.barTarget || '0%';
        fill.style.width = '0%';
        // Delay slightly so the card reveal animation leads
        setTimeout(function () { fill.style.width = target; }, 150);
      });
      barObserver.unobserve(entry.target);
    });
  }, { threshold: 0.4 });

  function initBarFills() {
    document.querySelectorAll('.layer-card').forEach(function (card) {
      card.querySelectorAll('.layer-bar-fill').forEach(function (fill) {
        var w = fill.style.width || '0%';
        fill.dataset.barTarget = w;
        fill.style.width = '0%';
      });
      barObserver.observe(card);
    });
  }

  /* ─────────────────────────────────────────────────────────────
     5. STAT CARD HOVER — left bar pulse (one-shot on enter)
  ───────────────────────────────────────────────────────────── */
  function initStatHover() {
    document.querySelectorAll('.stat-card').forEach(function (card) {
      var bar = card.querySelector('.stat-card::before'); // CSS handles this
      card.addEventListener('mouseenter', function () {
        // Briefly intensify the accent bar via outline flash
        card.style.outline = '1px solid transparent';
        requestAnimationFrame(function () { card.style.outline = ''; });
      });
    });
  }

  /* ─────────────────────────────────────────────────────────────
     6. LAYER CARD: number highlight on hover
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
     INIT — run after DOM is ready; cards/bars init after a small
     delay so the loading overlay has lifted before we observe.
  ───────────────────────────────────────────────────────────── */
  function init() {
    initTitleLines();
    initLayerHover();
    initStatHover();

    // Wait for loading overlay to clear before initiating reveal
    setTimeout(function () {
      initCardReveal();
      initBarFills();
    }, 600);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
