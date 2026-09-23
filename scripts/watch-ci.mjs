// يتابع آخر تشغيل CI على GitHub حتى ينتهي، ويطبع نتيجة كل خطوة (مستودع عام: بلا مصادقة).
// الاستعمال: node scripts/watch-ci.mjs [owner/repo] [sha]
const repo = process.argv[2] ?? "ahmedhmmad/sMas";
const sha = process.argv[3];
const api = (p) =>
  fetch(`https://api.github.com/repos/${repo}${p}`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => r.json());

for (let i = 0; i < 90; i++) {
  const { workflow_runs: runs = [] } = await api(`/actions/runs?per_page=5`);
  const run = runs.find((r) => !sha || r.head_sha.startsWith(sha));
  if (run && run.status === "completed") {
    console.log(`run ${run.id}: ${run.conclusion}  ${run.html_url}`);
    const { jobs = [] } = await api(`/actions/runs/${run.id}/jobs`);
    for (const job of jobs) {
      console.log(`job "${job.name}": ${job.conclusion}`);
      for (const s of job.steps ?? []) console.log(`  ${s.conclusion === "success" ? "✓" : s.conclusion === "skipped" ? "-" : "✗"} ${s.name}  (${s.conclusion})`);
    }
    process.exit(run.conclusion === "success" ? 0 : 1);
  }
  await new Promise((r) => setTimeout(r, 20000));
}
console.log("timeout: run did not complete in 30 minutes");
process.exit(2);
