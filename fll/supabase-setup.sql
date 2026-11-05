-- FLL Pit Crew: shared storage for a teacher's group.
-- Run this once in Supabase: SQL Editor -> New query -> paste everything -> Run.
-- It only creates FLL Pit Crew's own tables and rules. Running it again is safe.

-- Groups: one per class or team. The teacher's account owns it.
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  code text unique not null default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)),
  name text not null check (char_length(name) between 1 and 40),
  teacher uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Members: who is in which group, and as what.
create table if not exists public.members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  nick text not null check (char_length(nick) between 1 and 20),
  role text not null check (role in ('teacher', 'computer', 'student')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- Items: runs, plans, checklist lines, project notes, homework, announcements,
-- "done" ticks and questions. Nothing is ever hard-deleted, only marked deleted.
create table if not exists public.items (
  group_id uuid not null references public.groups(id) on delete cascade,
  kind text not null check (kind in ('run', 'plan', 'check', 'project', 'settings', 'hw', 'ann', 'done', 'q')),
  id text not null check (char_length(id) between 1 and 80),
  data jsonb not null default '{}'::jsonb check (pg_column_size(data) < 20000),
  deleted boolean not null default false,
  updated_by uuid not null default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (group_id, kind, id)
);
create index if not exists items_group_updated on public.items (group_id, updated_at);

-- Your role in a group, or null if you're not in it.
create or replace function public.my_role(g uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where group_id = g and user_id = auth.uid()
$$;

-- What each role may write.
--   teacher:  everything
--   computer: runs, plans, checklist, project notes, match settings
--   student:  their own "done" ticks, and new questions
create or replace function public.can_write(g uuid, k text, item_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select case public.my_role(g)
    when 'teacher' then true
    when 'computer' then k in ('run', 'plan', 'check', 'project', 'settings')
    when 'student' then (k = 'done' and item_id like '%|' || auth.uid()::text) or k = 'q'
    else false
  end
$$;

-- Joining with the group code. Only the group's own teacher account becomes a teacher.
create or replace function public.join_group(join_code text, nickname text, wanted text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  r text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into g from public.groups where code = upper(trim(join_code));
  if not found then raise exception 'no group with that code'; end if;
  if g.teacher = auth.uid() then r := 'teacher';
  elsif wanted = 'computer' then r := 'computer';
  else r := 'student';
  end if;
  insert into public.members (group_id, user_id, nick, role)
    values (g.id, auth.uid(), left(coalesce(nullif(trim(nickname), ''), 'Someone'), 20), r)
    on conflict (group_id, user_id) do update set nick = excluded.nick, role = excluded.role;
  return g.id;
end
$$;

-- The teacher is a member of their own group from the start.
create or replace function public.add_teacher() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.members (group_id, user_id, nick, role)
    values (new.id, new.teacher, 'Teacher', 'teacher')
    on conflict (group_id, user_id) do update set role = 'teacher';
  return new;
end
$$;
drop trigger if exists groups_add_teacher on public.groups;
create trigger groups_add_teacher after insert on public.groups
  for each row execute function public.add_teacher();

-- Row level security: these rules are checked by the database for every request.
alter table public.groups enable row level security;
alter table public.members enable row level security;
alter table public.items enable row level security;

drop policy if exists groups_read on public.groups;
drop policy if exists groups_create on public.groups;
drop policy if exists groups_rename on public.groups;
-- The teacher can always see their own groups (needed the moment a group is created).
create policy groups_read on public.groups for select
  using (teacher = auth.uid() or public.my_role(id) is not null);
-- Only real (not anonymous) accounts can start a group, and only for themselves.
create policy groups_create on public.groups for insert
  with check (teacher = auth.uid() and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false));
create policy groups_rename on public.groups for update
  using (teacher = auth.uid()) with check (teacher = auth.uid());

drop policy if exists members_read on public.members;
drop policy if exists members_leave on public.members;
create policy members_read on public.members for select
  using (public.my_role(group_id) is not null);
-- Anyone can leave; the teacher can remove people.
create policy members_leave on public.members for delete
  using (user_id = auth.uid() or public.my_role(group_id) = 'teacher');

drop policy if exists items_read on public.items;
drop policy if exists items_insert on public.items;
drop policy if exists items_update on public.items;
create policy items_read on public.items for select
  using (public.my_role(group_id) is not null);
-- A student's question must be their own and can't come with an answer.
create policy items_insert on public.items for insert
  with check (
    public.can_write(group_id, kind, id) and updated_by = auth.uid()
    and not (public.my_role(group_id) = 'student' and kind = 'q'
             and ((data ->> 'uid') is distinct from auth.uid()::text or data ? 'ans'))
  );
-- Students can change their own "done" ticks but not questions; teachers answer them.
create policy items_update on public.items for update
  using (public.can_write(group_id, kind, id) and not (public.my_role(group_id) = 'student' and kind = 'q'))
  with check (public.can_write(group_id, kind, id) and updated_by = auth.uid());

-- Let signed-in users (including anonymous student devices) use these tables through the API.
grant usage on schema public to anon, authenticated;
grant select, insert, update on public.groups to authenticated;
grant select, delete on public.members to authenticated;
grant select, insert, update on public.items to authenticated;
grant execute on function public.join_group(text, text, text) to authenticated;
grant execute on function public.my_role(uuid) to authenticated;
grant execute on function public.can_write(uuid, text, text) to authenticated;
revoke all on public.groups, public.members, public.items from anon;
