import assert from "node:assert/strict";
import { parseOrgToCanonicalAst } from "./dist/parser.js";
import { printCanonicalAstToOrg } from "./dist/printer.js";

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
