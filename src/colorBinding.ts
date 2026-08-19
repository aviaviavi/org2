export type OrgColorValue = {
  source: string;
  css: string;
  hex: string;
};

export type OrgColorBinding = {
  foreground?: OrgColorValue;
  background?: OrgColorValue;
};

const NAMED_COLORS: Readonly<Record<string, string>> = {
  black: "1c1c1e",
  blue: "007aff",
  brown: "a2845e",
  gray: "8e8e93",
  green: "34c759",
  grey: "8e8e93",
  indigo: "5856d6",
  mint: "00c7be",
  orange: "ff9500",
  pink: "ff2d55",
  purple: "af52de",
  red: "ff3b30",
  teal: "30b0c7",
  white: "f2f2f7",
  yellow: "ffcc00",
};

export function parseOrgColorValue(raw: string): OrgColorValue | null {
  const source = String(raw || "").trim();
  if (!source) return null;

  const namedHex = NAMED_COLORS[source.toLowerCase()];
  if (namedHex) return { source, css: `#${namedHex}`, hex: namedHex };

  const match = /^#([a-f\d]{3}|[a-f\d]{6})$/i.exec(source);
  if (!match) return null;
  const compact = (match[1] || "").toLowerCase();
  const hex = compact.length === 3
    ? compact.split("").map((digit) => `${digit}${digit}`).join("")
    : compact;
  return { source, css: `#${hex}`, hex };
}

export function parseOrgColorBindingTarget(rawTarget: string): OrgColorBinding | null {
  const target = String(rawTarget || "").trim();
  if (!/^color:/i.test(target)) return null;
  const body = target.slice(target.indexOf(":") + 1).trim();
  if (!body) return null;

  const binding: OrgColorBinding = {};
  const declarations = body.split(";").map((value) => value.trim()).filter(Boolean);
  for (const declaration of declarations) {
    const equals = declaration.indexOf("=");
    if (equals === -1) {
      if (declarations.length !== 1 || binding.foreground) return null;
      const color = parseOrgColorValue(declaration);
      if (!color) return null;
      binding.foreground = color;
      continue;
    }

    const key = declaration.slice(0, equals).trim().toLowerCase();
    const color = parseOrgColorValue(declaration.slice(equals + 1));
    if (!color) return null;
    if (["fg", "foreground", "text"].includes(key)) {
      if (binding.foreground) return null;
      binding.foreground = color;
    } else if (["bg", "background"].includes(key)) {
      if (binding.background) return null;
      binding.background = color;
    } else {
      return null;
    }
  }

  return binding.foreground || binding.background ? binding : null;
}
