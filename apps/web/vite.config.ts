/// <reference types="vitest/config" />
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv } from "vite";
import { assertBaseDomain } from "./build-guard.ts";

export default defineConfig(({ command, mode }) => {
  assertBaseDomain(command, { ...loadEnv(mode, process.cwd(), ""), ...process.env });
  return {
  plugins: [react(), tailwindcss()],
  server: { port: 5173, strictPort: true },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test-setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    env: { VITE_SUPABASE_PUBLISHABLE_KEY: "test-only", VITE_BASE_DOMAIN: "localhost" },   // عميل Supabase يُنشأ عند الاستيراد؛ لا شبكة
    environmentOptions: { jsdom: { url: "http://school-a.dev.localhost:4173/" } },          // F3: host مدرسة افتراضياً
  },
  };
});
