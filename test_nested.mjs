import { parseOrgToCanonicalAst } from "./dist/parser.js";

const input = `- First item
  - Nested item 1
  - Nested item 2
- Second item`;

const ast = parseOrgToCanonicalAst(input);
console.log(JSON.stringify(ast, null, 2));
