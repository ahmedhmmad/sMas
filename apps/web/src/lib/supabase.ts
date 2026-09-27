// عميل Supabase في المتصفح: الجلسة (تخزين، تجديد تلقائي) وقراءة البيانات عبر PostgREST تحت RLS.
import { createClient } from "@supabase/supabase-js";
import { config } from "./config";

export const supabase = createClient(config.supabaseUrl, config.publishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});

export type Session = { access_token: string; refresh_token: string };

// الجلسات التي تصدرها Supabase Auth عبر FastAPI (D1، D3) تُسلَّم لـsupabase-js ليتولى التجديد
export async function adoptSession(session: Session): Promise<void> {
  const { error } = await supabase.auth.setSession(session);
  if (error) throw error;
}
