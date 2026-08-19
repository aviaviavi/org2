import { spawnSync } from "node:child_process";

export const macOSDuckDBBindingPackages = [
  "@duckdb/node-bindings-darwin-arm64",
  "@duckdb/node-bindings-darwin-x64",
];

export function detectNodeArchitecture(nodePath) {
  const result = spawnSync(nodePath, ["-p", "process.arch"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      detail
        ? `Could not inspect Node.js runtime ${nodePath}:\n${detail}`
        : `Could not inspect Node.js runtime ${nodePath}`
    );
  }
  const architecture = result.stdout.trim();
  if (architecture !== "arm64" && architecture !== "x64") {
    throw new Error(`Unsupported macOS Node.js architecture "${architecture}" from ${nodePath}`);
  }
  return architecture;
}

export function duckDBBindingPackageForNodeArchitecture(architecture) {
  if (architecture === "arm64") return "@duckdb/node-bindings-darwin-arm64";
  if (architecture === "x64") return "@duckdb/node-bindings-darwin-x64";
  throw new Error(`Unsupported macOS Node.js architecture "${architecture}"`);
}

export function duckDBBindingPackagesForRuntime({ bundledNodePath, nodeArchitecture }) {
  if (!bundledNodePath) {
    // Development builds may fall back to a different system Node after the app
    // is installed. Include both native packages so that changing PATH or adding
    // Homebrew later cannot invalidate the app bundle.
    return [...macOSDuckDBBindingPackages];
  }
  return [duckDBBindingPackageForNodeArchitecture(nodeArchitecture)];
}
