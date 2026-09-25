-- M18 — policies_audit
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M18)، §7.5؛ docs/RLS_MODEL_v1.md §13 (F10، F11)؛ قرار H2
--
-- audit_log: SELECT فقط. لا INSERT/UPDATE/DELETE للعميل (T7 يكتب؛ T5 يرفض التعديل والحذف — M11).
--   (1) صف مدرسي: school_id ضمن النطاق
--   (2) كيان هوية مرئي للفاعل الآن — بالعلاقة الحالية (H2، M12b): طالب انتقل تنتقل رؤية تدقيق هويته معه
--   (3) صف tenant-level آخر: يلزم نطاق tenant (F10)
--   (4) Platform Admin: كيانات المنصة فقط، بصلاحية سياق Platform (F11، C3، G10)
-- (1)–(3) بـhas_permission('audit.read') في سياق Tenant؛ (4) سياسة منفصلة — لا OR بين السياقين في سياسة واحدة.
--
-- entity_id نص، ومفاتيح جداول الربط مركّبة ('a:b' — M11). Postgres لا يضمن ترتيب تقييم AND، فالتحويل إلى uuid
-- داخل CASE (الذي يضمن الترتيب) كي لا يُقيَّم على مفتاح مركّب.
--
-- SELECT على الجدول لـauthenticated: M20 (تبعية معتمدة عند إغلاق M11) — حتى ذلك الحين تُرفض القراءة بالصلاحية.
-- لا EXECUTE جديد: كل الدوال المستدعاة ممنوحة منذ M14/M17.
-- audit.sensitive_read: مؤجل حتى تُعرَّف قائمة الأحداث الحساسة مع جداول المرحلة 4 (§7.5).

create policy audit_log_tenant_select on public.audit_log
  for select to authenticated
  using (    app.has_permission('audit.read')
         and (   -- (1)
                 (school_id is not null and app.can_access_school(school_id))
                 -- (2)
              or (    platform_tenant_id = (select app.current_tenant_id())
                  and case entity_type
                        when 'students'  then app.student_in_scope(entity_id::uuid)
                        when 'guardians' then app.guardian_in_scope(entity_id::uuid)
                        when 'staff'     then app.staff_in_scope(entity_id::uuid)
                        when 'families'  then app.family_in_scope(entity_id::uuid)
                        else false
                      end)
                 -- (3)
              or (school_id is null and app.can_access_tenant(platform_tenant_id))));

create policy audit_log_platform_select on public.audit_log
  for select to authenticated
  using (    app.has_platform_permission('audit.read')
         and entity_type in ('platform_tenants', 'groups', 'schools', 'system_users',
                             'platform_admin_roles', 'platform_admin_assignments',
                             'platform_admin_role_permissions'));
