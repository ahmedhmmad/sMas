// F3 — قواعد سياق الـhost (قرار 2026-10-01):
//   {school}.{tenant}.{base} ← سياق مدرسة · {tenant}.{base} ← سياق Tenant · admin.{base} ← المنصة
// السياق للعرض واختيار نموذج الدخول فقط — ليس صلاحية. القواعد نفسها في FastAPI (services/api/app/host_context.py)
// وفي قيود DB (M30)؛ المتجهات المشتركة: docs/contracts/host_context_vectors.json.
export type HostContext =
  | { kind: "school"; tenant: string; school: string }
  | { kind: "tenant"; tenant: string }
  | { kind: "platform" };

const TENANT_LABEL = /^[a-z0-9][a-z0-9-]{0,62}$/;   // platform_tenants_host_label_chk
const SCHOOL_SLUG = /^[a-z0-9][a-z0-9-]{1,62}$/;    // schools_slug_chk
const RESERVED = new Set(["admin", "api", "www"]);  // platform_tenants_host_label_reserved
const PLATFORM_LABEL = "admin";

const tenantLabel = (label: string) => TENANT_LABEL.test(label) && !RESERVED.has(label);

export function parseHost(hostname: string, base: string): HostContext | null {
  if (!base || !hostname.endsWith(`.${base}`)) return null;
  const labels = hostname.slice(0, -(base.length + 1)).split(".");
  if (labels.length === 1) {
    const [label] = labels;
    if (label === PLATFORM_LABEL) return { kind: "platform" };
    return tenantLabel(label) ? { kind: "tenant", tenant: label } : null;
  }
  if (labels.length === 2) {
    const [school, tenant] = labels;
    if (tenantLabel(tenant) && SCHOOL_SLUG.test(school)) return { kind: "school", tenant, school };
  }
  return null;
}
