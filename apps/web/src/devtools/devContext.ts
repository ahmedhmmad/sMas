// W2: أداة سياق التطوير — وحدة مستقلة لا تُستورد إلا خلف شرط يُطوى عند البناء، فتسقط من بناء production كلياً.
const KEY_TENANT = "smas.dev.tenant";
const KEY_SCHOOL = "smas.dev.school";

function read(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

export const readDevTenant = () => read(KEY_TENANT);
export const readDevSchool = () => read(KEY_SCHOOL);

export function writeDevContext(tenantCode: string, schoolSlug: string): void {
  try {
    window.localStorage.setItem(KEY_TENANT, tenantCode.trim());
    window.localStorage.setItem(KEY_SCHOOL, schoolSlug.trim());
  } catch {
    // التخزين غير متاح — يبقى الافتراضي
  }
}
