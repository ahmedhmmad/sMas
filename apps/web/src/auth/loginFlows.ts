// F1.5 — مسارات الدخول الحقيقية من F2. كل جلسة يصدرها Supabase Auth؛ الواجهة لا ترى ولا تعرض بريداً
// اصطناعياً ولا token_hash ولا رابط جلسة — FastAPI يعيد حقول الجلسة وحدها، فتُسلَّم لـsupabase-js.
// F3: لا tenant ولا مدرسة في أي طلب — المتصفح يرسل Origin (host المدرسة/الـTenant) و FastAPI يشتق منه «أين يُبحث»
// عن الحساب؛ الجسم يُرفض إن حملهما (لا context drift).
import { api, ApiError } from "../lib/api";
import { adoptSession, type Session, supabase } from "../lib/supabase";

export type AccountKind = "staff" | "guardian" | "student" | "native";
const KIND_KEY = "smas.accountKind";

function remember(kind: AccountKind): void {
  try {
    window.sessionStorage.setItem(KIND_KEY, kind);
  } catch {
    // لا تخزين — التسمية الافتراضية
  }
}

export function accountKind(): AccountKind | null {
  try {
    return window.sessionStorage.getItem(KIND_KEY) as AccountKind | null;
  } catch {
    return null;
  }
}

async function adopt(session: Session, kind: AccountKind): Promise<void> {
  await adoptSession(session);
  remember(kind);
}

export async function loginStaff(email: string, password: string): Promise<void> {
  const session = await api<Session>("/auth/password/login", {
    method: "POST", auth: false,
    body: { kind: "staff", contact: email, password },
  });
  await adopt(session, "staff");
}

// 3-2 (P14): الموظف الجديد بلا كلمة مرور — يدخل برمز تحقق على بريده المسجل (D3)؛ المسار نفسه لولي الأمر بنوع staff
export async function requestStaffCode(email: string): Promise<void> {
  await api("/auth/otp/request", { method: "POST", auth: false, body: { kind: "staff", contact: email } });
}

export async function verifyStaffCode(email: string, code: string): Promise<void> {
  const session = await api<Session>("/auth/otp/verify", {
    method: "POST", auth: false,
    body: { kind: "staff", contact: email, code },
  });
  await adopt(session, "staff");
}

export async function loginStudent(identifier: string, password: string): Promise<void> {
  const session = await api<Session>("/auth/student/login", {
    method: "POST", auth: false,
    body: { identifier, password },
  });
  await adopt(session, "student");
}

export async function requestGuardianCode(phone: string): Promise<void> {
  await api("/auth/otp/request", {
    method: "POST", auth: false,
    body: { kind: "guardian", contact: phone },
  });
}

export async function verifyGuardianCode(phone: string, code: string): Promise<void> {
  const session = await api<Session>("/auth/otp/verify", {
    method: "POST", auth: false,
    body: { kind: "guardian", contact: phone, code },
  });
  await adopt(session, "guardian");
}

export async function loginGuardianPassword(phone: string, password: string): Promise<void> {
  const session = await api<Session>("/auth/password/login", {
    method: "POST", auth: false,
    body: { kind: "guardian", contact: phone, password },
  });
  await adopt(session, "guardian");
}

// Platform Admin و tenant_admin: هوية أصلية بالبريد (قرار tenant_admin المؤجل)
export async function loginNative(email: string, password: string): Promise<void> {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new ApiError(error.status ?? 400, "invalid_credentials");
  remember("native");
}

// D2 / D4 (A، C): تغيير الكلمة بجلسة المستخدم ثم التفعيل المتحكَّم به
export async function changePasswordAndActivate(password: string): Promise<void> {
  const { error } = await supabase.auth.updateUser({ password });
  if (error) throw new ApiError(error.status ?? 422, "weak_password");
  await api("/auth/activate", { method: "POST" });
}

export async function logout(): Promise<void> {
  await supabase.auth.signOut();
  try {
    window.sessionStorage.removeItem(KIND_KEY);
  } catch {
    // لا شيء
  }
}
