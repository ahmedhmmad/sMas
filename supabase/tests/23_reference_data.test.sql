-- M23 — reference_data: كشف الانحراف بين قاعدة البيانات و ROLE_PERMISSION_SEED_v1.md (B8 §8.2)
-- القيم المتوقعة هنا مولّدة من الوثيقة نفسها (Matrix §4 للكتالوج، seed §4 للخرائط، §6 لـplatform_admin).
-- أي اختلاف — مفتاح زائد أو ناقص، أو دور بصلاحية مختلفة — يُفشل CI.
begin;

create temp table exp_catalog (code text primary key) on commit drop;
insert into exp_catalog values ('academic_year.activate'), ('academic_year.close'), ('academic_year.create'), ('academic_year.export'), ('academic_year.read'), ('academic_year.update'), ('audit.read'), ('audit.sensitive_read'), ('enrollment.archive'), ('enrollment.create'), ('enrollment.export'), ('enrollment.read'), ('enrollment.transfer'), ('enrollment.update'), ('family.read'), ('family.update'), ('grade_level.manage'), ('grade_level.read'), ('group.archive'), ('group.create'), ('group.export'), ('group.read'), ('group.update'), ('guardian.create'), ('guardian.export'), ('guardian.link'), ('guardian.read'), ('guardian.sensitive_read'), ('guardian.unlink'), ('guardian.update'), ('membership.create'), ('membership.end'), ('membership.read'), ('membership.update'), ('permission.read'), ('profile.read'), ('profile.update'), ('role.assign'), ('role.create'), ('role.read'), ('role.update'), ('school.archive'), ('school.create'), ('school.export'), ('school.read'), ('school.update'), ('scope.assign'), ('section.manage'), ('section.read'), ('security.export'), ('security.manage'), ('staff.archive'), ('staff.assign'), ('staff.create'), ('staff.export'), ('staff.read'), ('staff.update'), ('stage.manage'), ('stage.read'), ('student.archive'), ('student.create'), ('student.export'), ('student.read'), ('student.sensitive_read'), ('student.transfer'), ('student.update'), ('tenant.create'), ('tenant.export'), ('tenant.read'), ('tenant.suspend'), ('tenant.update'), ('term.manage'), ('term.read');

create temp table exp_roles (code text primary key, perms text, n int) on commit drop;
insert into exp_roles values
  ('tenant_admin', 'academic_year.activate,academic_year.close,academic_year.create,academic_year.export,academic_year.read,academic_year.update,audit.read,audit.sensitive_read,enrollment.archive,enrollment.create,enrollment.export,enrollment.read,enrollment.transfer,enrollment.update,family.read,family.update,grade_level.manage,grade_level.read,group.archive,group.create,group.export,group.read,group.update,guardian.create,guardian.export,guardian.link,guardian.read,guardian.sensitive_read,guardian.unlink,guardian.update,membership.create,membership.end,membership.read,membership.update,permission.read,profile.read,profile.update,role.assign,role.create,role.read,role.update,school.archive,school.create,school.export,school.read,school.update,scope.assign,section.manage,section.read,security.export,security.manage,staff.archive,staff.assign,staff.create,staff.export,staff.read,staff.update,stage.manage,stage.read,student.archive,student.create,student.export,student.read,student.sensitive_read,student.transfer,student.update,tenant.export,tenant.read,tenant.update,term.manage,term.read', 71),
  ('group_manager', 'academic_year.activate,academic_year.close,academic_year.create,academic_year.export,academic_year.read,academic_year.update,audit.read,audit.sensitive_read,enrollment.archive,enrollment.create,enrollment.export,enrollment.read,enrollment.transfer,enrollment.update,family.read,family.update,grade_level.manage,grade_level.read,group.export,group.read,group.update,guardian.create,guardian.export,guardian.link,guardian.read,guardian.sensitive_read,guardian.unlink,guardian.update,membership.create,membership.end,membership.read,membership.update,permission.read,profile.read,profile.update,role.assign,role.read,school.archive,school.create,school.export,school.read,school.update,scope.assign,section.manage,section.read,staff.archive,staff.assign,staff.create,staff.export,staff.read,staff.update,stage.manage,stage.read,student.archive,student.create,student.export,student.read,student.sensitive_read,student.transfer,student.update,term.manage,term.read', 62),
  ('school_admin', 'academic_year.activate,academic_year.close,academic_year.create,academic_year.export,academic_year.read,academic_year.update,audit.read,audit.sensitive_read,enrollment.archive,enrollment.create,enrollment.export,enrollment.read,enrollment.transfer,enrollment.update,family.read,family.update,grade_level.manage,grade_level.read,guardian.create,guardian.export,guardian.link,guardian.read,guardian.sensitive_read,guardian.unlink,guardian.update,membership.create,membership.end,membership.read,membership.update,permission.read,profile.read,profile.update,role.assign,role.read,school.export,school.read,school.update,scope.assign,section.manage,section.read,security.export,security.manage,staff.archive,staff.assign,staff.create,staff.export,staff.read,staff.update,stage.manage,stage.read,student.archive,student.create,student.export,student.read,student.sensitive_read,student.transfer,student.update,term.manage,term.read', 59),
  ('secretary', 'academic_year.read,enrollment.create,enrollment.read,enrollment.update,family.read,family.update,grade_level.read,guardian.create,guardian.link,guardian.read,guardian.update,profile.read,school.read,section.read,stage.read,student.create,student.read,student.update,term.read', 19),
  ('accountant', 'academic_year.read,audit.read,enrollment.read,family.read,grade_level.read,guardian.read,profile.read,school.read,section.read,staff.read,student.read', 11),
  ('teacher', 'academic_year.read,enrollment.read,family.read,grade_level.read,guardian.read,profile.read,school.read,section.read,staff.read,student.read,term.read', 11),
  ('counselor', 'academic_year.read,enrollment.read,family.read,grade_level.read,guardian.read,profile.read,school.read,section.read,student.read,student.sensitive_read', 10),
  ('bus_supervisor', 'profile.read,school.read', 2),
  ('guardian', 'enrollment.read,family.read,guardian.read,profile.read,school.read,student.read', 6),
  ('student', 'enrollment.read,profile.read,school.read,student.read', 4);

create temp table exp_cover (grantor text primary key, grantees text) on commit drop;
insert into exp_cover values
  ('tenant_admin', 'accountant,bus_supervisor,counselor,group_manager,guardian,school_admin,secretary,student,teacher'),
  ('group_manager', 'accountant,bus_supervisor,counselor,guardian,secretary,student,teacher'),
  ('school_admin', 'accountant,bus_supervisor,counselor,guardian,secretary,student,teacher'),
  ('secretary', 'bus_supervisor,guardian,student'),
  ('accountant', 'bus_supervisor,guardian,student'),
  ('teacher', 'bus_supervisor,guardian,student'),
  ('counselor', 'bus_supervisor,guardian,student'),
  ('bus_supervisor', ''),
  ('guardian', 'bus_supervisor,student'),
  ('student', 'bus_supervisor');

select plan(35);

-- ---------- الكتالوج ----------
select set_eq('select code from public.permissions', 'select code from exp_catalog', 'catalog: exactly the 73 frozen keys (K1–K4) — none missing, none extra');
select is((select count(*)::int from public.permissions), 73, 'catalog: 73 rows');
select is((select count(*)::int from public.permissions
            where code !~ '^[a-z][a-z0-9_]*\.(read|sensitive_read|create|update|archive|export|approve|enter|assign|link|unlink|transfer|activate|close|suspend|end|manage)$'), 0,
          'naming: every key uses the frozen operation set (§2.1) — no delete');
select is((select count(*)::int from public.permissions where split_part(code, '.', 1) in
            ('attendance','grade','admission','fee','payment','discount','receipt','homework','report')), 0,
          'reserved keys for later phases are not seeded (§2.2)');

-- ---------- الأدوار ----------
select is((select string_agg(code, ',' order by code) from public.roles where platform_tenant_id is null), 'accountant,bus_supervisor,counselor,group_manager,guardian,school_admin,secretary,student,teacher,tenant_admin',
          'exactly the 10 system roles (§3)');
select is(coalesce((select string_agg(p.code, ',' order by p.code) from public.role_permissions rp
                    join public.permissions p on p.id = rp.permission_id join public.roles r on r.id = rp.role_id
                    where r.code = e.code and r.platform_tenant_id is null), '') || ' #' ||
          (select count(*) from public.role_permissions rp join public.roles r on r.id = rp.role_id where r.code = e.code and r.platform_tenant_id is null),
          e.perms || ' #' || e.n,
          format('%s: exactly its §4 permissions (%s)', e.code, e.n))
  from exp_roles e order by e.code;
select ok((select bool_and(is_system and status = 'active') from public.roles where platform_tenant_id is null), 'system roles: is_system and active');
select is((select count(*)::int from public.role_permissions), 255, 'role_permissions: 255 links in total');

-- ---------- K3/K4 و E5 ----------
select is((select count(*)::int from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
            where p.code in ('tenant.suspend','tenant.create')), 0, 'E5/K3/K4: no tenant role holds tenant.suspend or tenant.create');

-- ---------- platform_admin (§6) ----------
select is((select string_agg(p.code, ',' order by p.code) from public.platform_admin_role_permissions x
            join public.platform_admin_roles r on r.id = x.platform_admin_role_id join public.permissions p on p.id = x.permission_id
            where r.code = 'platform_admin'), 'audit.read,group.create,group.read,school.create,school.read,tenant.create,tenant.read,tenant.suspend,tenant.update',
          'platform_admin: exactly its nine permissions — no student/guardian/staff/export (C3)');
select is((select count(*)::int from public.platform_admin_roles), 1, 'platform_admin_roles: one seeded role');

-- ---------- is_sensitive ----------
select is((select string_agg(code, ',' order by code) from public.permissions where is_sensitive), 'academic_year.export,audit.sensitive_read,enrollment.export,group.export,guardian.export,guardian.sensitive_read,school.export,security.export,staff.export,student.export,student.sensitive_read,tenant.export',
          'is_sensitive: exactly the sensitive_read and export keys (audit on use)');

-- ---------- T8 على الأدوار المبذورة: من يستطيع إسناد من ----------
select is(coalesce((select string_agg(t.code, ',' order by t.code) from public.roles t
                    where t.platform_tenant_id is null and t.code <> g.grantor
                      and not exists (select 1 from public.role_permissions rt
                                      where rt.role_id = t.id
                                        and rt.permission_id not in (select rg.permission_id from public.role_permissions rg
                                                                     join public.roles gr on gr.id = rg.role_id
                                                                     where gr.code = g.grantor and gr.platform_tenant_id is null))), ''),
          g.grantees, format('T8 cover: %s can assign exactly {%s}', g.grantor, g.grantees))
  from exp_cover g order by g.grantor;

-- ---------- ما تفترضه M22 ----------
select is((select count(*)::int from unnest(array['tenant_admin','student','guardian']) c
            join public.roles r on r.code = c and r.is_system and r.platform_tenant_id is null), 3,
          'M22: the system roles it assigns by code exist (tenant_admin, student, guardian)');
select ok((select bool_and(p.code in (select p2.code from public.role_permissions rp2 join public.permissions p2 on p2.id = rp2.permission_id
                                      join public.roles r2 on r2.id = rp2.role_id where r2.code = 'secretary'))
           from public.role_permissions rp join public.permissions p on p.id = rp.permission_id join public.roles r on r.id = rp.role_id
           where r.code in ('student','guardian')),
          'M22 + T8: a secretary holds every permission of the student and guardian roles (it can provision students)');
select ok((select bool_and(exists (select 1 from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
                                   join public.roles r on r.id = rp.role_id where r.code = 'secretary' and p.code = k))
           from unnest(array['student.create','enrollment.create','guardian.create','guardian.link']) k),
          'M22: secretary can call provision_student and provision_guardian');

-- مَن يستطيع استدعاء دوال الإنشاء بصلاحياته (موثّق — لا قرار جديد)
create temp view can_call as
  select f, string_agg(r.code, ',' order by r.code) as roles
  from (values ('provision_student', array['student.create','enrollment.create']),
               ('provision_staff',   array['staff.create','staff.assign']),
               ('provision_guardian',array['guardian.create','guardian.link']),
               ('provision_account', array['membership.create'])) v(f, needs)
  join public.roles r on r.platform_tenant_id is null
  where not exists (select 1 from unnest(v.needs) k
                    where not exists (select 1 from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
                                      where rp.role_id = r.id and p.code = k))
  group by f;
select is((select string_agg(f || '=' || roles, ' ; ' order by f) from can_call),
          'provision_account=group_manager,school_admin,tenant_admin ; provision_guardian=group_manager,school_admin,secretary,tenant_admin ; provision_staff=group_manager,school_admin,tenant_admin ; provision_student=group_manager,school_admin,secretary,tenant_admin',
          'which seeded roles can call each provisioning function (documented)');

select * from finish();
rollback;
