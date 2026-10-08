// F1.4 — عناصر القائمة من مفاتيح الصلاحيات. **الإخفاء عرض فقط**: الصفحة نفسها تقرأ ما تسمح به RLS/FastAPI،
// فالوصول اليدوي لمسار مخفي لا يمنح شيئاً.
import type { AccountKind } from "../auth/loginFlows";
import type { Capabilities } from "../auth/AuthProvider";

export type NavItem = { to: string; labelKey: string; testId: string };

export function navItems(caps: Capabilities, kind: AccountKind | null): NavItem[] {
  const items: NavItem[] = [{ to: "/", labelKey: "nav.dashboard", testId: "nav-dashboard" }];
  const has = (p: string) => caps.permissions.includes(p);
  // 3-4: القراءة «بالتكليف» (student.read_assigned) تفتح القائمة نفسها — RLS تعيد طلاب التكليف وحدهم.
  if (caps.context === "tenant" && (has("student.read") || has("student.read_assigned"))) {
    const labelKey = kind === "guardian" ? "nav.myChildren" : kind === "student" ? "nav.myProfile" : "nav.students";
    items.push({ to: "/students", labelKey, testId: "nav-students" });
  }
  // Phase 2A: إعداد المدارس — لمن يقرأ السنوات (الموظفون)؛ المجموعات لمن يقرأها. الإخفاء عرض، والقرار في الخادم.
  if (caps.context === "tenant" && has("school.read") && has("academic_year.read")) {
    items.push({ to: "/setup/schools", labelKey: "nav.schools", testId: "nav-schools" });
  }
  if (caps.context === "tenant" && has("group.read")) {
    items.push({ to: "/setup/groups", labelKey: "nav.groups", testId: "nav-groups" });
  }
  if (caps.context === "platform" && has("tenant.read")) {
    items.push({ to: "/platform/tenants", labelKey: "nav.tenants", testId: "nav-tenants" });
  }
  return items;
}
