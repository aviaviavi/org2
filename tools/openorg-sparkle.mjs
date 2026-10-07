export const OPENORG_SPARKLE_ACCOUNT = "org.org2.workspace";
export const OPENORG_SPARKLE_PUBLIC_KEY = "pvU82IdCXtj+cQ9DUZJtUHKM1HgX12P0y5oBfsk7yGA=";
export const OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS = 2 * 60 * 60;
// New builds poll the Celorga site. Builds shipped before the rename poll the
// legacy host, which keeps serving identical appcasts (see
// tools/build-legacy-domain-site.mjs and docs/rename/celorga.org).
export const OPENORG_SPARKLE_FEED_BASE = "https://celorga.io/assets";
export const OPENORG_SPARKLE_LEGACY_FEED_BASES = Object.freeze(["https://openorg.so/assets"]);
export const OPENORG_SPARKLE_DOWNLOAD_BASE = "https://org2.gateway.scarf.sh/downloads";

export const OPENORG_SPARKLE_TARGETS = Object.freeze([
  { architecture: "arm64", artifact: "OpenOrg.dmg", output: "appcast-arm64.xml" },
  { architecture: "x86_64", artifact: "OpenOrg-Intel.dmg", output: "appcast-intel.xml" },
]);

export function openOrgSparkleFeedURL(architecture) {
  const target = OPENORG_SPARKLE_TARGETS.find((candidate) => candidate.architecture === architecture);
  if (!target) throw new Error(`Unsupported OpenOrg update architecture: ${architecture}`);
  return `${OPENORG_SPARKLE_FEED_BASE}/${target.output}`;
}

export function openOrgSparkleDownloadPrefix(version) {
  return `${OPENORG_SPARKLE_DOWNLOAD_BASE}/${encodeURIComponent(version)}/`;
}

export function openOrgSparkleDownloadURL(version, artifact) {
  return `${openOrgSparkleDownloadPrefix(version)}${encodeURIComponent(artifact)}`;
}
