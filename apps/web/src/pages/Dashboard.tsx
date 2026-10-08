import { useEffect, useState } from "react";
import { Link } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import { ContextLabel } from "../components/ContextLabel";
import { navItems } from "../components/navigation";
import { t } from "../i18n";
import { api } from "../lib/api";
import { supabase } from "../lib/supabase";

type Teaching = {
  kind: "teaching" | "class_teacher"; id: string; school_name: string | null; academic_year_name: string;
  section_name: string; grade_level_name: string; subject_name: string | null;
};

// 3-4 — «شعبي وموادي»: لمن يقرأ الطلاب بالتكليف وحده (عرض — القرار في RLS). الخادم يعيد التكليفات الفعّالة فقط.
function MyTeaching() {
  const [rows, setRows] = useState<Teaching[] | null>(null);
  useEffect(() => {
    void api<{ rows: Teaching[] }>("/me/teaching").then((b) => setRows(b.rows)).catch(() => setRows([]));
  }, []);
  if (rows === null) return null;
  return (
    <div className="mb-6 rounded bg-white p-4 shadow-sm" data-testid="my-teaching">
      <h2 className="mb-2 font-medium">{t("dashboard.myTeaching")}</h2>
      {rows.length === 0 ? (
        <p data-testid="my-teaching-empty" className="text-slate-500">{t("dashboard.myTeachingEmpty")}</p>
      ) : (
        <ul className="space-y-1">
          {rows.map((r) => (
            <li key={r.id} data-testid={`my-teaching-${r.id}`}>
              {r.grade_level_name} / {r.section_name} — {r.kind === "class_teacher" ? t("dashboard.classTeacher") : r.subject_name}
              <span className="text-sm text-slate-500"> · {r.school_name ? `${r.school_name} · ` : ""}{r.academic_year_name}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function Dashboard() {
  const { capabilities, kind, userId, can } = useAuth();
  const [name, setName] = useState<string | null>(null);

  useEffect(() => {
    if (capabilities.context !== "tenant" || !userId) return;
    // صف الـprofile الخاص (RLS: الصف الذاتي) — للعرض
    void supabase.from("profiles").select("display_name").eq("auth_user_id", userId).maybeSingle()
      .then(({ data }) => setName(data?.display_name ?? null));
  }, [capabilities.context, userId]);

  const links = navItems(capabilities, kind).filter((i) => i.to !== "/");
  return (
    <section data-testid="dashboard">
      <h1 className="mb-4 text-2xl font-semibold">
        {t("dashboard.welcome")}{name ? `، ${name}` : ""}
      </h1>
      <div className="mb-6 rounded bg-white p-4 shadow-sm">
        <h2 className="mb-2 font-medium">{t("dashboard.context")}</h2>
        {capabilities.context === "platform" ? (
          <p data-testid="dashboard-platform">{t("dashboard.platform")}</p>
        ) : (
          <p><ContextLabel testId="dashboard-tenant" /></p>
        )}
      </div>
      {capabilities.context === "tenant" && can("student.read_assigned") && !can("student.read") && <MyTeaching />}
      <div className="grid gap-3 sm:grid-cols-2">
        {links.map((l) => (
          <Link key={l.to} to={l.to} data-testid={`card-${l.testId}`} className="rounded bg-white p-4 shadow-sm hover:bg-emerald-50">
            {t(l.labelKey)}
          </Link>
        ))}
      </div>
    </section>
  );
}
