-- WebKbc: Easy / Medium / Hard for KBC and CBSE quizzes
-- Run this BEFORE deploying the new Edge Function. The old function keeps working in the meantime (difficulty defaults to easy).
-- Safe to run on an existing database. It does not touch your data.

alter table public.game_sessions add column if not exists difficulty text not null default 'easy'
  check (difficulty in ('easy','medium','hard'));
alter table public.leaderboards add column if not exists difficulty text not null default 'easy'
  check (difficulty in ('easy','medium','hard'));

create or replace function public._diff_rank(p_diff text) returns int
language sql immutable as $$
  select case p_diff when 'hard' then 3 when 'medium' then 2 else 1 end
$$;

-- A finished KBC game now records its difficulty on the leaderboard row.
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

-- create_game gains p_difficulty. The old 4-argument version is dropped so there is exactly one.
drop function if exists public.create_game(text, text, text, jsonb);
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

-- Ranking: higher class level first, then harder difficulty, then higher score, then earlier date.
-- One row per player: their best result at their highest class level and hardest difficulty.
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

revoke execute on function public._diff_rank(text), public._finish(uuid, bigint, int) from public, anon, authenticated;
-- create_game must only ever be callable by the Edge Function (service role). If anyone could call it, a player could hand it
-- questions of their own and win a perfect game. So close it for EVERY version of the function that exists, whatever its arguments.
do $$ declare r record; begin
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'create_game' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.f);
  end loop;
end $$;
grant execute on function public.create_game(text, text, text, jsonb, text) to service_role;
revoke execute on function public.leaderboard(text, int) from public, anon, authenticated;
grant execute on function public.leaderboard(text, int) to anon, authenticated;

-- Make the API notice the changed functions straight away.
notify pgrst, 'reload schema';
