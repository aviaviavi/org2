# OpenOrg Web Clipper

Load this directory as an unpacked extension in Chrome or Edge (`chrome://extensions` → Developer mode → Load unpacked). Pin the action, open an HTTP(S) article, optionally select text, then click **Clip to OpenOrg**. Review Article/Selection, title, author and Reading note/Read later task template. **Save clip** downloads an inspectable `.org2clip` JSON file.

In OpenOrg, open **Capture → Import Browser Clip**, choose that file, review it and click **Import**. The source URL, author and capture time are preserved in `views/browser-clips.org`, with immutable raw captures under `raw/browser/`. No local service, network upload or background page access is needed. The CLI alternative is `org2 browser-clip import --file article.org2clip --dir CORPUS --json`; apply with the returned `--if-revision` and `--if-clip-revision`.

Article extraction prefers `<article>`, then `<main>`, then page text; the preview reports fallback. It strips scripts, navigation and forms. Review extraction quality before saving. Selections capture exactly the selected text. Images and PDF/internal browser pages are not captured. Source text remains literal in Org; promotion into canonical notes is explicit.

The extension follows Chrome's [activeTab](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab) and [scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting) contracts. Its only permissions are activeTab, scripting and downloads.

Validation: run `npm run build && node test/test-browser-clip.mjs` for the shared contract. For the real unpacked-extension test, install Playwright separately with Chromium and run `ORG2_PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs node test/test-browser-clip-browser.mjs`. It uses a temporary browser profile and synthetic local article, verifies both capture modes, downloads a clip, imports it through the CLI, and removes the temporary corpus/profile.
