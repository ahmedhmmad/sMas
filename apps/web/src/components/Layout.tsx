import { type ReactNode, useState } from "react";
import { NavLink } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import { t } from "../i18n";
import { ContextLabel } from "./ContextLabel";
import { navItems } from "./navigation";

export function Layout({ children }: { children: ReactNode }) {
  const { capabilities, kind, logout } = useAuth();
  const [open, setOpen] = useState(false);
  const items = navItems(capabilities, kind);
  const nav = (
    <nav className="flex flex-col gap-1 p-4" data-testid="nav">
      {items.map((item) => (
        <NavLink
          key={item.to}
          to={item.to}
          end={item.to === "/"}
          data-testid={item.testId}
          onClick={() => setOpen(false)}
          className={({ isActive }) =>
            `rounded px-3 py-2 ${isActive ? "bg-emerald-600 text-white" : "text-slate-700 hover:bg-slate-100"}`
          }
        >
          {t(item.labelKey)}
        </NavLink>
      ))}
    </nav>
  );
  return (
    <div className="min-h-screen md:flex">
      <aside className="hidden w-60 shrink-0 border-e border-slate-200 bg-white md:block">{nav}</aside>
      {open && (
        <div className="fixed inset-0 z-20 bg-black/40 md:hidden" onClick={() => setOpen(false)}>
          <aside className="h-full w-64 bg-white" onClick={(e) => e.stopPropagation()}>
            <button type="button" className="m-4 text-slate-600" aria-label={t("app.closeMenu")} onClick={() => setOpen(false)}>
              ✕
            </button>
            {nav}
          </aside>
        </div>
      )}
      <div className="flex-1">
        <header className="flex items-center justify-between gap-4 border-b border-slate-200 bg-white px-4 py-3">
          <div className="flex items-center gap-3">
            <button type="button" className="md:hidden" aria-label={t("app.menu")} data-testid="menu-toggle" onClick={() => setOpen(true)}>
              ☰
            </button>
            <span className="font-semibold">{t("app.name")}</span>
          </div>
          <div className="flex items-center gap-4 text-sm text-slate-600">
            {capabilities.context === "tenant" && <ContextLabel testId="context-display" />}
            <button type="button" data-testid="logout" className="text-emerald-700" onClick={() => void logout()}>
              {t("app.logout")}
            </button>
          </div>
        </header>
        <main className="p-4 md:p-6">{children}</main>
      </div>
    </div>
  );
}
