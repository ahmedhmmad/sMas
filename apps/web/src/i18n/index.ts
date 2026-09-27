// F1.7 — ترجمة دنيا: t(key) من فهرس JSON. العربية أولاً؛ إضافة لغة = فهرس جديد + اتجاهه.
import ar from "./ar.json";

type Catalog = { [key: string]: string | Catalog };

const catalogs: Record<string, { messages: Catalog; dir: "rtl" | "ltr" }> = {
  ar: { messages: ar as Catalog, dir: "rtl" },
};

let current = "ar";

export function lookup(key: string, catalog: Catalog = catalogs[current].messages): string | undefined {
  let node: string | Catalog | undefined = catalog;
  for (const part of key.split(".")) {
    if (typeof node !== "object" || node === null) return undefined;
    node = node[part];
  }
  return typeof node === "string" ? node : undefined;
}

export function t(key: string): string {
  // مفتاح مفقود يظهر كما هو — واختبار اكتمال الفهرس يُفشل البناء قبل ذلك
  return lookup(key) ?? key;
}

export function direction(): "rtl" | "ltr" {
  return catalogs[current].dir;
}

export function language(): string {
  return current;
}

export function setLanguage(lang: string): void {
  if (catalogs[lang]) current = lang;
}

export function catalogKeys(catalog: Catalog = catalogs[current].messages, prefix = ""): string[] {
  return Object.entries(catalog).flatMap(([k, v]) =>
    typeof v === "string" ? [prefix + k] : catalogKeys(v, `${prefix}${k}.`),
  );
}

// رموز أخطاء الـAPI (آلة) ← مفاتيح الترجمة
export function errorText(code: string): string {
  return lookup(`error.${code}`) ?? t("error.generic");
}
