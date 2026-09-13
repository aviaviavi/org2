/** Runs only in the explicitly selected browser tab; no background page access. */
export function extractPage() {
  const selection = window.getSelection()?.toString().trim() || "";
  const article = document.querySelector("article") || document.querySelector("main") || document.body;
  const clone = article.cloneNode(true);
  clone.querySelectorAll("script,style,nav,header,footer,aside,form,button,input,textarea,[hidden],[aria-hidden='true']").forEach(node => node.remove());
  // innerText on a detached tree loses layout. Insert explicit line breaks before
  // reading textContent, retaining paragraph boundaries without hidden scripts.
  clone.querySelectorAll("p,div,section,h1,h2,h3,h4,h5,h6,li,blockquote,pre,br").forEach(node => {
    node.prepend(document.createTextNode("\n"));
    node.append(document.createTextNode("\n"));
  });
  const content = (clone.textContent || "").replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n\n").trim();
  const meta = selector => document.querySelector(selector)?.getAttribute("content")?.trim();
  return {
    url: location.href,
    title: meta('meta[property="og:title"]') || document.title || location.hostname,
    author: meta('meta[name="author"]') || meta('meta[property="article:author"]') || document.querySelector('[rel="author"]')?.textContent?.trim() || "",
    capturedAt: new Date().toISOString(),
    article: content,
    selection,
    articleElement: !!document.querySelector("article,main")
  };
}
