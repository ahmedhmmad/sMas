#!/usr/bin/env bash
# E6 — اختبار استعادة تقني: backup كامل ← قاعدة فارغة جديدة ← restore ← مقارنة بصمة ← (اختيارياً) الحزمة كاملة.
#
#   scripts/restore-test.sh [--run-tests]
#
# المصدر = قاعدة postgres المحلية كما هي الآن (يُجهَّز قبلها بـ `supabase db reset` أو `--no-seed`).
# الهدف  = قاعدة جديدة smas_restore في نفس الـcluster؛ تُحذف وتُنشأ من الـdump لا من migrations.
#
# لماذا لا يكفي pg_dump + createdb + pg_restore: pg_dump بلا --create لا يحمل خصائص القاعدة (المالك، ACL،
# ALTER DATABASE SET). ومالك القاعدة هو عضو pg_database_owner الذي يملك schema public؛ قاعدة يملكها
# supabase_admin تُسقط CREATE على public عن postgres (ظهر فعلاً: الحزمة فشلت على النسخة المستعادة).
# لذلك تُنشأ القاعدة ومصفوفة خصائصها من جمل الـdump نفسه (--create) باسم الهدف، ثم يُستعاد المحتوى.
#
# المتغيرات: CONTAINER_CLI (افتراضي docker؛ محلياً podman)، DB_CONTAINER (افتراضي supabase_db_SMas)،
#            TARGET_DB (افتراضي smas_restore)، DB_PORT (افتراضي 54322).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash على Windows يحوّل /tmp/... إلى مسار Windows قبل وصوله للحاوية

CLI=${CONTAINER_CLI:-docker}
CT=${DB_CONTAINER:-supabase_db_SMas}
TARGET=${TARGET_DB:-smas_restore}
PORT=${DB_PORT:-54322}
RUN_TESTS=0
[[ "${1:-}" == "--run-tests" ]] && RUN_TESTS=1

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

in_db() { "$CLI" exec -i "$CT" "$@"; }

echo "== 1. backup كامل (pg_dump -Fc --create) من postgres"
in_db pg_dump -U supabase_admin -d postgres -Fc --create -f /tmp/smas_e6.dump

echo "== 2. قاعدة فارغة جديدة: $TARGET — بإعدادات القاعدة الأصلية من الـdump"
# جمل مستوى القاعدة سطر واحد لكل منها في مخرج pg_restore --create؛ يُستبدل الاسم فقط
in_db pg_restore --create -s -f - /tmp/smas_e6.dump \
  | grep -E '^(CREATE DATABASE|ALTER DATABASE|COMMENT ON DATABASE) postgres |^(GRANT|REVOKE) .* ON DATABASE postgres ' \
  | sed -E "s/DATABASE postgres /DATABASE $TARGET /" > "$work/db.sql"
grep -q "^CREATE DATABASE $TARGET " "$work/db.sql" || { echo "لم يُعثر على CREATE DATABASE في الـdump"; exit 1; }
cat "$work/db.sql"
in_db dropdb -U supabase_admin --if-exists "$TARGET"
in_db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q < "$work/db.sql"

echo "== 3. restore المحتوى (معاملة واحدة، يتوقف عند أول خطأ)"
in_db pg_restore -U supabase_admin -d "$TARGET" --single-transaction --exit-on-error /tmp/smas_e6.dump
in_db rm -f /tmp/smas_e6.dump

echo "== 4. بصمة المصدر مقابل النسخة المستعادة"
for d in postgres "$TARGET"; do
  in_db psql -U supabase_admin -d "$d" -q < "$here/db-fingerprint.sql" > "$work/fp_$d.txt"
done
n=$(wc -l < "$work/fp_postgres.txt")
[[ "$n" -gt 0 ]] || { echo "البصمة فارغة — فشل الاستعلام"; exit 1; }
if ! diff "$work/fp_postgres.txt" "$work/fp_$TARGET.txt"; then
  echo "FAIL: النسخة المستعادة تختلف عن المصدر"; exit 1
fi
echo "بصمة متطابقة: $n سطراً"
grep -E '^[a-z_]+ [|] ' "$work/fp_postgres.txt" | cut -d'|' -f1 | sort | uniq -c

if [[ $RUN_TESTS == 1 ]]; then
  echo "== 5. الحزمة كاملة على النسخة المستعادة"
  npx supabase test db --db-url "postgresql://postgres:postgres@127.0.0.1:$PORT/$TARGET"
fi
echo "== PASS"
