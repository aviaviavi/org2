import { extractPage } from "./extract.js";
const field = id => document.getElementById(id);
let page;
function refreshPreview() {
  const mode = field("mode").value;
  field("content").value = page?.[mode] || "";
  const content = field("content").value;
  field("save").disabled = !content || new TextEncoder().encode(content).length > 2_000_000;
  field("status").textContent = !content ? "Select text on the page, then reopen the clipper." : field("save").disabled ? "This clip exceeds 2 MB. Select a shorter passage." : mode === "article" && !page.articleElement ? "No article element found. Preview includes the page’s main text." : `${content.length.toLocaleString()} characters · ${new Date(page.capturedAt).toLocaleString()}`;
}
try {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !/^https?:/.test(tab.url || "")) throw new Error("Open an HTTP or HTTPS article to capture it.");
  const [result] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: extractPage });
  page = result.result;
  for (const name of ["title", "author", "url"]) field(name).value = page[name];
  if (page.selection) field("mode").value = "selection";
  refreshPreview();
} catch (error) { field("status").textContent = `Cannot capture this page: ${error.message}`; }
field("mode").addEventListener("change", refreshPreview);
field("clip-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (!page || field("save").disabled) return;
  const clip = { schema: "org2:browser-clip:v1", url: page.url, title: field("title").value.trim(), author: field("author").value.trim(), capturedAt: page.capturedAt, mode: field("mode").value, template: field("template").value, content: field("content").value };
  const blobURL = URL.createObjectURL(new Blob([JSON.stringify(clip, null, 2) + "\n"], { type: "application/json" }));
  try {
    await chrome.downloads.download({ url: blobURL, filename: `${clip.title.replace(/[^a-z0-9-]+/gi, "-").slice(0, 80) || "article"}.org2clip`, saveAs: true });
    field("status").textContent = "Clip saved. In OpenOrg’s Capture window, choose Import Browser Clip.";
  } catch (error) { field("status").textContent = `Save failed: ${error.message}`; }
  // Keep the blob available until the popup closes; the download may start later.
});
