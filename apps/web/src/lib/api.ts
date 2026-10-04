// عميل FastAPI: Bearer من جلسة supabase-js؛ الأخطاء رموز آلة (F4) تُترجم في الواجهة.
// لا يُضاف هنا tenant ولا school من السياق — القرار في الخادم (قرار F1، قيد 2).
import { config } from "./config";
import { supabase } from "./supabase";

export class ApiError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

async function bearer(): Promise<Record<string, string>> {
  const { data } = await supabase.auth.getSession();
  return data.session ? { Authorization: `Bearer ${data.session.access_token}` } : {};
}

export async function api<T>(path: string, init: { method?: "GET" | "POST" | "PATCH"; body?: unknown; auth?: boolean } = {}): Promise<T> {
  const headers: Record<string, string> = { "Content-Type": "application/json", ...(init.auth === false ? {} : await bearer()) };
  let response: Response;
  try {
    response = await fetch(`${config.apiUrl}${path}`, {
      method: init.method ?? "GET",
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
  } catch {
    throw new ApiError(0, "network");
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = typeof payload?.detail === "string" ? payload.detail : "generic";
    throw new ApiError(response.status, detail);
  }
  return payload as T;
}
