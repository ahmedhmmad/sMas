// W2: بناء production يخلو من أداة سياق التطوير (يُشغَّل بعد `npm run build` الافتراضي في CI).
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = "dist/assets";
const hits = readdirSync(dir).filter((f) => f.endsWith(".js"))
  .filter((f) => /dev-context|smas\.dev\.school|smas\.dev\.tenant/.test(readFileSync(join(dir, f), "utf-8")));
if (hits.length) {
  console.error(`development context tool found in the production bundle: ${hits.join(", ")}`);
  process.exit(1);
}
console.log("production bundle: no development context tool");
