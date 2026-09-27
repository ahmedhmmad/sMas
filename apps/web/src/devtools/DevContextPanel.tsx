// W2: لوحة سياق التطوير (F3 يزيلها) — تُحمَّل كسولاً في بناء التطوير فقط.
import { useState } from "react";
import { getSchoolContext, getTenantContext } from "../context/appContext";
import { t } from "../i18n";
import { Field } from "../pages/Login";
import { writeDevContext } from "./devContext";

export default function DevContextPanel() {
  const [tenant, setTenant] = useState(getTenantContext().code);
  const [school, setSchool] = useState(getSchoolContext().slug);
  return (
    <details className="mt-6 text-sm text-slate-500" data-testid="dev-context">
      <summary>{t("app.devContext")}</summary>
      <div className="mt-2 grid gap-2">
        <Field id="dev-tenant" labelKey="context.tenantCode" value={tenant} onChange={setTenant} />
        <Field id="dev-school" labelKey="context.schoolSlug" value={school} onChange={setSchool} />
        <button type="button" data-testid="dev-apply" className="rounded border px-3 py-1" onClick={() => writeDevContext(tenant, school)}>
          {t("context.apply")}
        </button>
      </div>
    </details>
  );
}
