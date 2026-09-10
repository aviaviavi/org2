import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { execFileSync } from "node:child_process";

execFileSync(process.execPath, ["tools/build-mobile-document.mjs", "--check"], { stdio: "inherit" });
const context = vm.createContext({});
vm.runInContext(readFileSync("apps/ios/Org2Mobile/Org2Mobile/Org2MobileDocument.js", "utf8"), context);
const runtime = context.Org2MobileDocument;
const source = `#+TITLE: Recipes
* Breakfast
We discussed pour over yesterday.
* Pour over
:PROPERTIES:
:ID: coffee-entry
:END:
- *Coffee:* 14 g
- *Water:* 225 g
** Grind
Fine — setting 15.
#+begin_src sh
* Not a heading
#+end_src
* Tea
Steep 3 minutes.
`;
const index = runtime.indexDocument(source, "notes/recipes.org2");
assert.equal(index.length, 5);
const coffee = index.find(e => e.title === "Pour over");
assert.equal(coffee.line, 4);
assert.equal(coffee.nodeID, "coffee-entry");
assert.equal(coffee.parent, "Recipes");
assert.match(coffee.body, /Coffee: 14 g/);
assert.equal(index.find(e => e.title === "Grind").parent, "Recipes › Pour over");
const html = runtime.renderDocument(source, coffee.path, coffee.line, coffee.nodeID).html;
assert.match(html, /225 g/);
assert.match(html, /setting 15/);
assert.doesNotMatch(html, /Steep 3 minutes|discussed pour over yesterday/);
assert.match(runtime.renderDocument(source, coffee.path).html, /Steep 3 minutes/);
assert.match(runtime.renderDocument("\n" + source, coffee.path, coffee.line, coffee.nodeID).html, /225 g/);
assert.throws(() => runtime.renderDocument(source, coffee.path, 2, "", [], "Pour over"), /entry changed/);
const unsafe = runtime.renderDocument('#+HTML_HEAD: <script>unsafe()</script>\n* Hello\n#+begin_export html\n<script>unsafe()</script>\n#+end_export', 'test.org').html;
assert.match(unsafe, /script-src 'none'/);
assert.doesNotMatch(unsafe, /<script>unsafe\(\)<\/script>/);
assert.equal(runtime.indexDocument('#+TODO: OPEN | FINISHED\n* OPEN Coffee', 'test.org')[1].title, 'Coffee');
assert.equal(runtime.indexDocument('* READY Coffee', 'test.org', ['READY | FINISHED'])[1].title, 'Coffee');
assert.equal(runtime.indexDocument('* Coffee\n\tIndented text', 'test.org')[1].title, 'Coffee');
console.log('Mobile shared parser/renderer: entry scopes, source blocks, workflow defaults, IDs, stale results, safe HTML passed');

const table = runtime.indexDocument('* Coffee\n| Ingredient | Weight |\n|------------+--------|\n| *Water* | 225 g |', 'table.org');
assert.match(table[1].body, /Water 225 g/);
assert.doesNotMatch(table[1].body, /\*Water\*/);
