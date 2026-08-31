import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { printCanonicalAstToOrg } from "../dist/printer.js";

const input = `* Blog post

Supply chain security is an urgent topic right now. From Anthropic's launch of
Claude Mythos to exploits at like Aqua Security, Checkmarx, and Bitwarden,
even Vercel, it's clear that AI is posing an existential threat.

Most large enterprises are still downloading OSS packages that are known to be
vulnerable. I don't just mean things like the compromised versions of Axios
from a month ago (https://github.com/axios/axios/issues/10064). I mean things
like the 2+ million downloads of vulnerable versions.

This is not terribly surprising when you consider a few factors:

- Most SLDC tools work by scanning code, not by monitoring real time dynamic
downloads and usage.
- Another point.
`;

const ast = parseOrgToCanonicalAst(input);
const formatted = printCanonicalAstToOrg(ast);

assert.equal(formatted, input);

const sugarInput = `* Canonical Org save

Use \`inline code\` and \`tilde~code\` in prose.

\`\`\`js
const value = \`body backticks stay literal\`;
\`\`\`

#+begin_org2
* Nested Org
#+end_org2
`;

const losslessSugar = printCanonicalAstToOrg(parseOrgToCanonicalAst(sugarInput));
assert.equal(losslessSugar, sugarInput, "default printing remains lossless");

const canonicalOrg = execFileSync(
  "node",
  ["dist/cli.js", "fmt", "--stdin", "--canonical-org"],
  { encoding: "utf8", input: sugarInput },
);
assert.equal(canonicalOrg, `* Canonical Org save

Use ~inline code~ and =tilde~code= in prose.

#+begin_src js
const value = \`body backticks stay literal\`;
#+end_src

#+begin_src org2
* Nested Org
#+end_src
`);

const ambiguousSugar = `\`both~=delimiters\`

\`\`\`org
#+end_src
\`\`\`
`;
const preservedAmbiguity = execFileSync(
  "node",
  ["dist/cli.js", "fmt", "--stdin", "--canonical-org"],
  { encoding: "utf8", input: ambiguousSugar },
);
assert.equal(preservedAmbiguity, ambiguousSugar, "canonicalization must not change ambiguous literal content");

const extensionFixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), "org2-canonical-extension-"));
try {
  const orgFile = path.join(extensionFixtureDir, "note.org");
  const org2File = path.join(extensionFixtureDir, "legacy.org2");
  fs.writeFileSync(orgFile, sugarInput, "utf8");
  fs.writeFileSync(org2File, sugarInput, "utf8");

  const automaticOrgPreview = execFileSync(
    "node",
    ["dist/cli.js", "fmt", "--file", orgFile],
    { encoding: "utf8" },
  );
  assert.equal(automaticOrgPreview, canonicalOrg, ".org file formatting selects canonical Org automatically");

  const losslessOrg2Preview = execFileSync(
    "node",
    ["dist/cli.js", "fmt", "--file", org2File],
    { encoding: "utf8" },
  );
  assert.equal(losslessOrg2Preview, sugarInput, ".org2 file formatting remains lossless by default");

  execFileSync(
    "node",
    ["dist/cli.js", "fmt", "--files", orgFile, org2File, "--apply"],
    { encoding: "utf8" },
  );
  assert.equal(fs.readFileSync(orgFile, "utf8"), canonicalOrg, "mixed apply canonicalizes .org files");
  assert.equal(fs.readFileSync(org2File, "utf8"), sugarInput, "mixed apply preserves .org2 spelling");
} finally {
  fs.rmSync(extensionFixtureDir, { recursive: true, force: true });
}
