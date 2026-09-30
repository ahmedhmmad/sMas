// إعداد الواجهة — قيم عامة فقط (تصل إلى المتصفح بطبيعتها): عنوان Supabase، المفتاح المنشور، عنوان FastAPI.
// لا مفتاح سري ولا service_role هنا أبداً (PLAN §3.3 بند 12).
export const config = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL ?? "http://127.0.0.1:54321",
  publishableKey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? "",
  apiUrl: import.meta.env.VITE_API_URL ?? "http://127.0.0.1:8000",
  // F3: النطاق الأساسي للـhost ({school}.{tenant}.{base}). التطوير: *.localhost؛ بناء production يشترطه (build-guard)
  baseDomain: import.meta.env.VITE_BASE_DOMAIN ?? (import.meta.env.DEV ? "localhost" : ""),
};
