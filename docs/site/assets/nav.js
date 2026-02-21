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
  }

  window.addEventListener('resize', setup);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setup);
  } else {
    setup();
  }
})();
