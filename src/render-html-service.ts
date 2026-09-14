#!/usr/bin/env node

import readline from "node:readline";
import { renderAppHTML, type AppHTMLRenderOptions } from "./appHtmlRenderer.js";

interface RenderRequest extends AppHTMLRenderOptions {
  id: string;
  text: string;
}

interface RenderResponse {
  id: string;
  html?: string;
  error?: string;
}

function respond(response: RenderResponse): void {
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
  terminal: false,
});

for await (const line of input) {
  if (!line) continue;
  let request: RenderRequest;
  try {
    request = JSON.parse(line) as RenderRequest;
  } catch (error) {
    respond({ id: "", error: error instanceof Error ? error.message : String(error) });
    continue;
  }
  try {
    const { id, text, ...options } = request;
    respond({ id, html: renderAppHTML(text, options) });
  } catch (error) {
    respond({ id: request.id, error: error instanceof Error ? error.message : String(error) });
  }
}
