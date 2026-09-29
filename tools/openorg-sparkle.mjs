export const OPENORG_SPARKLE_ACCOUNT = "org.org2.workspace";
export const OPENORG_SPARKLE_PUBLIC_KEY = "pvU82IdCXtj+cQ9DUZJtUHKM1HgX12P0y5oBfsk7yGA=";
export const OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS = 2 * 60 * 60;
export const OPENORG_SPARKLE_DOWNLOAD_BASE = "https://org2.gateway.scarf.sh/downloads";

export const OPENORG_SPARKLE_TARGETS = Object.freeze([
  { architecture: "arm64", artifact: "OpenOrg.dmg", output: "appcast-arm64.xml" },
  { architecture: "x86_64", artifact: "OpenOrg-Intel.dmg", output: "appcast-intel.xml" },
]);

export function openOrgSparkleFeedURL(architecture) {
  const target = OPENORG_SPARKLE_TARGETS.find((candidate) => candidate.architecture === architecture);
  if (!target) throw new Error(`Unsupported OpenOrg update architecture: ${architecture}`);
  return `https://openorg.so/assets/${target.output}`;
}

export function openOrgSparkleDownloadPrefix(version) {
  return `${OPENORG_SPARKLE_DOWNLOAD_BASE}/${encodeURIComponent(version)}/`;
}

export function openOrgSparkleDownloadURL(version, artifact) {
  return `${openOrgSparkleDownloadPrefix(version)}${encodeURIComponent(artifact)}`;
}
