import { createHighlighter } from 'https://esm.sh/shiki@1.29.1';

const THEME_LIGHT = 'github-light';
const THEME_DARK = 'github-dark';

const ORG2_LANGUAGE = {
  name: 'org2',
  scopeName: 'source.org2',
  patterns: [
    { name: 'comment.line.number-sign.org2', match: '^\\s*#(?!\\+).*?$' },
    { name: 'keyword.control.block.org2', match: '^\\s*```.*$' },
    { name: 'keyword.control.block.org2', match: '^\\s*#\\+(?:begin|end)_[A-Za-z0-9_-]+\\b.*$' },
    { name: 'markup.heading.org2', match: '^\\*+(?=\\s)' },
    { name: 'keyword.control.todo.org2', match: '\\b(?:TODO|IN_PROGRESS|DONE|CANCELLED|CANCELED|WAITING|BLOCKED|NEXT)\\b' },
    { name: 'keyword.other.planning.org2', match: '^\\s*(?:SCHEDULED|DEADLINE|CLOSED):' },
    { name: 'keyword.other.directive.org2', match: '^\\s*#\\+[A-Za-z][A-Za-z0-9_-]*(?=:)' },
    { name: 'entity.name.section.drawer.org2', match: '^\\s*:(?:PROPERTIES|LOGBOOK|END):\\s*$' },
    { name: 'variable.other.property.org2', match: '^\\s*:[A-Za-z][A-Za-z0-9_-]*:(?=\\s)' },
    { name: 'constant.language.priority.org2', match: '\\[#[A-Z]\\]' },
    { name: 'constant.other.timestamp.org2', match: '(?:<|\\[)\\d{4}-\\d{2}-\\d{2}[^>\\]]*(?:>|\\])' },
    { name: 'string.other.link.org2', match: '\\[\\[[^\\]]+\\](?:\\[[^\\]]*\\])?\\]' },
    { name: 'entity.name.tag.org2', match: ':[A-Za-z0-9_@#%]+(?::[A-Za-z0-9_@#%]+)*:\\s*$' },
    { name: 'markup.list.org2', match: '^\\s*(?:[-+] |\\d+[.)] )' }
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
  if (raw === 'org' || raw === 'org2') return 'org2';
  return raw;
}

function activeTheme() {
  return prefersDark() ? THEME_DARK : THEME_LIGHT;
}

async function run() {
  const highlighter = await createHighlighter({
    themes: [THEME_LIGHT, THEME_DARK],
    langs: ['text', 'bash', 'json', 'javascript', 'typescript', 'tsx', 'yaml', 'html', 'css', 'markdown', 'sql', 'haskell', 'java', 'c', 'cpp', 'csharp', 'ruby', 'php', 'kotlin', 'swift', 'scala', 'lua', 'go', 'rust', 'python', ORG2_LANGUAGE]
  });

  const theme = activeTheme();

  // Block code: source blocks and standalone renderer directives.
  for (const pre of document.querySelectorAll('pre.org2-src, pre.org2-directive')) {
    const codeEl = pre.querySelector('code');
    const code = (codeEl || pre).textContent || '';
    const lang = pre.classList.contains('org2-directive') ? 'org2' : languageFromCodeEl(codeEl || pre);
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
