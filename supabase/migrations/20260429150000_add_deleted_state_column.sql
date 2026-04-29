-- Fehlende Spalte deleted_state ergänzen.
-- loadData() und saveField('deleted') in index.html erwarten diese Spalte
-- analog zu done_state, prio_state, manual_entries.
-- Idempotent: add column if not exists.

alter table public.todo_data
  add column if not exists deleted_state jsonb not null default '{}'::jsonb;
