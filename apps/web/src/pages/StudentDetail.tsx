// تفاصيل طالب: صف واحد تحت RLS — غير المرئي = غير موجود (لا يُكشف وجوده)، حتى مع كتابة الرابط يدوياً.
import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { Loading, NotFound } from "../components/states";
import { t } from "../i18n";
import { supabase } from "../lib/supabase";

type Student = { id: string; full_name: string; status: string; official_id: string | null; temporary_id: string | null };

export function StudentDetail() {
  const { id } = useParams();
  const [row, setRow] = useState<Student | null | undefined>(undefined);

  useEffect(() => {
    void supabase.from("students").select("id, full_name, status, official_id, temporary_id").eq("id", id ?? "").maybeSingle()
      .then(({ data }) => setRow((data as Student | null) ?? null));
  }, [id]);

  if (row === undefined) return <Loading />;
  if (row === null) return <NotFound />;
  return (
    <section data-testid="student-detail" className="rounded bg-white p-4 shadow-sm">
      <h1 className="mb-4 text-2xl font-semibold" data-testid="student-name">{row.full_name}</h1>
      <dl className="grid grid-cols-2 gap-2 text-sm">
        <dt className="text-slate-500">{t("students.status")}</dt><dd>{row.status}</dd>
        <dt className="text-slate-500">{t("students.officialId")}</dt><dd>{row.official_id ?? "—"}</dd>
        <dt className="text-slate-500">{t("students.temporaryId")}</dt><dd>{row.temporary_id ?? "—"}</dd>
      </dl>
      <Link to="/students" className="mt-4 inline-block text-emerald-700">{t("students.back")}</Link>
    </section>
  );
}
