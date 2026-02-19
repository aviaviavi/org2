import type { Org2PublishProjectConfig } from "./config.js";

const PRISM_LIGHT_THEME_LINK =
  '<link id="org2-prism-light" rel="stylesheet" href="https://cdn.jsdelivr.net/npm/prismjs/themes/prism.min.css" media="all" />';
const PRISM_DARK_THEME_LINK =
  '<link id="org2-prism-dark" rel="stylesheet" href="https://cdn.jsdelivr.net/npm/prismjs/themes/prism-okaidia.min.css" media="not all" />';
const PRISM_LIGHT_TEXT_FIX_STYLE =
  '<style>:root[data-theme="light"] code[class*="language-"],:root[data-theme="light"] pre[class*="language-"]{color:#1f2937!important;} @media (prefers-color-scheme: light){:root:not([data-theme]) code[class*="language-"],:root:not([data-theme]) pre[class*="language-"]{color:#1f2937!important;}}</style>';
const PRISM_THEME_AUTODETECT_SCRIPT =
  '<script>(function(){var root=document.documentElement;function hasDarkToken(s){return /(^|\\s)(dark|theme-dark|dark-mode)(\\s|$)/.test((s||"").toLowerCase());}function luminanceFromRgb(rgb){var m=(rgb||"").match(/\d+(?:\.\d+)?/g);if(!m||m.length<3)return null;var r=Number(m[0]),g=Number(m[1]),b=Number(m[2]);if(!Number.isFinite(r)||!Number.isFinite(g)||!Number.isFinite(b))return null;return (0.2126*r+0.7152*g+0.0722*b)/255;}function inferDarkFromStyles(){try{var el=document.body||root;var bg=getComputedStyle(el).backgroundColor;var l=luminanceFromRgb(bg);if(l===null)return null;return l<0.5;}catch(_){return null;}}function pick(){var explicit=(root.getAttribute("data-theme")||"").toLowerCase();var rootDark=hasDarkToken(root.className||"");var bodyDark=hasDarkToken((document.body&&document.body.className)||"");var inferred=inferDarkFromStyles();var dark=(explicit==="dark")||(explicit!=="light"&&(rootDark||bodyDark||(inferred===null?window.matchMedia("(prefers-color-scheme: dark)").matches:inferred)));var l=document.getElementById("org2-prism-light");var d=document.getElementById("org2-prism-dark");if(l&&d){l.media=dark?"not all":"all";d.media=dark?"all":"not all";}}pick();try{window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change",pick);}catch(_){};if(typeof MutationObserver!=="undefined"){var mo=new MutationObserver(pick);mo.observe(root,{attributes:true,attributeFilter:["class","data-theme","style"]});if(document.body){mo.observe(document.body,{attributes:true,attributeFilter:["class","data-theme","style"]});}else{document.addEventListener("DOMContentLoaded",function(){if(document.body)mo.observe(document.body,{attributes:true,attributeFilter:["class","data-theme","style"]});pick();},{once:true});}}window.addEventListener("load",pick);})();</script>';

const PRISM_CORE_SCRIPT = '<script defer src="https://cdn.jsdelivr.net/npm/prismjs/prism.min.js"></script>';
const PRISM_LANGUAGE_SCRIPTS = [
  '<script defer src="https://cdn.jsdelivr.net/npm/prismjs/components/prism-haskell.min.js"></script>',
  '<script defer src="https://cdn.jsdelivr.net/npm/prismjs/components/prism-bash.min.js"></script>',
  '<script defer src="https://cdn.jsdelivr.net/npm/prismjs/components/prism-json.min.js"></script>',
  '<script defer src="https://cdn.jsdelivr.net/npm/prismjs/components/prism-typescript.min.js"></script>',
  '<script defer src="https://cdn.jsdelivr.net/npm/prismjs/components/prism-jsx.min.js"></script>',
];

export const DEFAULT_SYNTAX_HEAD_INCLUDES = [
  PRISM_LIGHT_THEME_LINK,
  PRISM_DARK_THEME_LINK,
  PRISM_LIGHT_TEXT_FIX_STYLE,
  PRISM_THEME_AUTODETECT_SCRIPT,
  PRISM_CORE_SCRIPT,
  ...PRISM_LANGUAGE_SCRIPTS,
];

export const COMPAT_CONTENT_OPEN = '<div id="content" class="content">\n';
export const COMPAT_CONTENT_CLOSE = "</div>\n";
export const COMPAT_CONTENT_STYLE_SECTION =
  "<style>\n#content { max-width: 60em; margin: auto; line-height: 1.35; }\n#content li > p { margin: 0; }\n#content li + li { margin-top: 0.2rem; }\n</style>\n";

export function resolvePublishHeadIncludes(project: Org2PublishProjectConfig): string[] {
  if (Array.isArray(project.headIncludes) && project.headIncludes.length > 0) {
    return project.headIncludes;
  }

  if (project.syntaxHighlighting === false) {
    return [];
  }

  return DEFAULT_SYNTAX_HEAD_INCLUDES;
}
