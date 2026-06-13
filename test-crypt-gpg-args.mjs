#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-crypt-gpg-args-"));
const note = path.join(tmp, "secret.org2");
const argsLog = path.join(tmp, "gpg-args.json");
const fakeGpg = path.join(tmp, "fake-gpg.mjs");

fs.writeFileSync(
  note,
  `* Secret :crypt:
-----BEGIN PGP MESSAGE-----
abc
-----END PGP MESSAGE-----
`,
  "utf8",
);

fs.writeFileSync(
  fakeGpg,
  `#!/usr/bin/env node
import fs from "node:fs";
fs.writeFileSync(${JSON.stringify(argsLog)}, JSON.stringify(process.argv.slice(2)), "utf8");
if (process.argv.includes("--decrypt")) {
  process.stdout.write("plaintext\\n");
} else {
  process.stdout.write("-----BEGIN PGP MESSAGE-----\\nabc\\n-----END PGP MESSAGE-----\\n");
}
`,
  "utf8",
);
fs.chmodSync(fakeGpg, 0o755);

execFileSync("node", [
  "dist/cli.js",
  "crypt",
  "decrypt",
  "--file",
  note,
  "--line",
  "1",
  "--gpg-program",
  fakeGpg,
  "--gpg-timeout",
  "5",
  "--apply",
]);

let args = JSON.parse(fs.readFileSync(argsLog, "utf8"));
assert.equal(args.includes("--decrypt"), true);
assert.equal(args.includes("--batch"), false);
assert.equal(args.includes("--pinentry-mode"), false);

execFileSync("node", [
  "dist/cli.js",
  "crypt",
  "encrypt",
  "--file",
  note,
  "--line",
  "1",
  "--passphrase",
  "test",
  "--gpg-program",
  fakeGpg,
  "--gpg-timeout",
  "5",
]);

args = JSON.parse(fs.readFileSync(argsLog, "utf8"));
assert.equal(args.includes("--symmetric"), true);
assert.equal(args.includes("--batch"), true);
assert.equal(args.includes("--pinentry-mode"), true);
assert.equal(args.includes("loopback"), true);
