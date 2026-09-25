-- M17b — staff_assignment_columns
-- المرجع: قرار 2026-09-25 (مراجعة M17)؛ docs/DB_IMPLEMENTATION_SPEC_v1.md §4.6؛ CLAUDE.md §1.1 بند 13؛ H2
--
-- staff_school_assignments.status و effective_to ليسا أعمدة يكتبها العميل.
--   بدون ذلك تستطيع مدرسة سابقة إعادة فتح تكليف منتهٍ بـUPDATE مباشر (status = 'active'، effective_to = NULL)
--   فتصبح staff_in_scope() صحيحة وتستعيد الوصول التشغيلي لموظف انتقل — خلاف H2.
--   RLS لا تقارن القيمة القديمة بالجديدة لعمود، فالمنع بصلاحية العمود.
--   تغييرات الحالة (إنهاء/إعادة فتح) عبر دوال انتقال حالة في M21 (auth.uid()، الصلاحية، سلطة النطاق،
--   FOR UPDATE، انتقالات صريحة، تدقيق).
--
-- تطبيق مبكر لسجل §4.6 على هذا الجدول وحده؛ M20 يطبّق السجل كاملاً على بقية الجداول.
-- سياسة UPDATE بلا تغيير (لا staff_in_scope فيها: التكليفات المتزامنة في عدة مدارس مشروعة).
-- INSERT بلا تغيير هنا: إنشاء تكليف جديد يمر بسياسة M17 (staff.assign + نطاق المدرسة).

revoke update on public.staff_school_assignments from authenticated;
grant  update (job_title, is_primary) on public.staff_school_assignments to authenticated;
