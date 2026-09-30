// F3: السياق كما يحمله الـhost — عرض فقط. معرّفات الـhost لا أسماء (اسم المدرسة يحتاج بحثاً عاماً — خارج F3، بند 5).
import { getSchoolContext, getTenantContext } from "../context/appContext";
import { t } from "../i18n";

export function ContextLabel({ testId }: { testId: string }) {
  const tenant = getTenantContext();
  const school = getSchoolContext();
  if (!tenant) return <span data-testid={testId}>{t("context.platform")}</span>;   // host غير معروف لا يصل إلى هنا (App)
  return (
    <span data-testid={testId}>
      {t("context.tenant")}: {tenant.label}
      {school && <> · {t("context.school")}: {school.slug}</>}
    </span>
  );
}
