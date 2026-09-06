import { statSync } from "node:fs";
import { resolve } from "node:path";

/** Resolve references only; private-key contents never enter plans or logs. */
export function notarizationAuthentication(profile, environment = process.env) {
  const keyPath = environment.OPENORG_NOTARY_PRIVATE_KEY_PATH?.trim();
  const keyID = environment.OPENORG_NOTARY_KEY_ID?.trim();
  const issuer = environment.OPENORG_NOTARY_ISSUER_ID?.trim();
  if (keyPath || keyID || issuer) {
    if (!keyPath || !keyID) {
      throw new Error("API-key notarization requires OPENORG_NOTARY_PRIVATE_KEY_PATH and OPENORG_NOTARY_KEY_ID");
    }
    const absolutePath = resolve(keyPath);
    try {
      if (!statSync(absolutePath).isFile()) throw new Error();
    } catch {
      throw new Error("OPENORG_NOTARY_PRIVATE_KEY_PATH must reference an existing protected key file");
    }
    return {
      label: "existing Apple API key configured",
      args: ["--key", absolutePath, "--key-id", keyID, ...(issuer ? ["--issuer", issuer] : [])],
    };
  }
  if (profile?.trim()) {
    return { label: "notarytool Keychain profile configured", args: ["--keychain-profile", profile.trim()] };
  }
  return null;
}
