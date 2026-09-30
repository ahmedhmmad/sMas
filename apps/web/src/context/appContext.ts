// F1.2 / F3 — سياق الـTenant والمدرسة من الـhost (window.location.hostname): للعرض واختيار نموذج الدخول فقط.
//
// ⚠️ ليس مدخل صلاحية: لا تضيف أي دالة جلب بيانات tenant أو school_id من هنا كنطاق — البيانات هي ما تعيده
// RLS و FastAPI للجلسة. (قرار F1، قيد 2؛ يحرسه src/guards.test.ts)
// ولا يُرسل إلى الخادم: FastAPI يشتق سياق الدخول من ترويسة Origin التي يضعها المتصفح نفسه (F3.4).
import { config } from "../lib/config";
import { type HostContext, parseHost } from "./hostContext";

export type TenantContext = { label: string; source: "host" };
export type SchoolContext = { slug: string; source: "host" };

// null = host غير معروف (لا أحد الأشكال الثلاثة) — التطبيق لا يعرض دخولاً ولا يطلب شيئاً من الخادم
export function getHostContext(): HostContext | null {
  return parseHost(window.location.hostname, config.baseDomain);
}

export function getTenantContext(): TenantContext | null {
  const host = getHostContext();
  return host && host.kind !== "platform" ? { label: host.tenant, source: "host" } : null;
}

export function getSchoolContext(): SchoolContext | null {
  const host = getHostContext();
  return host?.kind === "school" ? { slug: host.school, source: "host" } : null;
}
