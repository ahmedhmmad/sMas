import { useEffect, useState } from "react";
import { Link } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import { navItems } from "../components/navigation";
import { getSchoolContext, getTenantContext } from "../context/appContext";
import { t } from "../i18n";
import { supabase } from "../lib/supabase";

export function Dashboard() {
  const { capabilities, kind, userId } = useAuth();
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
          <p data-testid="dashboard-tenant">
            {t("context.tenant")}: {getTenantContext().code} · {t("context.school")}: {getSchoolContext().slug}
          </p>
        )}
      </div>
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
