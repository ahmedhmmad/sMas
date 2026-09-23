# SMas — نظام إدارة المدارس متعدد المستأجرين

وثائق التصميم في [`docs/`](docs/)، وحالة التنفيذ وقواعد العمل في [`CLAUDE.md`](CLAUDE.md).

| المسار | المحتوى | يُملأ في |
|---|---|---|
| `supabase/` | migrations، اختبارات pgTAP، seed | Gate C–E |
| `apps/web/` | React + TS + Vite + Tailwind (RTL) | Gate F |
| `services/api/` | FastAPI | Gate F |
| `apps/mobile/` | Flutter | المرحلة 12 |
| `n8n/` | تصدير الـworkflows | المرحلة 5 |
| `spikes/m00/` | تحقق Gate I من افتراضات Postgres/Supabase — **ليست migrations** | Gate I |

## التشغيل المحلي

يتطلب Docker Desktop و Node 20+.

```bash
npm install
npm run db:start     # Supabase محلي
npm run db:test      # اختبارات pgTAP
npm run check:secrets
```
