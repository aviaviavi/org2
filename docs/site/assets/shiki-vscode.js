import { createHighlighter } from 'https://esm.sh/shiki@1.29.1';

const THEME_LIGHT = 'github-light';
const THEME_DARK = 'github-dark';

function prefersDark() {
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function languageFromCodeEl(codeEl) {
  const cls = codeEl.className || '';
  const m = cls.match(/language-([a-zA-Z0-9_+-]+)/);
  if (!m) return 'text';
  const raw = m[1].toLowerCase();
  if (raw === 'js') return 'javascript';
  if (raw === 'ts') return 'typescript';
  if (raw === 'sh' || raw === 'shell') return 'bash';
  if (raw === 'yml') return 'yaml';
  // org/org2 grammar is not bundled in Shiki by default; fall back to text.
  if (raw === 'org' || raw === 'org2') return 'text';
  return raw;
}

function activeTheme() {
  return prefersDark() ? THEME_DARK : THEME_LIGHT;
}

async function run() {
  const highlighter = await createHighlighter({
    themes: [THEME_LIGHT, THEME_DARK],
    langs: ['text', 'bash', 'json', 'javascript', 'typescript', 'tsx', 'yaml', 'html', 'css', 'markdown', 'sql', 'haskell', 'java', 'c', 'cpp', 'csharp', 'ruby', 'php', 'kotlin', 'swift', 'scala', 'lua', 'go', 'rust', 'python']
  });

  const theme = activeTheme();

  // Block code: pre > code
  for (const pre of document.querySelectorAll('pre.org2-src')) {
    const codeEl = pre.querySelector('code');
    if (!codeEl) continue;
    const code = codeEl.textContent || '';
    const lang = languageFromCodeEl(codeEl);
    const html = highlighter.codeToHtml(code, { lang, theme });
    const wrapper = document.createElement('div');
    wrapper.innerHTML = html;
    const shikiPre = wrapper.querySelector('pre.shiki');
    if (!shikiPre) continue;
    shikiPre.classList.add('org2-shiki-block');
    pre.replaceWith(shikiPre);
  }

  // Re-render on theme changes.
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  media.addEventListener?.('change', () => window.location.reload());
}

run().catch((err) => {
  console.error('shiki highlight failed', err);
});
