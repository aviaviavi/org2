/** Runs only in the explicitly selected browser tab; no background page access. */
export function extractPage() {
  const selection = window.getSelection()?.toString().trim() || "";
  const hiddenByStyle = element => {
    const style = getComputedStyle(element);
    return style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse"
      || style.contentVisibility === "hidden" || Number(style.opacity) === 0;
  };
  const visibleRoot = element => {
    for (let current = element; current; current = current.parentElement) {
      if (current.hasAttribute("hidden") || current.getAttribute("aria-hidden") === "true" || hiddenByStyle(current)) return false;
    }
    return true;
  };
  const article = [...document.querySelectorAll("article")].find(visibleRoot)
    || [...document.querySelectorAll("main")].find(visibleRoot) || document.body;
  const clone = article.cloneNode(true);
  // Read computed styles on the live tree: detached clones cannot resolve the
  // page's CSS. Matching node lists are captured before anything is removed.
  const originals = article.querySelectorAll("*");
  const copies = clone.querySelectorAll("*");
  originals.forEach((node, index) => {
    if (node.matches("script,style,nav,header,footer,aside,form,button,input,textarea,[hidden],[aria-hidden='true']") || hiddenByStyle(node)) copies[index].remove();
  });
  if (!visibleRoot(article)) clone.replaceChildren();
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
    articleElement: article.matches("article,main")
  };
}
