-- WebKbc: chapter-list cache for the CBSE / NCERT quiz tab
-- Safe to run on an existing database. It does not touch your data.

create table if not exists public.curriculum_cache (
  cache_key text primary key,
  chapters jsonb not null check (jsonb_typeof(chapters) = 'array'),
  updated_at timestamptz not null default now()
);
alter table public.curriculum_cache enable row level security;
revoke all on public.curriculum_cache from anon, authenticated;

-- "Clear quiz cache" in Admin now also forgets the saved chapter lists.
create or replace function public.admin_clear_cache(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  delete from cached_quizzes where true;
  delete from curriculum_cache where true;
  return jsonb_build_object('ok', true);
end $$;
