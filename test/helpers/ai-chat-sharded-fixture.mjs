import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

export function encodedJSON(value) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");
}

export function writeShardedV2Store(root, options) {
  const stateDirectory = path.join(root, ".org2");
  const legacyFile = path.join(stateDirectory, "openclaw-chat.json");
  const storeRoot = path.join(stateDirectory, "openclaw-chat.store");
  const threadsDirectory = path.join(storeRoot, "threads");
  const manifestsDirectory = path.join(storeRoot, "manifests");
  fs.mkdirSync(threadsDirectory, { recursive: true });
  fs.mkdirSync(manifestsDirectory, { recursive: true });

  const entries = options.threads.map(({ metadata, messages = [] }) => {
    const shard = {
      schema: "org2:ai-chat-thread:v1",
      version: 1,
      messages: messages.map((stored) => (
        stored.message
          ? stored
          : { message: stored, attachments: stored.attachments ?? [] }
      )),
    };
    const shardData = encodedJSON(shard);
    const shardDigest = sha256(shardData);
    const shardName = `threads/${metadata.id.toLowerCase()}-${shardDigest.slice(0, 20)}.json`;
    fs.writeFileSync(path.join(storeRoot, shardName), shardData);
    return {
      metadata: {
        ...metadata,
        messages: [],
        storedMessageCount: metadata.storedMessageCount ?? messages.length,
      },
      shard: shardName,
      shardDigest,
      blobs: [],
    };
  });
  const manifest = {
    schema: "org2:ai-chat-transcript-manifest:v2",
    version: 2,
    generation: options.generation ?? 1,
    commitID: options.commitID ?? crypto.randomUUID().toLowerCase(),
    parentCommitID: options.parentCommitID ?? null,
    threads: entries,
    selectedThreadID: options.selectedThreadID ?? null,
    settlementSettings: {
      autoSettleAfterSeconds: options.autoSettleAfterSeconds ?? null,
    },
  };
  const manifestData = encodedJSON(manifest);
  const manifestName = `${manifest.commitID}.json`;
  const manifestFile = path.join(manifestsDirectory, manifestName);
  fs.writeFileSync(manifestFile, manifestData);
  fs.writeFileSync(path.join(storeRoot, "manifest.json"), manifestData);
  const marker = {
    schema: "org2:ai-chat-transcript-store-marker:v1",
    version: 1,
    currentManifest: manifestName,
    currentDigest: sha256(manifestData),
    previousManifest: options.previousManifest ?? null,
    previousDigest: options.previousDigest ?? null,
  };
  const markerFile = path.join(storeRoot, "migration-marker.json");
  fs.writeFileSync(markerFile, encodedJSON(marker));
  if (options.legacyPayload !== undefined) {
    fs.mkdirSync(stateDirectory, { recursive: true });
    fs.writeFileSync(legacyFile, encodedJSON(options.legacyPayload));
  }
  return {
    entries,
    legacyFile,
    manifest,
    manifestData,
    manifestFile,
    marker,
    markerFile,
    storeRoot,
  };
}
