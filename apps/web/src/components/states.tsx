import { Link } from "react-router";
import { t } from "../i18n";

export function Loading() {
  return (
    <div role="status" data-testid="state-loading" className="p-8 text-center text-slate-500">
      {t("app.loading")}
    </div>
  );
}

function Message({ testId, textKey }: { testId: string; textKey: string }) {
  return (
    <div data-testid={testId} className="mx-auto max-w-md p-8 text-center">
      <p className="mb-4 text-slate-700">{t(textKey)}</p>
      <Link to="/" className="text-emerald-700 underline">
        {t("state.home")}
      </Link>
    </div>
  );
}

export const NotFound = () => <Message testId="state-not-found" textKey="state.notFound" />;
export const Forbidden = () => <Message testId="state-forbidden" textKey="state.forbidden" />;
export const ErrorState = () => <Message testId="state-error" textKey="state.error" />;
export const Unavailable = () => <Message testId="state-unavailable" textKey="state.unavailable" />;

// F3: host ليس أحد الأشكال الثلاثة — صفحة ثابتة خارج الموجّه: لا دخول، ولا طلب إلى الخادم
export function UnknownHost() {
  return (
    <div data-testid="state-unknown-host" className="mx-auto mt-16 max-w-md p-8 text-center">
      <h1 className="mb-2 text-xl font-semibold">{t("app.name")}</h1>
      <p className="text-slate-700">{t("state.unknownHost")}</p>
    </div>
  );
}
