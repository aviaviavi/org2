import { createHighlighter } from 'https://esm.sh/shiki@1.29.1';

const THEME_LIGHT = 'github-light';
const THEME_DARK = 'github-dark';

const ORG_LANGUAGE = {
  name: 'org',
  scopeName: 'source.org',
  patterns: [
    { name: 'comment.line.number-sign.org', match: '^\\s*#(?!\\+).*?$' },
    { name: 'keyword.control.block.org', match: '^\\s*```.*$' },
    { name: 'keyword.control.block.org', match: '^\\s*#\\+(?:begin|end)_[A-Za-z0-9_-]+\\b.*$' },
    { name: 'markup.heading.org', match: '^\\*+(?=\\s)' },
    { name: 'keyword.control.todo.org', match: '\\b(?:TODO|IN_PROGRESS|DONE|CANCELLED|CANCELED|WAITING|BLOCKED|NEXT)\\b' },
    { name: 'keyword.other.planning.org', match: '^\\s*(?:SCHEDULED|DEADLINE|CLOSED):' },
    { name: 'keyword.other.directive.org', match: '^\\s*#\\+[A-Za-z][A-Za-z0-9_-]*(?=:)' },
    { name: 'entity.name.section.drawer.org', match: '^\\s*:(?:PROPERTIES|LOGBOOK|END):\\s*$' },
    { name: 'variable.other.property.org', match: '^\\s*:[A-Za-z][A-Za-z0-9_-]*:(?=\\s)' },
    { name: 'constant.language.priority.org', match: '\\[#[A-Z]\\]' },
    { name: 'constant.other.timestamp.org', match: '(?:<|\\[)\\d{4}-\\d{2}-\\d{2}[^>\\]]*(?:>|\\])' },
    { name: 'string.other.link.org', match: '\\[\\[[^\\]]+\\](?:\\[[^\\]]*\\])?\\]' },
    { name: 'entity.name.tag.org', match: ':[A-Za-z0-9_@#%]+(?::[A-Za-z0-9_@#%]+)*:\\s*$' },
    { name: 'markup.list.org', match: '^\\s*(?:[-+] |\\d+[.)] )' }
  ]
};

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
  if (raw === 'org' || raw === 'org2') return 'org';
  return raw;
}

function activeTheme() {
  return prefersDark() ? THEME_DARK : THEME_LIGHT;
}

async function run() {
  const highlighter = await createHighlighter({
    themes: [THEME_LIGHT, THEME_DARK],
    langs: ['text', 'bash', 'json', 'javascript', 'typescript', 'tsx', 'yaml', 'html', 'css', 'markdown', 'sql', 'haskell', 'java', 'c', 'cpp', 'csharp', 'ruby', 'php', 'kotlin', 'swift', 'scala', 'lua', 'go', 'rust', 'python', ORG_LANGUAGE]
  });

  const theme = activeTheme();

  // Block code: source blocks and standalone renderer directives.
  for (const pre of document.querySelectorAll('pre.org2-src, pre.org2-directive')) {
    const codeEl = pre.querySelector('code');
    const code = (codeEl || pre).textContent || '';
    const lang = pre.classList.contains('org2-directive') ? 'org' : languageFromCodeEl(codeEl || pre);
    const html = highlighter.codeToHtml(code, { lang, theme });
    const wrapper = document.createElement('div');
    wrapper.innerHTML = html;
    const shikiPre = wrapper.querySelector('pre.shiki');
    if (!shikiPre) continue;
    shikiPre.classList.add('celorga-shiki-block');
    pre.replaceWith(shikiPre);
  }

  // Re-render on theme changes.
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  media.addEventListener?.('change', () => window.location.reload());
}

run().catch((err) => {
  console.error('shiki highlight failed', err);
});
