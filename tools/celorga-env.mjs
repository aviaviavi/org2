// Accept CELORGA_WORKSPACE_* environment variables in the macOS build tools,
// which read the ORG2_WORKSPACE_* names. The Celorga name wins when both are
// set. The CELORGA_* copy is removed afterwards so explicit ORG2_* values passed
// to child processes are not overridden again.
for (const [name, value] of Object.entries(process.env)) {
  if (name.startsWith("CELORGA_WORKSPACE_") && value !== undefined) {
    process.env[`ORG2_${name.slice("CELORGA_".length)}`] = value;
    delete process.env[name];
  }
}
