(function () {
  function isMobile() {
    return window.matchMedia('(max-width: 759px)').matches;
  }

  function setup() {
    document.querySelectorAll('.org2-nav-menu').forEach(function (el) {
      var summary = el.querySelector(':scope > summary');
      if (summary) summary.textContent = '☰ Menu';

      if (isMobile()) {
        el.removeAttribute('open');
      } else {
        el.setAttribute('open', '');
      }
    });

    document.querySelectorAll('.org2-nav-dropdown').forEach(function (el) {
      var summary = el.querySelector(':scope > summary');
      if (!summary) return;

      if (isMobile()) {
        summary.setAttribute('aria-label', summary.textContent || 'Open menu');
      } else {
        el.removeAttribute('open');
        summary.setAttribute('aria-haspopup', 'true');
        summary.setAttribute('aria-expanded', 'false');
      }
    });
  }

  function setupHoverDropdowns() {
    document.querySelectorAll('.org2-nav-dropdown').forEach(function (el) {
      var summary = el.querySelector(':scope > summary');
      if (!summary || el.dataset.hoverReady === '1') return;
      el.dataset.hoverReady = '1';

      el.addEventListener('mouseenter', function () {
        if (isMobile()) return;
        el.setAttribute('open', '');
        summary.setAttribute('aria-expanded', 'true');
      });

      el.addEventListener('mouseleave', function () {
        if (isMobile()) return;
        el.removeAttribute('open');
        summary.setAttribute('aria-expanded', 'false');
      });

      summary.addEventListener('click', function (event) {
        if (!isMobile()) event.preventDefault();
      });

      el.addEventListener('focusin', function () {
        if (isMobile()) return;
        el.setAttribute('open', '');
        summary.setAttribute('aria-expanded', 'true');
      });

      el.addEventListener('focusout', function () {
        if (isMobile()) return;
        window.setTimeout(function () {
          if (!el.contains(document.activeElement)) {
            el.removeAttribute('open');
            summary.setAttribute('aria-expanded', 'false');
          }
        }, 0);
      });
    });
  }

  function init() {
    setup();
    setupHoverDropdowns();
  }

  window.addEventListener('resize', setup);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
