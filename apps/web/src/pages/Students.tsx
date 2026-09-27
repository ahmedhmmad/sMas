// الطلاب: ما تعيده RLS للجلسة — بلا مرشّح school_id من السياق (قيد 2). ولي الأمر يرى أبناءه والطالب نفسه
// بالبيانات نفسها. التصدير (student.export) عبر FastAPI لكل مدرسة مرئية؛ القرار في الخادم (P3).
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import { Loading } from "../components/states";
import { errorText, t } from "../i18n";
import { api, ApiError } from "../lib/api";
import { supabase } from "../lib/supabase";

type Student = { id: string; full_name: string; status: string };
type School = { id: string; name: string };

export function Students() {
  const { can, kind } = useAuth();
  const [rows, setRows] = useState<Student[] | null>(null);
  const [schools, setSchools] = useState<School[]>([]);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    void supabase.from("students").select("id, full_name, status").order("full_name")
      .then(({ data }) => setRows((data as Student[] | null) ?? []));
    if (can("student.export")) {
      void supabase.from("schools").select("id, name").order("name").then(({ data }) => setSchools((data as School[] | null) ?? []));
    }
  }, [can]);

  const exportSchool = async (school: School) => {
    setMessage(null);
    try {
      const body = await api<{ rows: Student[] }>(`/schools/${school.id}/students/export`);
      const url = URL.createObjectURL(new Blob([JSON.stringify(body.rows, null, 2)], { type: "application/json" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = `students-${school.id}.json`;
      a.click();
      URL.revokeObjectURL(url);
      setMessage(t("students.exported"));
    } catch (e) {
      setMessage(errorText(e instanceof ApiError ? e.code : "generic"));
    }
  };

  const title = kind === "guardian" ? "nav.myChildren" : kind === "student" ? "nav.myProfile" : "students.title";
  if (rows === null) return <Loading />;
  return (
    <section data-testid="students">
      <h1 className="mb-4 text-2xl font-semibold">{t(title)}</h1>
      {can("student.export") && schools.length > 0 && (
        <div className="mb-4 flex flex-wrap gap-2" data-testid="export-actions">
          {schools.map((s) => (
            <button key={s.id} type="button" data-testid={`export-${s.id}`} className="rounded border border-emerald-600 px-3 py-1 text-emerald-700"
              onClick={() => void exportSchool(s)}>
              {t("students.exportSchool")}: {s.name}
            </button>
          ))}
        </div>
      )}
      {message && <p role="status" data-testid="export-message" className="mb-4 text-slate-700">{message}</p>}
      {rows.length === 0 ? (
        <p data-testid="students-empty" className="text-slate-500">{t("students.empty")}</p>
      ) : (
        <table className="w-full rounded bg-white text-start shadow-sm">
          <thead>
            <tr className="border-b text-sm text-slate-500">
              <th className="p-2 text-start">{t("students.name")}</th>
              <th className="p-2 text-start">{t("students.status")}</th>
              <th className="p-2" />
            </tr>
          </thead>
          <tbody>
            {rows.map((s) => (
              <tr key={s.id} className="border-b" data-testid={`student-row-${s.id}`}>
                <td className="p-2">{s.full_name}</td>
                <td className="p-2">{s.status}</td>
                <td className="p-2">
                  <Link to={`/students/${s.id}`} className="text-emerald-700">{t("students.open")}</Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
