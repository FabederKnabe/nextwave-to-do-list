-- RLS-Policies für public.todo_data: alle authentifizierten User
-- dürfen die Shared-Row (id=1) lesen und ändern.
-- Idempotent: drop-if-exists + create.

alter table public.todo_data enable row level security;

drop policy if exists "todo_data_select_authenticated" on public.todo_data;
drop policy if exists "todo_data_update_authenticated" on public.todo_data;
drop policy if exists "todo_data_insert_authenticated" on public.todo_data;

create policy "todo_data_select_authenticated"
  on public.todo_data
  for select
  to authenticated
  using (true);

create policy "todo_data_update_authenticated"
  on public.todo_data
  for update
  to authenticated
  using (true)
  with check (true);

create policy "todo_data_insert_authenticated"
  on public.todo_data
  for insert
  to authenticated
  with check (true);
