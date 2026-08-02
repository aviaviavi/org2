import assert from "node:assert/strict";
import {
  managedBlockEnd,
  managedBlockStart,
  mergeReleaseDownloadBlock,
  planReleaseDownloadSync,
  releaseDownloadBlock,
  renderDownloadsPage,
  scarfDownloadUrl,
} from "../tools/sync-release-downloads.mjs";

const releases = [
  {
    id: 2,
    tag_name: "0.4.1",
    published_at: "2026-08-02T16:02:07Z",
    draft: false,
    prerelease: false,
    body: "## Highlights\n\nCurrent release.\n",
    assets: [
      { name: "aviaviavi-org2-0.4.1.tgz", size: 315913 },
      { name: "Org2Workspace.dmg", size: 8184365 },
      { name: "org2-vscode-0.4.1.vsix", size: 177345 },
    ],
  },
  {
    id: 1,
    tag_name: "0.3.0",
    published_at: "2026-06-29T11:41:08Z",
    draft: false,
    prerelease: false,
    body: "Initial release.\n",
    assets: [{ name: "Org2Workspace.dmg", size: 6989425 }],
  },
];

assert.equal(
  scarfDownloadUrl("0.4.1", "Org2Workspace.dmg"),
  "https://org2.gateway.scarf.sh/downloads/0.4.1/Org2Workspace.dmg",
);

const block = releaseDownloadBlock(releases[0]);
assert.ok(block.startsWith(managedBlockStart));
assert.ok(block.endsWith(managedBlockEnd));
assert.match(block, /Org2 Workspace for macOS/);
assert.match(block, /org2-vscode-0\.4\.1\.vsix/);
assert.match(block, /aviaviavi-org2-0\.4\.1\.tgz/);

const merged = mergeReleaseDownloadBlock(releases[0].body, releases[0]);
assert.match(merged, /^<!-- org2-scarf-downloads:start -->/);
assert.match(merged, /## Highlights\n\nCurrent release\./);
assert.equal(mergeReleaseDownloadBlock(merged, releases[0]), merged);

const page = renderDownloadsPage(releases);
assert.match(page, /\* Current release 0\.4\.1/);
assert.match(page, /\| 0\.4\.1 \| \[\[https:\/\/org2\.gateway\.scarf\.sh/);
assert.match(page, /\| 0\.3\.0 \|/);
assert.match(page, /No release files are hosted separately by Scarf\./);

const plan = planReleaseDownloadSync(releases, { currentPage: page });
assert.equal(plan.pageChanged, false);
assert.deepEqual(plan.releaseUpdates.map((item) => item.release.tag_name), ["0.4.1", "0.3.0"]);
assert.ok(plan.releaseUpdates.every((item) => item.changed));

const currentReleases = releases.map((release) => ({
  ...release,
  body: mergeReleaseDownloadBlock(release.body, release),
}));
const currentPlan = planReleaseDownloadSync(currentReleases, { currentPage: page });
assert.equal(currentPlan.pageChanged, false);
assert.ok(currentPlan.releaseUpdates.every((item) => !item.changed));

console.log("release download sync tests passed");
