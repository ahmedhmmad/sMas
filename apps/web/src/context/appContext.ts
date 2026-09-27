// F1.2 — سياق الـTenant والمدرسة: للعرض ولطلبات الدخول فقط.
//
// ⚠️ ليس مدخل صلاحية: لا تضيف أي دالة جلب بيانات tenant أو school_id من هنا كنطاق — البيانات هي ما تعيده
// RLS و FastAPI للجلسة. (قرار F1، قيد 2؛ يحرسه src/context/contextGuard.test.ts)
//
// التنفيذ الحالي: سياق تطوير مؤقت (متغيرات البيئة + اختيار محلي في المتصفح).
// F3 يستبدل هذا الملف وحده بمحلل النطاق الفرعي (subdomain ← tenant + school) — المستدعون لا يتغيرون.

export type TenantContext = { code: string; source: "development" };
export type SchoolContext = { slug: string; source: "development" };

const KEY_TENANT = "smas.dev.tenant";
const KEY_SCHOOL = "smas.dev.school";

function stored(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function getTenantContext(): TenantContext {
  return { code: stored(KEY_TENANT) || import.meta.env.VITE_DEV_TENANT_CODE || "DEV", source: "development" };
}

export function getSchoolContext(): SchoolContext {
  return { slug: stored(KEY_SCHOOL) || import.meta.env.VITE_DEV_SCHOOL_SLUG || "school-a", source: "development" };
}

// أداة التطوير فقط (F3 يزيلها): تغيير السياق المعروض وسياق طلبات الدخول
export function setDevContext(tenantCode: string, schoolSlug: string): void {
  try {
    window.localStorage.setItem(KEY_TENANT, tenantCode.trim());
    window.localStorage.setItem(KEY_SCHOOL, schoolSlug.trim());
  } catch {
    // التخزين غير متاح — يبقى الافتراضي
  }
}
