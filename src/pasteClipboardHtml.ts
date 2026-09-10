import { MAX_PASTE_CHARACTERS, type PasteBlock } from "./pasteAsOrg2.js";

/** Browser DOM boundary only. An inert template never enters the live document. */
export function extractPasteHtml(html: string, document: Document): { blocks: PasteBlock[]; links: string[]; warnings: string[]; fallbackText?: string } {
  if (html.length > MAX_PASTE_CHARACTERS) throw new Error("Clipboard HTML exceeds prototype limit");
  const template = document.createElement("template");
  const fragment = /<!--\s*StartFragment\s*-->([\s\S]*?)<!--\s*EndFragment\s*-->/i.exec(html);
  template.innerHTML = fragment?.[1] ?? html;
  const root = template.content;
  const warnings: string[] = [];
  // HTML source is retained by createPastePreview; executable/non-visible material
  // is not promoted into Org. No network, styles, images, or event handlers run.
  const ignored = root.querySelectorAll("script,style,noscript,iframe,object,embed,template,head");
  if (ignored.length) warnings.push("Non-content HTML elements omitted; original HTML remains available in the review packet.");
  ignored.forEach(node => node.remove());
  const links = [...root.querySelectorAll("a[href]")].map(node => node.getAttribute("href")!).filter(Boolean);
  const blocks: PasteBlock[] = [];
  const inline = (node: Node): string => {
    if (node.nodeType === 3) return node.textContent ?? "";
    const element = node as Element;
    if (element.tagName === "BR") return "\n";
    if (element.tagName === "IMG") return element.getAttribute("alt") ?? "";
    return [...node.childNodes].map(inline).join("");
  };
  const add = (text: string, label: PasteBlock["label"], extra: Partial<PasteBlock> = {}) => {
    if (text.trim()) blocks.push({ text, label, origin: "html", ...extra });
  };
  const layoutText = (node: Node): string => {
    const tag = (node as Element).tagName ?? "";
    if (node.nodeType === 3 || tag === "BR" || tag === "IMG") return inline(node);
    const separator = tag === "TR" ? "\t" : node.nodeType === 11 || /^(TABLE|THEAD|TBODY|TFOOT|DIV|SECTION|UL|OL)$/.test(tag) ? "\n" : "";
    return [...node.childNodes].map(layoutText).join(separator);
  };
  if (!root.querySelector("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,table")) {
    warnings.push("HTML has no supported semantic blocks; using original plain text, or literal HTML text if plain text is absent.");
    return { blocks, links, warnings, fallbackText: layoutText(root) };
  }
  const walk = (node: Node, depth: number): void => {
    if (depth > 64) throw new Error("Clipboard HTML nesting exceeds prototype limit; use plain text");
    if (node.nodeType === 3) { add(node.textContent ?? "", "paragraph"); return; }
    const element = node as Element;
    const tag = element.tagName ?? "";
    if (/^H[1-6]$/.test(tag)) { add(inline(node), "heading", { level: Number(tag.slice(1)) }); return; }
    if (tag === "PRE") { add(inline(node), "code"); return; }
    if (tag === "BLOCKQUOTE") {
      // Keep paragraph boundaries within a quotation. Nested complex content is
      // flattened literally rather than traversed twice or silently discarded.
      add([...node.childNodes].map(inline).join("\n"), "quote"); return;
    }
    if (tag === "TABLE") {
      const rows = [...element.querySelectorAll("tr")];
      const complex = !!element.querySelector("[rowspan],[colspan],table");
      if (complex) {
        warnings.push("Merged or nested table retained literally; column layout needs review.");
        add(layoutText(element), "code");
      } else {
        for (const caption of element.querySelectorAll("caption")) add(inline(caption), "paragraph");
        for (const row of rows) {
          const cells = [...row.children].filter(cell => /^(TD|TH)$/.test(cell.tagName)).map(inline);
          add(cells.join("\t"), "table", { cells });
        }
      }
      return;
    }
    if (tag === "LI") {
      const nested = [...node.childNodes].filter(child => /^(UL|OL)$/.test((child as Element).tagName ?? ""));
      const parent = element.parentElement;
      let prefix = "";
      if (parent?.tagName === "OL") {
        const items = [...parent.children].filter(child => child.tagName === "LI");
        const reversed = parent.hasAttribute("reversed");
        let value = Number.parseInt(parent.getAttribute("start") ?? "", 10);
        if (!Number.isFinite(value)) value = reversed ? items.length : 1;
        for (const item of items) {
          const explicit = Number.parseInt(item.getAttribute("value") ?? "", 10);
          if (Number.isFinite(explicit)) value = explicit;
          if (item === element) break;
          value += reversed ? -1 : 1;
        }
        prefix = `${value}. `;
      }
      let text = "";
      let first = true;
      const flushItem = () => {
        if (text.trim()) { add((first ? prefix : "") + text, first ? "list" : "paragraph"); first = false; }
        text = "";
      };
      for (const child of node.childNodes) {
        if (nested.includes(child)) { flushItem(); walk(child, depth + 1); }
        else text += inline(child);
      }
      flushItem();
      if (nested.length) warnings.push("Nested list hierarchy flattened; item order and text retained.");
      return;
    }
    if (tag === "P") { add(inline(node), "paragraph"); return; }
    // Coalesce inline siblings so markup such as Hello <b>world</b> stays together.
    let pending = "";
    const flush = () => { add(pending, "paragraph"); pending = ""; };
    for (const child of node.childNodes) {
      if (/^(H[1-6]|P|UL|OL|LI|BLOCKQUOTE|PRE|TABLE|DIV|SECTION|ARTICLE|HEADER|FOOTER|MAIN)$/.test((child as Element).tagName ?? "")) {
        flush(); walk(child, depth + 1);
      } else pending += inline(child);
    }
    flush();
  };
  walk(root, 0);
  return { blocks, links: [...new Set(links)], warnings: [...new Set(warnings)] };
}
