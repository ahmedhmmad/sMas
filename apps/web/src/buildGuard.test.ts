// W2: أداة سياق التطوير لا تدخل بناء production إلا بتصريح تطوير صريح.
import { describe, expect, it } from "vitest";
import { assertDevContextAllowed } from "../build-guard";

describe("development context build guard", () => {
  it("a production build with the tool enabled fails", () => {
    expect(() => assertDevContextAllowed("build", { VITE_DEV_CONTEXT: "1" })).toThrow(/development-only/);
  });
  it("an explicit development-target build may include it (E2E)", () => {
    expect(() => assertDevContextAllowed("build", { VITE_DEV_CONTEXT: "1", SMAS_BUILD_TARGET: "development" })).not.toThrow();
  });
  it("the default build and the dev server are unaffected", () => {
    expect(() => assertDevContextAllowed("build", {})).not.toThrow();
    expect(() => assertDevContextAllowed("serve", { VITE_DEV_CONTEXT: "1" })).not.toThrow();
  });
});
