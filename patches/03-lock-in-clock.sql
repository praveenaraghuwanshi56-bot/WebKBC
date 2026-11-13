-- WebKbc: fair clock for the lock-in pause (needs patch 02 applied first)
-- Safe to run on an existing database. It does not touch your data.

alter table public.game_sessions add column if not exists ready boolean not null default false;

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

-- Same signature as before, so this replaces the existing kbc_answer. The only change: a correct answer resets "ready".
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

revoke execute on function public.kbc_ready(text, uuid, int) from public, anon, authenticated;
grant execute on function public.kbc_ready(text, uuid, int) to anon, authenticated;
