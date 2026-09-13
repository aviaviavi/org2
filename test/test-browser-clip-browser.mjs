// Optional real Chromium extension E2E. Set ORG2_PLAYWRIGHT_MODULE to an installed
// Playwright index.mjs, or install Playwright separately for this test.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
const { chromium } = await import(process.env.ORG2_PLAYWRIGHT_MODULE || "playwright");
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "org2-clip-browser-"));
const downloads = path.join(profile, "downloads");
fs.mkdirSync(downloads);
const context = await chromium.launchPersistentContext(profile, {
  channel: "chromium", headless: true, args: ["--enable-unsafe-extension-debugging"],
  ignoreDefaultArgs: ["--disable-extensions"],
});
try {
  const browser = await context.browser().newBrowserCDPSession();
  await browser.send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: downloads });
  const extension = await browser.send("Extensions.loadUnpacked", { path: path.resolve("integrations/browser-clip") });
  const page = context.pages()[0];
  await page.route("http://clip.test/**", route => route.fulfill({ contentType: "text/html", body: '<title>Field notes</title><meta name="author" content="Ada Author"><style>.css-hidden{display:none}.css-invisible{visibility:hidden}.transparent{opacity:0}.unrendered{content-visibility:hidden}</style><nav>Outside navigation</nav><article class="css-hidden">PRIVATE_HIDDEN_ARTICLE</article><article><h1>Field notes</h1><p id="passage">A selected passage with meaningful context.</p><p>Second paragraph.</p><div class="css-hidden"><p>PRIVATE_CSS_HIDDEN_TEXT</p></div><span class="css-invisible">PRIVATE_INVISIBLE_TEXT</span><p class="transparent">PRIVATE_TRANSPARENT_TEXT</p><div class="unrendered">PRIVATE_UNRENDERED_TEXT</div><span hidden>PRIVATE_HIDDEN_ATTRIBUTE</span><span aria-hidden="true">PRIVATE_ARIA_HIDDEN</span><script type="text/plain">private script text</script><footer>Footer noise</footer></article>' }));
  await page.goto("http://clip.test/article");
  await page.evaluate(() => { const range = document.createRange(); range.selectNodeContents(document.querySelector("#passage")); window.getSelection().removeAllRanges(); window.getSelection().addRange(range); });
  const targets = (await browser.send("Target.getTargets", { filter: [{ type: "tab", exclude: false }] })).targetInfos;
  await browser.send("Extensions.triggerAction", { id: extension.id, targetId: targets.find(target => target.url === page.url()).targetId });
  let popup;
  for (let i = 0; i < 100; i++) {
    popup = (await browser.send("Target.getTargets")).targetInfos.find(target => target.url === `chrome-extension://${extension.id}/popup.html`);
    if (popup) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  assert.ok(popup, "Extension action must open its popup");
  const { sessionId } = await browser.send("Target.attachToTarget", { targetId: popup.targetId, flatten: false });
  let nextID = 0;
  const pending = new Map();
  browser.on("Target.receivedMessageFromTarget", event => {
    if (event.sessionId !== sessionId) return;
    const response = JSON.parse(event.message);
    if (!response.id) return;
    const handler = pending.get(response.id); pending.delete(response.id);
    if (response.error) handler?.reject(new Error(response.error.message)); else handler?.resolve(response.result);
  });
  function send(method, params = {}) {
    const id = ++nextID;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      browser.send("Target.sendMessageToTarget", { sessionId, message: JSON.stringify({ id, method, params }) }).catch(reject);
    });
  }
  async function evaluate(expression) {
    const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  for (let i = 0; i < 100; i++) {
    if (await evaluate('!!document.getElementById("save") && !document.getElementById("save").disabled')) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  assert.equal(await evaluate('document.getElementById("mode").value'), "selection");
  assert.equal(await evaluate('document.getElementById("content").value'), "A selected passage with meaningful context.");
  assert.equal(await evaluate('document.getElementById("author").value'), "Ada Author");
  await evaluate('document.getElementById("mode").value="article"; document.getElementById("mode").dispatchEvent(new Event("change"));');
  const article = await evaluate('document.getElementById("content").value');
  assert.match(article, /Second paragraph/);
  assert.doesNotMatch(article, /navigation|script text|Footer noise|PRIVATE_/);
  assert.match(article, /A selected passage with meaningful context/);
  await evaluate('document.getElementById("template").value="task"; document.getElementById("clip-form").requestSubmit();');
  let saved;
  for (let i = 0; i < 100; i++) {
    saved = fs.readdirSync(downloads).find(file => !file.endsWith(".crdownload"));
    if (saved) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.ok(saved, `Clip download should complete (${JSON.stringify(await evaluate("chrome.downloads.search({})"))}): ${await evaluate('document.getElementById("status").textContent')}`);
  const clipFile = path.join(downloads, saved);
  const clip = JSON.parse(fs.readFileSync(clipFile, "utf8"));
  assert.equal(clip.template, "task"); assert.equal(clip.url, page.url()); assert.equal(clip.author, "Ada Author");
  const root = path.join(profile, "corpus"); fs.mkdirSync(root);
  const args = ["dist/cli.js", "browser-clip", "import", "--file", clipFile, "--dir", root, "--json"];
  const preview = JSON.parse(execFileSync(process.execPath, args, { encoding: "utf8" }));
  const applied = JSON.parse(execFileSync(process.execPath, [...args, "--if-revision", preview.revision, "--if-clip-revision", preview.clipRevision, "--apply"], { encoding: "utf8" }));
  assert.match(fs.readFileSync(applied.file, "utf8"), /^\* TODO Field notes/);
  assert.equal(JSON.parse(fs.readFileSync(applied.rawFile, "utf8")).content, clip.content);
  const metrics = await send("Page.getLayoutMetrics");
  const screenshot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true, clip: { x: 0, y: 0, width: 370, height: Math.min(600, metrics.cssContentSize.height), scale: 1 } });
  const screenshotFile = process.env.ORG2_CLIP_SCREENSHOT || path.join(os.tmpdir(), "openorg-browser-clip.png");
  fs.writeFileSync(screenshotFile, Buffer.from(screenshot.data, "base64"));
  console.log(`Real unpacked extension: activeTab capture, selection/article preview, author extraction, local download and CLI import passed. Screenshot: ${screenshotFile}`);
} finally { await context.close(); fs.rmSync(profile, { recursive: true, force: true }); }
