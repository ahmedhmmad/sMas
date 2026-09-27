import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";
import noUiLiterals from "./eslint-rules/no-ui-literals.js";

export default tseslint.config(
  { ignores: ["dist", "playwright-report", "test-results"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: { globals: { ...globals.browser, ...globals.node } },
    plugins: { "react-hooks": reactHooks, smas: { rules: { "no-ui-literals": noUiLiterals } } },
    rules: {
      ...reactHooks.configs.recommended.rules,
      "smas/no-ui-literals": "error",
    },
  },
  { files: ["scripts/**/*.mjs", "eslint-rules/**/*.js"], languageOptions: { globals: globals.node } },
  // الاختبارات تحمل بيانات اختبار نصية
  { files: ["**/*.test.{ts,tsx}", "e2e/**"], rules: { "smas/no-ui-literals": "off" } },
);
