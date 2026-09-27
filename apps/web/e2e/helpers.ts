import { expect, type Page } from "@playwright/test";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const E2E_DIR = resolve(import.meta.dirname, "../../../.e2e");
export const DEV_PASSWORD = "DevOnly-Seed-2026";

type Fixtures = {
  schools: Record<"SA" | "SB" | "SS", string>;
  students: Record<"seed" | "sb" | "ss" | "fresh", { id: string; identifier?: string }>;
  guardians: Record<"A" | "B" | "C", { id: string; phone: string; temporary_password?: string }>;
};

export const fx = (): Fixtures => JSON.parse(readFileSync(resolve(E2E_DIR, "fixtures.json"), "utf-8"));

export function clearOtp(): void {
  writeFileSync(resolve(E2E_DIR, "otp.jsonl"), "");
}

export function otpsFor(contact: string): string[] {
  return readFileSync(resolve(E2E_DIR, "otp.jsonl"), "utf-8").split("\n").filter(Boolean)
    .map((l) => JSON.parse(l)).filter((m) => m.contact === contact).map((m) => m.code);
}

export async function readOtp(contact: string): Promise<string> {
  await expect.poll(() => otpsFor(contact).length, { timeout: 10_000 }).toBeGreaterThan(0);
  return otpsFor(contact).at(-1)!;
}

export async function setDevContext(page: Page, tenant: string, school: string): Promise<void> {
  await page.getByTestId("dev-context").locator("summary").click();
  await page.getByTestId("dev-tenant").fill(tenant);
  await page.getByTestId("dev-school").fill(school);
  await page.getByTestId("dev-apply").click();
}

export async function staffLogin(page: Page, email: string, password = DEV_PASSWORD, expectSuccess = true): Promise<void> {
  await page.goto("/login");
  await page.getByTestId("tab-staff").click();
  await page.getByTestId("staff-email").fill(email);
  await page.getByTestId("staff-password").fill(password);
  await page.getByTestId("staff-submit").click();
  if (expectSuccess) await expect(page.getByTestId("dashboard")).toBeVisible();   // الجلسة مخزَّنة قبل أي تنقل
}

export async function adminLogin(page: Page, email: string): Promise<void> {
  await page.goto("/login/admin");
  await page.getByTestId("admin-email").fill(email);
  await page.getByTestId("admin-password").fill(DEV_PASSWORD);
  await page.getByTestId("admin-submit").click();
  await expect(page.getByTestId("dashboard")).toBeVisible();
}

export async function changePassword(page: Page, password: string): Promise<void> {
  await expect(page.getByTestId("change-password")).toBeVisible();
  await page.getByTestId("new-password").fill(password);
  await page.getByTestId("confirm-password").fill(password);
  await page.getByTestId("password-submit").click();
  await expect(page.getByTestId("dashboard")).toBeVisible();
}

export async function studentRows(page: Page): Promise<string[]> {
  await page.goto("/students");
  const list = page.getByTestId("students");
  await expect(list).toBeVisible();
  return list.locator("[data-testid^='student-row-']").evaluateAll((els) => els.map((e) => e.getAttribute("data-testid")!.slice(12)));
}

export async function expectNotFound(page: Page, path: string): Promise<void> {
  await page.goto(path);
  await expect(page.getByTestId("state-not-found")).toBeVisible();
}
