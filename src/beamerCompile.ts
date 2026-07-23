import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export type BeamerPdfCompileOptions = {
  sourcePath: string;
  engine?: string;
  passes?: number;
};

export type BeamerPdfCompileResult =
  | {
      ok: true;
      pdf: Buffer;
      log: string;
      engine: string;
    }
  | {
      ok: false;
      log: string;
      engine: string;
      message: string;
    };

export function summarizeLatexFailure(
  log: string,
  engine: string,
  status: number | null,
): string {
  const normalizedLog = log.replace(/(\.tex:\d*)\r?\n(?=\d*:)/g, "$1");
  const packageError = /(?:^|\n).*?\.tex:(\d+): Package ([^\s]+) Error:\s*([^\n]+)(?:\n\(\2\)\s*([^\n]+))?/m
    .exec(normalizedLog);
  if (packageError) {
    const detail = [packageError[3], packageError[4]]
      .filter(Boolean)
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
    return `${engine} failed at generated line ${packageError[1]}: ${detail}`;
  }

  const latexError = /(?:^|\n)! (?:LaTeX|pdfTeX) Error:\s*([^\n]+)/m.exec(normalizedLog);
  if (latexError) {
    return `${engine} failed: ${latexError[1]!.trim()}`;
  }

  const fileError = /(?:^|\n).*?\.tex:(\d+):\s*([^\n]*Error:[^\n]*)/m.exec(normalizedLog);
  if (fileError) {
    return `${engine} failed at generated line ${fileError[1]}: ${fileError[2]!.trim()}`;
  }

  return `${engine} exited with status ${status ?? "unknown"}.`;
}

export function compileBeamerPdf(
  tex: string,
  options: BeamerPdfCompileOptions,
): BeamerPdfCompileResult {
  const engine = String(options.engine || "pdflatex").trim() || "pdflatex";
  if (/\s/.test(engine)) {
    return {
      ok: false,
      engine,
      log: "",
      message: "The LaTeX engine must be a command or path without additional arguments.",
    };
  }

  const sourcePath = path.resolve(options.sourcePath);
  const sourceDirectory = path.dirname(sourcePath);
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "org2-beamer-"));
  const temporaryTexPath = path.join(temporaryDirectory, "deck.tex");
  const temporaryPdfPath = path.join(temporaryDirectory, "deck.pdf");
  const passes = Math.max(1, Math.min(4, Math.trunc(options.passes ?? 2)));
  const logs: string[] = [];

  try {
    fs.writeFileSync(temporaryTexPath, tex, "utf8");

    for (let pass = 0; pass < passes; pass += 1) {
      const compiled = spawnSync(
        engine,
        [
          "-interaction=nonstopmode",
          "-halt-on-error",
          "-file-line-error",
          `-output-directory=${temporaryDirectory}`,
          temporaryTexPath,
        ],
        {
          cwd: sourceDirectory,
          encoding: "utf8",
          maxBuffer: 16 * 1024 * 1024,
        },
      );
      const passLog = [compiled.stdout, compiled.stderr].filter(Boolean).join("\n").trim();
      if (passLog) logs.push(passLog);

      if (compiled.error) {
        return {
          ok: false,
          engine,
          log: logs.join("\n\n"),
          message: `Could not run ${engine}: ${compiled.error.message}`,
        };
      }
      if (compiled.status !== 0) {
        return {
          ok: false,
          engine,
          log: logs.join("\n\n"),
          message: summarizeLatexFailure(logs.join("\n\n"), engine, compiled.status),
        };
      }
    }

    if (!fs.existsSync(temporaryPdfPath)) {
      return {
        ok: false,
        engine,
        log: logs.join("\n\n"),
        message: `${engine} completed without producing deck.pdf.`,
      };
    }

    return {
      ok: true,
      engine,
      pdf: fs.readFileSync(temporaryPdfPath),
      log: logs.join("\n\n"),
    };
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
