import { homedir } from "node:os";
import { join } from "node:path";

// Share architecture-specific release compilation between coordinated releases
// and standalone DMG packaging. Bundle staging and signing stay disposable.
export function releaseBuildCacheRoot(environment = process.env) {
  return environment.OPENORG_RELEASE_BUILD_CACHE?.trim()
    || join(homedir(), "Library", "Caches", "OpenOrg", "release-build");
}
