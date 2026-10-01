// F3: قواعد الـhost — المتجهات المشتركة نفسها التي يختبر بها FastAPI و DB (docs/contracts/host_context_vectors.json)
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { getHostContext, getSchoolContext, getTenantContext } from "./appContext";
import { parseHost } from "./hostContext";

type Vectors = {
  hosts: { base: string; cases: [string, object | null][] };
  tenant_labels: { valid: string[]; invalid: string[] };
  school_slugs: { valid: string[]; invalid: string[] };
};
const vectors: Vectors = JSON.parse(readFileSync(join(__dirname, "../../../../docs/contracts/host_context_vectors.json"), "utf-8"));

describe("host rules (shared vectors)", () => {
  it.each(vectors.hosts.cases)("%s", (host, expected) => {
    expect(parseHost(host, vectors.hosts.base)).toEqual(expected);
  });

  it("tenant label rule: a label is a tenant host exactly when the DB accepts it", () => {
    const hostOk = (label: string) => parseHost(`${label}.localhost`, "localhost")?.kind === "tenant";
    expect(vectors.tenant_labels.valid.filter((l) => !hostOk(l))).toEqual([]);
    expect(vectors.tenant_labels.invalid.filter(hostOk)).toEqual([]);
  });

  it("school slug rule (M30b): a slug is a school host exactly when the DB accepts it", () => {
    const hostOk = (slug: string) => parseHost(`${slug}.dev.localhost`, "localhost")?.kind === "school";
    expect(vectors.school_slugs.valid.filter((s) => !hostOk(s))).toEqual([]);
    expect(vectors.school_slugs.invalid.filter(hostOk)).toEqual([]);
  });

  it("no base domain: nothing is recognised", () => {
    expect(parseHost("school-a.dev.localhost", "")).toBeNull();
  });
});

describe("app context from the page host (jsdom: school-a.dev.localhost)", () => {
  it("reads window.location.hostname — display/login only", () => {
    expect(getHostContext()).toEqual({ kind: "school", tenant: "dev", school: "school-a" });
    expect(getTenantContext()).toEqual({ label: "dev", source: "host" });
    expect(getSchoolContext()).toEqual({ slug: "school-a", source: "host" });
  });
});
