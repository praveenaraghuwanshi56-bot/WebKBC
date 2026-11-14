-- WebKbc: Supabase schema (v2)
-- Run the whole file in Supabase Dashboard > SQL Editor.
-- It replaces the v1 tables. Browsers never touch tables directly: every table is locked
-- and all reads/writes go through the functions below, which check the session token.

create extension if not exists pgcrypto with schema extensions;

drop table if exists public.leaderboards, public.cached_quizzes, public.profiles cascade;

-- ---------- Tables ----------
create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  username text not null check (username ~ '^[A-Za-z0-9_]{3,16}$'),
  pw_hash text not null,
  is_admin boolean not null default false,
  avatar_letter text,
  avatar_color text,
  fail_count int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists app_users_name on public.app_users (lower(username));

create table if not exists public.app_sessions (
  token text primary key,
  user_id uuid not null references public.app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);
create index if not exists app_sessions_user on public.app_sessions (user_id);

-- One row. The master Gemini key lives here and is only readable by the edge function.
create table if not exists public.app_settings (
  id int primary key check (id = 1),
  gemini_key text,
  model text not null default 'gemini-3.8-flash',
  daily_cap int not null default 1000,
  hourly_cap int not null default 12,
  cache_sets int not null default 6,
  tts jsonb not null default
    '{"enabled":true,"auto":true,"lang":"en-IN","voice":"","rate":0.95,"pitch":1,"volume":1,"pause_ms":500,"labels":true,"announce":true,"extra_secs":12}'::jsonb
);
insert into public.app_settings (id) values (1) on conflict do nothing;

-- Full questions WITH answers stay here. The browser only ever gets question text and options.
create table if not exists public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_users(id) on delete cascade,
  mode text not null check (mode in ('kbc','study')),
  class_level text not null,
  questions jsonb not null,
  lvl int not null default 0,
  used jsonb not null default '{}'::jsonb,
  hidden jsonb not null default '[]'::jsonb,
  status text not null default 'active' check (status in ('active','finished')),
  score bigint not null default 0,
  reached int not null default 0,
  ready boolean not null default false,
  difficulty text not null default 'easy' check (difficulty in ('easy','medium','hard')),
  q_started_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists game_sessions_user on public.game_sessions (user_id, created_at desc);

-- Rows are written only by the server when a game ends. One row per finished game.
create table if not exists public.leaderboards (
  id bigint generated always as identity primary key,
  game_id uuid not null unique references public.game_sessions(id) on delete cascade,
  user_id uuid not null references public.app_users(id) on delete cascade,
  class_level text not null,
  difficulty text not null default 'easy' check (difficulty in ('easy','medium','hard')),
  score bigint not null check (score between 0 and 10000000),
  reached int not null,
  created_at timestamptz not null default now()
);
create index if not exists leaderboards_rank on public.leaderboards (class_level, score desc);

create table if not exists public.cached_quizzes (
  id bigint generated always as identity primary key,
  cache_key text not null,
  class_level text,
  questions jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists cached_quizzes_key on public.cached_quizzes (cache_key);

create table if not exists public.curriculum_cache (
  cache_key text primary key,
  chapters jsonb not null check (jsonb_typeof(chapters) = 'array'),
  updated_at timestamptz not null default now()
);
create table if not exists public.api_logs (
  id bigint generated always as identity primary key,
  user_id uuid references public.app_users(id) on delete set null,
  kind text,
  class_level text,
  status int,
  ms int,
  tokens_in int,
  tokens_out int,
  cache_hit boolean not null default false,
  error text,
  request text,
  response text,
  created_at timestamptz not null default now()
);
create index if not exists api_logs_time on public.api_logs (created_at desc);

alter table public.app_users enable row level security;
alter table public.app_sessions enable row level security;
alter table public.app_settings enable row level security;
alter table public.game_sessions enable row level security;
alter table public.leaderboards enable row level security;
alter table public.cached_quizzes enable row level security;
alter table public.curriculum_cache enable row level security;
alter table public.api_logs enable row level security;
revoke all on all tables in schema public from anon, authenticated;
-- (no RLS policies on purpose: the anon key cannot read or write any table)

-- ---------- Internal helpers ----------
create or replace function public._uid(p_tok text) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select user_id from app_sessions where token = p_tok and expires_at > now() limit 1
$$;

create or replace function public._is_admin(p_tok text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select u.is_admin from app_sessions s join app_users u on u.id = s.user_id
                   where s.token = p_tok and s.expires_at > now() limit 1), false)
$$;

create or replace function public._ladder() returns bigint[]
language sql immutable as $$
  select array[1000,2000,3000,5000,10000,20000,40000,80000,160000,320000,640000,1250000,2500000,5000000,10000000]::bigint[]
$$;

-- Money kept when you miss question index p_lvl (0-based): safe havens after Level 5 and Level 10.
create or replace function public._safe(p_lvl int) returns bigint
language sql immutable as $$
  select (case when p_lvl > 9 then 320000 when p_lvl > 4 then 10000 else 0 end)::bigint
$$;

create or replace function public._finish(p_gid uuid, p_score bigint, p_reached int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g record;
begin
  update game_sessions set status = 'finished', score = p_score, reached = p_reached, finished_at = now()
   where id = p_gid and status = 'active' returning * into g;
  if found and g.mode = 'kbc' and p_score > 0 then
    insert into leaderboards (game_id, user_id, class_level, difficulty, score, reached)
    values (g.id, g.user_id, g.class_level, g.difficulty, p_score, p_reached) on conflict do nothing;
  end if;
end $$;

create or replace function public._diff_rank(p_diff text) returns int
language sql immutable as $$
  select case p_diff when 'hard' then 3 when 'medium' then 2 else 1 end
$$;

create or replace function public._user_json(r app_users, p_token text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', true, 'token', p_token, 'username', r.username, 'is_admin', r.is_admin,
                            'avatar_letter', r.avatar_letter, 'avatar_color', r.avatar_color)
$$;

-- ---------- Accounts ----------
create or replace function public.signup(p_user text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r app_users; t text; n text := trim(coalesce(p_user, ''));
begin
  if n !~ '^[A-Za-z0-9_]{3,16}$' then return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  if length(coalesce(p_pw, '')) < 6 or length(p_pw) > 72 then return jsonb_build_object('ok', false, 'error', 'bad_password'); end if;
  if exists (select 1 from app_users where lower(username) = lower(n)) then return jsonb_build_object('ok', false, 'error', 'taken'); end if;
  insert into app_users (username, pw_hash) values (n, crypt(p_pw, gen_salt('bf', 10))) returning * into r;
  t := encode(gen_random_bytes(24), 'hex');
  insert into app_sessions (token, user_id) values (t, r.id);
  return _user_json(r, t);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'taken');
end $$;

-- One device at a time: signing in ends every other session. 5 wrong passwords lock the account for 15 minutes.
create or replace function public.login(p_user text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r app_users; t text;
begin
  select * into r from app_users where lower(username) = lower(trim(coalesce(p_user, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'wrong'); end if;
  if r.locked_until is not null and r.locked_until > now() then return jsonb_build_object('ok', false, 'error', 'locked'); end if;
  if r.pw_hash <> crypt(coalesce(p_pw, ''), r.pw_hash) then
    update app_users
       set fail_count = case when fail_count + 1 >= 5 then 0 else fail_count + 1 end,
           locked_until = case when fail_count + 1 >= 5 then now() + interval '15 minutes' else locked_until end
     where id = r.id;
    return jsonb_build_object('ok', false, 'error', 'wrong');
  end if;
  update app_users set fail_count = 0, locked_until = null where id = r.id;
  delete from app_sessions where user_id = r.id;
  t := encode(gen_random_bytes(24), 'hex');
  insert into app_sessions (token, user_id) values (t, r.id);
  return _user_json(r, t);
end $$;

create or replace function public.check_session(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r app_users;
begin
  select u.* into r from app_sessions s join app_users u on u.id = s.user_id
   where s.token = p_tok and s.expires_at > now();
  if not found then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  return _user_json(r, p_tok);
end $$;

create or replace function public.logout(p_tok text) returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  with d as (delete from app_sessions where token = p_tok returning 1) select jsonb_build_object('ok', true)
$$;

create or replace function public.change_password(p_tok text, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare uid uuid := _uid(p_tok); r app_users;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into r from app_users where id = uid;
  if r.pw_hash <> crypt(coalesce(p_old, ''), r.pw_hash) then return jsonb_build_object('ok', false, 'error', 'wrong'); end if;
  if length(coalesce(p_new, '')) < 6 or length(p_new) > 72 then return jsonb_build_object('ok', false, 'error', 'bad_password'); end if;
  update app_users set pw_hash = crypt(p_new, gen_salt('bf', 10)) where id = uid;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Games (the server decides what is correct and what you win) ----------
-- Called only by the edge function (service role): stores the full questions, returns them without answers.
create or replace function public.create_game(p_tok text, p_mode text, p_cls text, p_questions jsonb, p_difficulty text default 'easy') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); g record; need int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  need := case p_mode when 'kbc' then 15 when 'study' then 10 else 0 end;
  if need = 0 or jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) <> need then
    return jsonb_build_object('ok', false, 'error', 'bad_questions');
  end if;
  if (select count(*) from game_sessions where user_id = uid and created_at > now() - interval '1 hour') >= 40 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  for g in select * from game_sessions where user_id = uid and status = 'active' for update loop
    perform _finish(g.id, case when g.mode = 'kbc' then _safe(g.lvl) else 0 end, g.lvl + 1);
  end loop;
  insert into game_sessions (user_id, mode, class_level, questions, difficulty)
  values (uid, p_mode, p_cls, p_questions, case when p_difficulty in ('easy','medium','hard') then p_difficulty else 'easy' end) returning * into g;
  return jsonb_build_object('ok', true, 'gid', g.id, 'questions',
    (select jsonb_agg(jsonb_build_object('q', e.v->'q', 'options', e.v->'options') order by e.ord)
       from jsonb_array_elements(p_questions) with ordinality as e(v, ord)));
end $$;

-- The question's clock starts when the player can SEE it, not when the previous answer was saved.
-- (Locking an answer adds a 2-5 second suspense pause plus the reveal, which must not eat into the next question's time.)
-- The browser calls kbc_ready when a question appears. It only counts once, and only within 15 s of the
-- previous answer, so it cannot be used to stall for long. If it is never called, the older (stricter) start time applies.
create or replace function public.kbc_ready(p_tok text, p_gid uuid, p_lvl int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok);
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  update game_sessions set q_started_at = now(), ready = true
   where id = p_gid and user_id = uid and mode = 'kbc' and status = 'active'
     and lvl = p_lvl and not ready and now() - q_started_at <= interval '15 seconds';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.kbc_answer(p_tok text, p_gid uuid, p_lvl int, p_choice int, p_extra int default 0) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); g game_sessions; q jsonb; ans int; lim int; ex int; timed_out boolean; ok boolean; sc bigint;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into g from game_sessions where id = p_gid and user_id = uid and mode = 'kbc' for update;
  if not found or g.status <> 'active' then return jsonb_build_object('ok', false, 'error', 'no_game'); end if;
  if p_lvl <> g.lvl then return jsonb_build_object('ok', false, 'error', 'out_of_sync'); end if;
  q := g.questions -> g.lvl; ans := (q->>'answer')::int;
  lim := case when g.lvl < 5 then 30 when g.lvl < 10 then 45 else 60 end;
  select case when coalesce((tts->>'enabled')::boolean, false)
              then least(greatest(coalesce(p_extra, 0), 0), coalesce((tts->>'extra_secs')::int, 0)) else 0 end
    into ex from app_settings where id = 1;
  timed_out := now() - g.q_started_at > make_interval(secs => lim + 4 + coalesce(ex, 0));
  ok := not timed_out and p_choice = ans;
  if ok then
    if g.lvl = 14 then
      sc := (_ladder())[15];
      perform _finish(g.id, sc, 15);
      return jsonb_build_object('ok', true, 'correct', true, 'finished', true, 'score', sc, 'correct_index', ans, 'explanation', q->>'explanation');
    end if;
    update game_sessions set lvl = lvl + 1, hidden = '[]'::jsonb, q_started_at = now(), ready = false where id = g.id;
    return jsonb_build_object('ok', true, 'correct', true, 'finished', false, 'score', (_ladder())[g.lvl + 1], 'correct_index', ans, 'explanation', q->>'explanation');
  end if;
  sc := _safe(g.lvl);
  perform _finish(g.id, sc, g.lvl + 1);
  return jsonb_build_object('ok', true, 'correct', false, 'timeout', timed_out or p_choice < 0, 'finished', true, 'score', sc, 'correct_index', ans, 'explanation', q->>'explanation');
end $$;

create or replace function public.kbc_quit(p_tok text, p_gid uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); g game_sessions; sc bigint;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into g from game_sessions where id = p_gid and user_id = uid and mode = 'kbc' for update;
  if not found or g.status <> 'active' then return jsonb_build_object('ok', false, 'error', 'no_game'); end if;
  sc := case when g.lvl = 0 then 0 else (_ladder())[g.lvl] end;
  perform _finish(g.id, sc, g.lvl + 1);
  return jsonb_build_object('ok', true, 'score', sc);
end $$;

create or replace function public.kbc_lifeline(p_tok text, p_gid uuid, p_kind text, p_lvl int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); g game_sessions; q jsonb; ans int; wrong int[]; hid int[]; pct int[] := array[0,0,0,0];
        top int; rem int; x int; k int; n int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  if p_kind not in ('ff','poll','ph') then return jsonb_build_object('ok', false, 'error', 'no_game'); end if;
  select * into g from game_sessions where id = p_gid and user_id = uid and mode = 'kbc' for update;
  if not found or g.status <> 'active' then return jsonb_build_object('ok', false, 'error', 'no_game'); end if;
  if p_lvl <> g.lvl then return jsonb_build_object('ok', false, 'error', 'out_of_sync'); end if;
  if coalesce((g.used->>p_kind)::boolean, false) then return jsonb_build_object('ok', false, 'error', 'lifeline_used'); end if;
  q := g.questions -> g.lvl; ans := (q->>'answer')::int;
  update game_sessions set used = used || jsonb_build_object(p_kind, true) where id = g.id;

  if p_kind = 'ff' then
    select array_agg(i) into hid from (select i from generate_series(0,3) i where i <> ans order by random() limit 2) s;
    update game_sessions set hidden = to_jsonb(hid) where id = g.id;
    return jsonb_build_object('ok', true, 'hidden', to_jsonb(hid));
  elsif p_kind = 'poll' then
    top := round(greatest(30, least(88, 88 - g.lvl * 4 + (random() * 12 - 6))))::int;
    select array_agg(i order by i) into wrong from generate_series(0,3) i
     where i <> ans and not (g.hidden @> to_jsonb(i));
    n := coalesce(array_length(wrong, 1), 0);
    if n = 0 then top := 100; end if;
    pct[ans + 1] := top; rem := 100 - top;
    for k in 1..n loop
      if k = n then x := rem; else x := (random() * rem)::int; end if;
      pct[wrong[k] + 1] := x; rem := rem - x;
    end loop;
    return jsonb_build_object('ok', true, 'pct', to_jsonb(pct));
  else
    return jsonb_build_object('ok', true, 'text', q->>'hint', 'letter', chr(65 + ans), 'sure', greatest(45, 95 - g.lvl * 3));
  end if;
end $$;

create or replace function public.study_submit(p_tok text, p_gid uuid, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); g game_sessions; k int; a int; ans int; sc int := 0; rev jsonb := '[]'::jsonb;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  if jsonb_typeof(p_answers) <> 'array' then return jsonb_build_object('ok', false, 'error', 'no_game'); end if;
  select * into g from game_sessions where id = p_gid and user_id = uid and mode = 'study' for update;
  if not found or g.status <> 'active' then return jsonb_build_object('ok', false, 'error', 'no_game'); end if;
  for k in 0..jsonb_array_length(g.questions) - 1 loop
    a := coalesce((p_answers->>k)::int, -1);
    ans := (g.questions->k->>'answer')::int;
    if a = ans then sc := sc + 1; end if;
    rev := rev || jsonb_build_array(jsonb_build_object('correct_index', ans, 'explanation', g.questions->k->>'explanation'));
  end loop;
  perform _finish(g.id, sc, jsonb_array_length(g.questions));
  return jsonb_build_object('ok', true, 'score', sc, 'review', rev);
end $$;

create or replace function public._tier(p_cls text) returns int
language sql immutable as $$
  select case p_cls
    when '5th Class' then 5 when '6th Class' then 6 when '7th Class' then 7 when '8th Class' then 8
    when '9th Class' then 9 when '10th Class' then 10 when '11th Class' then 11 when '12th Class' then 12
    when 'General GK' then 13 else 0 end
$$;

create or replace function public.leaderboard(p_cls text default null, p_lim int default 20) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.rank), '[]'::jsonb) from (
    select row_number() over (order by b.tier desc, b.drank desc, b.best desc, b.at) as rank, u.username, u.avatar_letter, u.avatar_color,
           b.best as score, b.reached, b.cls, b.difficulty
      from (select distinct on (l.user_id) l.user_id, _tier(l.class_level) as tier, _diff_rank(l.difficulty) as drank, l.difficulty,
                   l.score as best, l.reached, l.created_at as at, l.class_level as cls
              from leaderboards l where (p_cls is null or l.class_level = p_cls)
             order by l.user_id, _tier(l.class_level) desc, _diff_rank(l.difficulty) desc, l.score desc, l.created_at) b
      join app_users u on u.id = b.user_id
     order by b.tier desc, b.drank desc, b.best desc, b.at limit least(coalesce(p_lim, 20), 50)
  ) t
$$;

-- ---------- Edge function gate (service role only) ----------
create or replace function public.gate(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); s app_settings;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into s from app_settings where id = 1;
  return jsonb_build_object('ok', true, 'user_id', uid, 'key', s.gemini_key, 'model', s.model, 'cache_sets', s.cache_sets,
    'user_ok', (select count(*) from api_logs where user_id = uid and not cache_hit and created_at > now() - interval '1 hour') < s.hourly_cap,
    'global_ok', (select count(*) from api_logs where not cache_hit and created_at > now() - interval '24 hours') < s.daily_cap);
end $$;

-- ---------- Admin ----------
create or replace function public.admin_get_settings(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare s app_settings;
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  select * into s from app_settings where id = 1;
  return jsonb_build_object('ok', true, 'has_key', coalesce(s.gemini_key, '') <> '', 'hint', right(coalesce(s.gemini_key, ''), 4),
    'model', s.model, 'daily_cap', s.daily_cap, 'hourly_cap', s.hourly_cap, 'cache_sets', s.cache_sets,
    'used_today', (select count(*) from api_logs where not cache_hit and created_at > now() - interval '24 hours'));
end $$;

create or replace function public.admin_save_settings(p_tok text, p_key text, p_model text, p_daily int, p_hourly int, p_sets int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if coalesce(p_key, '') <> '' and p_key !~ '^[A-Za-z0-9._~-]{20,200}$' then return jsonb_build_object('ok', false, 'error', 'bad_key'); end if;
  if p_model !~ '^gemini-[a-z0-9.-]{3,40}$' then return jsonb_build_object('ok', false, 'error', 'bad_model'); end if;
  update app_settings set
    gemini_key = case when coalesce(p_key, '') = '' then gemini_key else p_key end,
    model = p_model,
    daily_cap = greatest(10, least(coalesce(p_daily, 1000), 100000)),
    hourly_cap = greatest(1, least(coalesce(p_hourly, 12), 1000)),
    cache_sets = greatest(1, least(coalesce(p_sets, 6), 50))
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_remove_key(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  update app_settings set gemini_key = null where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_clear_cache(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  delete from cached_quizzes where true;
  delete from curriculum_cache where true;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_logs(p_tok text, p_lim int default 60) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return (select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]'::jsonb) from (
    select l.id, l.created_at, u.username, l.kind, l.class_level, l.status, l.ms, l.tokens_in, l.tokens_out,
           l.cache_hit, l.error, l.request, l.response
      from api_logs l left join app_users u on u.id = l.user_id
     order by l.id desc limit least(coalesce(p_lim, 60), 200)) t);
end $$;

create or replace function public.admin_users(p_tok text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return (select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) from (
    select u.username, u.is_admin, u.created_at, (select count(*) from game_sessions g where g.user_id = u.id) as games
      from app_users u) t);
end $$;

create or replace function public.admin_delete_user(p_tok text, p_user text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if exists (select 1 from app_users where lower(username) = lower(p_user) and is_admin) then
    return jsonb_build_object('ok', false, 'error', 'admin_protected');
  end if;
  delete from app_users where lower(username) = lower(p_user);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Profile ----------
create or replace function public.update_profile(p_tok text, p_letter text, p_color text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); r app_users; l text := nullif(trim(coalesce(p_letter, '')), ''); c text := nullif(coalesce(p_color, ''), '');
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  if l is not null and (char_length(l) > 8 or l ~ '[[:space:][:cntrl:]<>&"'']') then return jsonb_build_object('ok', false, 'error', 'bad_icon'); end if;
  if c is not null and c !~ '^#[0-9a-fA-F]{6}$' then return jsonb_build_object('ok', false, 'error', 'bad_color'); end if;
  update app_users set avatar_letter = l, avatar_color = c where id = uid returning * into r;
  return _user_json(r, p_tok);
end $$;

create or replace function public.rename_user(p_tok text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := _uid(p_tok); r app_users; n text := trim(coalesce(p_new, ''));
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  if n !~ '^[A-Za-z0-9_]{3,16}$' then return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  if exists (select 1 from app_users where lower(username) = lower(n) and id <> uid) then return jsonb_build_object('ok', false, 'error', 'taken'); end if;
  update app_users set username = n where id = uid returning * into r;
  return _user_json(r, p_tok);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'taken');
end $$;

-- Deletes the account, its sessions, game history and leaderboard rows. Needs the password. The admin account can't be deleted.
create or replace function public.delete_account(p_tok text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare uid uuid := _uid(p_tok); r app_users;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not_signed_in'); end if;
  select * into r from app_users where id = uid;
  if r.is_admin then return jsonb_build_object('ok', false, 'error', 'admin_protected'); end if;
  if r.pw_hash <> crypt(coalesce(p_pw, ''), r.pw_hash) then return jsonb_build_object('ok', false, 'error', 'wrong'); end if;
  delete from app_users where id = uid;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Speech settings ----------
-- Public: the browser needs these to know how to read questions. Contains nothing secret.
create or replace function public.get_config() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('ok', true, 'tts', tts) from app_settings where id = 1
$$;

create or replace function public.admin_save_tts(p_tok text, p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c jsonb := coalesce(p_cfg, '{}'::jsonb);
begin
  if not _is_admin(p_tok) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if coalesce(c->>'lang', '') !~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$' or char_length(coalesce(c->>'voice', '')) > 100
     or coalesce(c->>'voice', '') ~ '[[:cntrl:]<>]' then
    return jsonb_build_object('ok', false, 'error', 'bad_tts');
  end if;
  update app_settings set tts = jsonb_build_object(
    'enabled', coalesce((c->>'enabled')::boolean, true),
    'auto', coalesce((c->>'auto')::boolean, true),
    'lang', c->>'lang',
    'voice', coalesce(c->>'voice', ''),
    'rate', greatest(0.5, least(1.6, coalesce((c->>'rate')::numeric, 0.95))),
    'pitch', greatest(0.5, least(1.5, coalesce((c->>'pitch')::numeric, 1))),
    'volume', greatest(0, least(1, coalesce((c->>'volume')::numeric, 1))),
    'pause_ms', greatest(0, least(2000, coalesce((c->>'pause_ms')::int, 500))),
    'labels', coalesce((c->>'labels')::boolean, true),
    'announce', coalesce((c->>'announce')::boolean, true),
    'extra_secs', greatest(0, least(30, coalesce((c->>'extra_secs')::int, 12)))
  ) where id = 1;
  return jsonb_build_object('ok', true);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'bad_tts');
end $$;

-- ---------- Permissions ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.signup(text, text), public.login(text, text), public.check_session(text), public.logout(text),
  public.change_password(text, text, text), public.leaderboard(text, int),
  public.update_profile(text, text, text), public.rename_user(text, text), public.delete_account(text, text),
  public.kbc_answer(text, uuid, int, int, int), public.kbc_ready(text, uuid, int), public.get_config(), public.admin_save_tts(text, jsonb), public.kbc_quit(text, uuid), public.kbc_lifeline(text, uuid, text, int),
  public.study_submit(text, uuid, jsonb),
  public.admin_get_settings(text), public.admin_save_settings(text, text, text, int, int, int),
  public.admin_remove_key(text), public.admin_clear_cache(text), public.admin_logs(text, int),
  public.admin_users(text), public.admin_delete_user(text, text)
  to anon, authenticated;
grant execute on function public.gate(text), public.create_game(text, text, text, jsonb, text) to service_role;

-- ---------- Admin account ----------
-- Username: admin   Password: rudsilver56   (change it from the account menu after your first sign-in)
insert into public.app_users (username, pw_hash, is_admin)
values ('admin', extensions.crypt('rudsilver56', extensions.gen_salt('bf', 10)), true)
on conflict do nothing;
