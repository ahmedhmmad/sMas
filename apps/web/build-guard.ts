// W2 (F1): أداة سياق التطوير لا تدخل بناء production.
// VITE_DEV_CONTEXT=1 يُضمّنها — ويُرفض في `vite build` ما لم يُصرَّح بهدف تطوير (SMAS_BUILD_TARGET=development)،
// كبناء E2E في CI. البناء الافتراضي (production) يخلو منها ويفشل إن طُلبت.
export function assertDevContextAllowed(command: string, env: Record<string, string | undefined>): void {
  if (command === "build" && env.VITE_DEV_CONTEXT === "1" && env.SMAS_BUILD_TARGET !== "development") {
    throw new Error("VITE_DEV_CONTEXT=1 is development-only: set SMAS_BUILD_TARGET=development for a test build");
  }
}
