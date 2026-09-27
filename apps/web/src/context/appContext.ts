// F1.2 — سياق الـTenant والمدرسة: للعرض ولطلبات الدخول فقط.
//
// ⚠️ ليس مدخل صلاحية: لا تضيف أي دالة جلب بيانات tenant أو school_id من هنا كنطاق — البيانات هي ما تعيده
// RLS و FastAPI للجلسة. (قرار F1، قيد 2؛ يحرسه src/guards.test.ts)
//
// التنفيذ الحالي: متغيرات البيئة، ومعها في بناء التطوير وحده اختيار محلي (src/devtools — W2).
// F3 يستبدل هذا الملف وحده بمحلل النطاق الفرعي (subdomain ← tenant + school) — المستدعون لا يتغيرون.
import * as dev from "../devtools/devContext";

export type TenantContext = { code: string; source: "development" };
export type SchoolContext = { slug: string; source: "development" };

// يُطوى عند البناء: في production يصير false فتسقط قراءة التخزين المحلي
const DEV_CONTEXT = import.meta.env.DEV || import.meta.env.VITE_DEV_CONTEXT === "1";

export function getTenantContext(): TenantContext {
  const override = DEV_CONTEXT ? dev.readDevTenant() : null;
  return { code: override || import.meta.env.VITE_DEV_TENANT_CODE || "DEV", source: "development" };
}

export function getSchoolContext(): SchoolContext {
  const override = DEV_CONTEXT ? dev.readDevSchool() : null;
  return { slug: override || import.meta.env.VITE_DEV_SCHOOL_SLUG || "school-a", source: "development" };
}
