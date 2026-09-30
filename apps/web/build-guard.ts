// F3: بناء الواجهة يشترط النطاق الأساسي للـhost (VITE_BASE_DOMAIN) — وإلا لا يتعرف التطبيق على أي host فيعرض
// «عنوان غير معروف» في كل مكان. الفشل هنا عند البناء بدل الاكتشاف بعد النشر. التطوير (vite dev) يفترض localhost.
// (أداة سياق التطوير W2 أُزيلت في F3 — السياق من الـhost وحده في كل بناء.)
const DNS_NAME = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export function assertBaseDomain(command: string, env: Record<string, string | undefined>): void {
  if (command !== "build") return;
  const base = env.VITE_BASE_DOMAIN ?? "";
  if (!DNS_NAME.test(base)) {
    throw new Error(`VITE_BASE_DOMAIN must be the web base domain (e.g. smas.example or localhost); got "${base}"`);
  }
}
