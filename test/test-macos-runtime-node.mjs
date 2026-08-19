import assert from "node:assert/strict";
import {
  detectNodeArchitecture,
  duckDBBindingPackageForNodeArchitecture,
  duckDBBindingPackagesForRuntime,
  macOSDuckDBBindingPackages,
} from "../tools/macos-runtime-node.mjs";

assert.equal(detectNodeArchitecture(process.execPath), process.arch);
assert.equal(
  duckDBBindingPackageForNodeArchitecture("arm64"),
  "@duckdb/node-bindings-darwin-arm64"
);
assert.equal(
  duckDBBindingPackageForNodeArchitecture("x64"),
  "@duckdb/node-bindings-darwin-x64"
);
assert.deepEqual(
  duckDBBindingPackagesForRuntime({ bundledNodePath: "", nodeArchitecture: "x64" }),
  macOSDuckDBBindingPackages
);
assert.deepEqual(
  duckDBBindingPackagesForRuntime({ bundledNodePath: "/tmp/node", nodeArchitecture: "x64" }),
  ["@duckdb/node-bindings-darwin-x64"]
);
assert.deepEqual(
  duckDBBindingPackagesForRuntime({ bundledNodePath: "/tmp/node", nodeArchitecture: "arm64" }),
  ["@duckdb/node-bindings-darwin-arm64"]
);
assert.throws(
  () => duckDBBindingPackageForNodeArchitecture("ppc64"),
  /Unsupported macOS Node\.js architecture/
);

console.log("macOS runtime Node architecture tests: ok");
