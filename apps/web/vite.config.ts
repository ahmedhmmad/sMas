/// <reference types="vitest/config" />
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: { port: 5173, strictPort: true },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test-setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    env: { VITE_SUPABASE_PUBLISHABLE_KEY: "test-only" },   // عميل Supabase يُنشأ عند الاستيراد؛ لا شبكة في هذه الاختبارات
  },
});
