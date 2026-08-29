import fs from "node:fs";
import path from "node:path";
import { findConfigFile, loadConfig } from "./config.js";
import {
  GOOGLE_DOCS_MIME_TYPE,
  GOOGLE_DRIVE_MULTIPART_MAX_BYTES,
  GOOGLE_DRIVE_FILE_SCOPE,
  prepareGoogleDocsUpload,
  preparePublishedDocument,
  publishToGoogleDocs,
  writeWebPublicationBundle,
  type PreparedPublishedDocument,
} from "./publishDocument.js";

type PublishDestination = "web" | "google-docs";
type OutputFormat = "text" | "json";

type PublishDocumentArguments = {
  file: string;
  line?: number;
  title?: string;
  destination: PublishDestination;
  outDir?: string;
  documentId?: string;
  folderId?: string;
  expectedVersion?: string;
  accessTokenEnv: string;
  configPath?: string;
  allowIndexing: boolean;
  replaceExisting: boolean;
  apply: boolean;
  format: OutputFormat;
};

function usage(exitCode: number): never {
  console.error(`Usage:
  org2 publish document --file FILE --to web --out-dir DIR [--line N] [--allow-indexing] [--replace-existing] [--apply] [--format text|json]
  org2 publish document --file FILE --to google-docs [--folder-id ID] [--line N] [--apply] [--format text|json]
  org2 publish document --file FILE --to google-docs --document-id ID --if-version VERSION --replace-existing [--apply] [--format text|json]

Publishes a disclosure-safe document or subtree. Commands preview by default.
Google credentials are read from ORG2_GOOGLE_DRIVE_ACCESS_TOKEN (or the
environment variable named by --access-token-env), never from an argument.`);
  process.exit(exitCode);
}

function requiredValue(args: string[], index: number, option: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${option} requires a value`);
  return value;
}

function parseArguments(args: string[]): PublishDocumentArguments {
  let file = "";
  let line: number | undefined;
  let title: string | undefined;
  let destination: PublishDestination = "web";
  let outDir: string | undefined;
  let documentId: string | undefined;
  let folderId: string | undefined;
  let expectedVersion: string | undefined;
  let accessTokenEnv = "ORG2_GOOGLE_DRIVE_ACCESS_TOKEN";
  let configPath: string | undefined;
  let allowIndexing = false;
  let replaceExisting = false;
  let apply = false;
  let format: OutputFormat = "text";

  for (let index = 2; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--file") file = requiredValue(args, index++, argument);
    else if (argument === "--line") line = Number(requiredValue(args, index++, argument));
    else if (argument === "--title") title = requiredValue(args, index++, argument);
    else if (argument === "--to") {
      const value = requiredValue(args, index++, argument);
      if (value !== "web" && value !== "google-docs") throw new Error("--to must be web or google-docs");
      destination = value;
    } else if (argument === "--out-dir") outDir = requiredValue(args, index++, argument);
    else if (argument === "--document-id") documentId = requiredValue(args, index++, argument);
    else if (argument === "--folder-id") folderId = requiredValue(args, index++, argument);
    else if (argument === "--if-version") expectedVersion = requiredValue(args, index++, argument);
    else if (argument === "--access-token-env") accessTokenEnv = requiredValue(args, index++, argument);
    else if (argument === "--config") configPath = requiredValue(args, index++, argument);
    else if (argument === "--allow-indexing") allowIndexing = true;
    else if (argument === "--replace-existing") replaceExisting = true;
    else if (argument === "--apply") apply = true;
    else if (argument === "--json") format = "json";
    else if (argument === "--format") {
      const value = requiredValue(args, index++, argument);
      if (value !== "text" && value !== "json") throw new Error("--format must be text or json");
      format = value;
    } else {
      throw new Error(`Unknown publish document option: ${argument}`);
    }
  }

  if (!file) throw new Error("publish document requires --file FILE");
  if (line !== undefined && (!Number.isInteger(line) || line < 1)) throw new Error("--line must be a positive integer");
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(accessTokenEnv)) throw new Error("--access-token-env must name an environment variable");
  if (destination === "web") {
    if (!outDir) throw new Error("web publishing requires --out-dir DIR");
    if (documentId || folderId || expectedVersion) throw new Error("Google Drive options require --to google-docs");
  } else {
    if (outDir) throw new Error("--out-dir only applies to --to web");
    if (allowIndexing) throw new Error("--allow-indexing only applies to --to web");
    if (documentId && folderId) throw new Error("--folder-id cannot be used when updating --document-id");
    if (documentId && !replaceExisting) throw new Error("updating --document-id requires --replace-existing");
    if (documentId && !expectedVersion) throw new Error("updating --document-id requires --if-version VERSION");
    if (!documentId && expectedVersion) throw new Error("--if-version requires --document-id");
    if (!documentId && replaceExisting) throw new Error("--replace-existing requires --document-id for Google Docs");
  }

  return {
    file,
    ...(line !== undefined ? { line } : {}),
    ...(title !== undefined ? { title } : {}),
    destination,
    ...(outDir !== undefined ? { outDir } : {}),
    ...(documentId !== undefined ? { documentId } : {}),
    ...(folderId !== undefined ? { folderId } : {}),
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    accessTokenEnv,
    ...(configPath !== undefined ? { configPath } : {}),
    allowIndexing,
    replaceExisting,
    apply,
    format,
  };
}

function prepare(arguments_: PublishDocumentArguments): { publication: PreparedPublishedDocument; file: string; configPath?: string } {
  const file = path.resolve(arguments_.file);
  if (!fs.existsSync(file)) throw new Error(`File not found: ${file}`);
  const stat = fs.statSync(file);
  if (!stat.isFile()) throw new Error(`Not a file: ${file}`);
  const discoveredConfig = arguments_.configPath
    ? path.resolve(arguments_.configPath)
    : findConfigFile(path.dirname(file)) || undefined;
  const config = discoveredConfig ? loadConfig(discoveredConfig) : undefined;
  const sourceText = fs.readFileSync(file, "utf8");
  const publication = preparePublishedDocument({
    sourceText,
    sourcePath: file,
    ...(arguments_.line !== undefined ? { line: arguments_.line } : {}),
    ...(arguments_.title ? { title: arguments_.title } : {}),
    allowIndexing: arguments_.allowIndexing,
    linkAbbreviations: config?.links?.abbreviations,
    linearTeam: config?.links?.linearTeam,
  });
  return { publication, file, ...(discoveredConfig ? { configPath: discoveredConfig } : {}) };
}

function redactionCount(publication: PreparedPublishedDocument): number {
  return Object.values(publication.redactions).reduce((sum, count) => sum + count, 0);
}

function printTextPreview(
  arguments_: PublishDocumentArguments,
  prepared: ReturnType<typeof prepare>,
  destination: Record<string, unknown>,
): void {
  const verb = arguments_.apply ? "published" : "would publish";
  console.log(`${verb}: ${prepared.publication.manifest.title}`);
  console.log(`source: ${prepared.file}${arguments_.line ? ` (subtree at line ${arguments_.line})` : ""}`);
  console.log(`artifact: ${prepared.publication.manifest.bytes} bytes, ${prepared.publication.assets.length} embedded image${prepared.publication.assets.length === 1 ? "" : "s"}`);
  console.log(`disclosure: ${redactionCount(prepared.publication)} private or unsafe element${redactionCount(prepared.publication) === 1 ? "" : "s"} removed`);
  if (arguments_.destination === "web") {
    console.log(`destination: web bundle at ${String(destination.outDir || arguments_.outDir)}`);
  } else if (arguments_.documentId) {
    console.log(`destination: Google Doc ${arguments_.documentId} at expected version ${arguments_.expectedVersion}`);
  } else {
    console.log(`destination: new Google Doc${arguments_.folderId ? ` in folder ${arguments_.folderId}` : ""}`);
  }
  for (const warning of prepared.publication.warnings) console.log(`warning: ${warning}`);
  if (!arguments_.apply) console.log("preview only; pass --apply to publish");
}

export async function runPublishDocumentCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "publish" || args[1] !== "document") return false;
  if (args.includes("--help") || args.includes("-h")) usage(0);
  const arguments_ = parseArguments(args);
  const prepared = prepare(arguments_);

  let destination: Record<string, unknown>;
  if (arguments_.destination === "web") {
    const outDir = path.resolve(arguments_.outDir || "");
    destination = arguments_.apply
      ? writeWebPublicationBundle(prepared.publication, { outDir, replaceExisting: arguments_.replaceExisting })
      : {
          destination: "web",
          action: fs.existsSync(outDir) && fs.readdirSync(outDir).length > 0 ? "replace" : "create",
          outDir,
          indexPath: path.join(outDir, "index.html"),
          manifestPath: path.join(outDir, "manifest.json"),
          requiresHosting: true,
          authentication: "enforced by the selected host; the bundle contains no corpus access",
        };
  } else {
    if (arguments_.apply) {
      const accessToken = String(process.env[arguments_.accessTokenEnv] || "").trim();
      if (!accessToken) throw new Error(`Google Docs publishing requires ${arguments_.accessTokenEnv} in the environment`);
      destination = await publishToGoogleDocs(prepared.publication, {
        accessToken,
        ...(arguments_.documentId ? { documentId: arguments_.documentId } : {}),
        ...(arguments_.folderId ? { folderId: arguments_.folderId } : {}),
        ...(arguments_.expectedVersion ? { expectedVersion: arguments_.expectedVersion } : {}),
        replaceExisting: arguments_.replaceExisting,
      });
    } else {
      const upload = prepareGoogleDocsUpload(prepared.publication);
      destination = {
        destination: "google-docs",
        action: arguments_.documentId ? "update" : "create",
        mimeType: GOOGLE_DOCS_MIME_TYPE,
        inputMediaType: upload.mediaType,
        uploadBytes: upload.byteLength,
        artifactHash: upload.sha256,
        maxArtifactBytes: GOOGLE_DRIVE_MULTIPART_MAX_BYTES,
        requiredOAuthScope: GOOGLE_DRIVE_FILE_SCOPE,
        sharing: "Google Drive permissions are inherited and are not changed by this command",
        updateGuards: "existing content version must match and the target must have no comments",
        ...(arguments_.documentId ? { documentId: arguments_.documentId, expectedVersion: arguments_.expectedVersion } : {}),
        ...(arguments_.folderId ? { folderId: arguments_.folderId } : {}),
      };
    }
  }

  const payload = {
    $schema: "org2:publish-document-command-result:v1",
    applied: arguments_.apply,
    source: {
      file: prepared.file,
      selection: prepared.publication.manifest.selection,
      sourceHash: prepared.publication.sourceHash,
      ...(arguments_.line !== undefined ? { line: arguments_.line } : {}),
      ...(prepared.configPath ? { configPath: prepared.configPath } : {}),
    },
    artifact: {
      ...prepared.publication.manifest,
      projectionHash: prepared.publication.projectionHash,
      assets: prepared.publication.assets,
    },
    disclosure: {
      redactions: prepared.publication.redactions,
      warnings: prepared.publication.warnings,
    },
    destination,
  };
  if (arguments_.format === "json") console.log(JSON.stringify(payload, null, 2));
  else printTextPreview(arguments_, prepared, destination);
  return true;
}
