// F3: البناء يشترط نطاقاً أساسياً صالحاً (build-guard.ts)
import { describe, expect, it } from "vitest";
import { assertBaseDomain } from "../build-guard";

describe("build guard (F3)", () => {
  it("a build without a base domain fails", () => {
    expect(() => assertBaseDomain("build", {})).toThrow(/VITE_BASE_DOMAIN/);
  });
  it.each(["*", "*.smas.example", "https://smas.example", "smas.example/", "SMAS.example", "127.0.0.1", ".smas.example", "smas..example"])(
    "an invalid base domain fails: %s",
    (base) => expect(() => assertBaseDomain("build", { VITE_BASE_DOMAIN: base })).toThrow(/VITE_BASE_DOMAIN/),
  );
  it.each(["smas.example", "localhost", "app.smas-school.example"])("a valid base domain builds: %s", (base) => {
    expect(() => assertBaseDomain("build", { VITE_BASE_DOMAIN: base })).not.toThrow();
  });
  it("the dev server needs no base domain (defaults to localhost)", () => {
    expect(() => assertBaseDomain("serve", {})).not.toThrow();
  });
});
