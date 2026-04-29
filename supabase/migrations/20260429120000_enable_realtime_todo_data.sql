-- Enable Supabase Realtime for public.todo_data so that
-- postgres_changes events fire on INSERT/UPDATE/DELETE.
-- Required by Phase 5 (browser-to-browser sync).
--
-- Idempotent: skip if the table is already in the publication.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'todo_data'
  ) then
    alter publication supabase_realtime add table public.todo_data;
  end if;
end $$;
