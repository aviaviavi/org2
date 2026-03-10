export interface ProtectedPgpBlocks {
  text: string;
  blocks: string[];
}

const PGP_BLOCK_RE = /(^|\n)([ \t]*-----BEGIN PGP MESSAGE-----[\s\S]*?-----END PGP MESSAGE-----[ \t]*)(?=\n|$)/g;

export function protectPgpBlocks(rawText: string): ProtectedPgpBlocks {
  const blocks: string[] = [];
  const text = rawText.replace(PGP_BLOCK_RE, (_match, prefix: string, block: string) => {
    const token = `__ORG2_PGP_BLOCK_${blocks.length}__`;
    blocks.push(block);
    return `${prefix}${token}`;
  });

  return { text, blocks };
}

export function restorePgpBlocks(text: string, blocks: string[]): string {
  let out = text;
  for (let i = 0; i < blocks.length; i += 1) {
    const token = `__ORG2_PGP_BLOCK_${i}__`;
    out = out.split(token).join(blocks[i]!);
  }
  return out;
}

export function normalizePgpArmorForDecrypt(rawArmor: string): string {
  const lines = rawArmor.replace(/\r\n/g, "\n").split("\n");
  const out: string[] = [];

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    out.push(line);

    if (!/^\s*-----BEGIN PGP MESSAGE-----\s*$/.test(line)) {
      continue;
    }

    const next = lines[i + 1] ?? "";
    if (next.trim() === "" || /^\s*-----END PGP MESSAGE-----\s*$/.test(next)) {
      continue;
    }

    if (/^[A-Za-z0-9-]+:\s*/.test(next)) {
      let j = i + 1;
      while (j < lines.length && /^[A-Za-z0-9-]+:\s*/.test(lines[j] ?? "")) {
        j += 1;
      }
      if ((lines[j] ?? "").trim() !== "") {
        out.push("");
      }
      continue;
    }

    out.push("");
  }

  return out.join("\n");
}
