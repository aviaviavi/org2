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

  function closeDropdown(el) {
    var summary = el.querySelector(':scope > summary');
    el.removeAttribute('open');
    if (summary) summary.setAttribute('aria-expanded', 'false');
  }

  function closeOtherDropdowns(active) {
    document.querySelectorAll('.org2-nav-dropdown[open]').forEach(function (el) {
      if (el !== active) closeDropdown(el);
    });
  }

  function setupHoverDropdowns() {
    document.querySelectorAll('.org2-nav-dropdown').forEach(function (el) {
      var summary = el.querySelector(':scope > summary');
      if (!summary || el.dataset.hoverReady === '1') return;
      el.dataset.hoverReady = '1';

      el.addEventListener('mouseenter', function () {
        if (isMobile()) return;
        closeOtherDropdowns(el);
        el.setAttribute('open', '');
        summary.setAttribute('aria-expanded', 'true');
      });

      el.addEventListener('mouseleave', function () {
        if (isMobile()) return;
        if (!el.contains(document.activeElement)) closeDropdown(el);
      });

      summary.addEventListener('click', function (event) {
        if (!isMobile()) event.preventDefault();
      });

      el.addEventListener('focusin', function () {
        if (isMobile()) return;
        closeOtherDropdowns(el);
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

  function setupSearch() {
    var forms = document.querySelectorAll('.org2-site-search');
    if (!forms.length) return;

    var indexPromise = fetch('assets/search-index.json')
      .then(function (response) { return response.ok ? response.json() : []; })
      .catch(function () { return []; });

    function score(page, query) {
      var haystack = [page.title, page.description, page.url].join(' ').toLowerCase();
      var terms = query.toLowerCase().split(/\s+/).filter(Boolean);
      if (!terms.length) return 0;
      return terms.reduce(function (total, term) {
        if ((page.title || '').toLowerCase().indexOf(term) !== -1) return total + 4;
        return haystack.indexOf(term) !== -1 ? total + 1 : total;
      }, 0);
    }

    forms.forEach(function (form) {
      if (form.dataset.searchReady === '1') return;
      form.dataset.searchReady = '1';
      var input = form.querySelector('input[type="search"]');
      var toggle = form.querySelector('.org2-site-search-toggle');
      var results = form.querySelector('.org2-site-search-results');
      if (!input || !toggle || !results) return;

      function openSearch() {
        form.classList.add('is-open');
        toggle.setAttribute('aria-expanded', 'true');
        toggle.setAttribute('aria-label', 'Close docs search');
        window.setTimeout(function () { input.focus(); }, 0);
      }

      function closeResults() {
        results.hidden = true;
        input.setAttribute('aria-expanded', 'false');
      }

      function closeSearch() {
        closeResults();
        input.value = '';
        form.classList.remove('is-open');
        toggle.setAttribute('aria-expanded', 'false');
        toggle.setAttribute('aria-label', 'Open docs search');
      }

      function render(matches) {
        results.innerHTML = '';
        if (!matches.length) {
          var empty = document.createElement('div');
          empty.className = 'org2-site-search-empty';
          empty.textContent = 'No matches';
          results.appendChild(empty);
        } else {
          matches.slice(0, 6).forEach(function (page) {
            var link = document.createElement('a');
            link.href = page.url;
            link.innerHTML = '<strong></strong><span></span>';
            link.querySelector('strong').textContent = page.title;
            link.querySelector('span').textContent = page.description || page.url;
            results.appendChild(link);
          });
        }
        results.hidden = false;
        input.setAttribute('aria-expanded', 'true');
      }

      input.addEventListener('input', function () {
        var query = input.value.trim();
        if (query.length < 2) return closeResults();
        indexPromise.then(function (pages) {
          var matches = pages
            .map(function (page) { return { page: page, score: score(page, query) }; })
            .filter(function (entry) { return entry.score > 0; })
            .sort(function (a, b) { return b.score - a.score || a.page.title.localeCompare(b.page.title); })
            .map(function (entry) { return entry.page; });
          render(matches);
        });
      });

      toggle.addEventListener('click', function () {
        if (form.classList.contains('is-open')) {
          closeSearch();
        } else {
          openSearch();
        }
      });

      form.addEventListener('submit', function (event) {
        event.preventDefault();
        if (!form.classList.contains('is-open')) return openSearch();
        var first = results.querySelector('a');
        if (first) window.location.href = first.href;
      });

      document.addEventListener('click', function (event) {
        if (!form.contains(event.target)) closeSearch();
      });

      input.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
          event.preventDefault();
          closeSearch();
          toggle.focus();
        }
      });
    });
  }

  function setupCurrentPage() {
    function normalize(pathname) {
      return pathname.endsWith('/') ? pathname + 'index.html' : pathname;
    }

    var current = normalize(window.location.pathname);
    document.querySelectorAll('.org2-nav a[href]').forEach(function (link) {
      var target = new URL(link.getAttribute('href'), window.location.href);
      if (target.origin === window.location.origin && normalize(target.pathname) === current) {
        link.setAttribute('aria-current', 'page');
      }
    });
  }

  function init() {
    setup();
    setupHoverDropdowns();
    setupSearch();
    setupCurrentPage();
  }

  window.addEventListener('resize', setup);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
