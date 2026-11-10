-- WebKbc: read-aloud settings (admin-controlled) + extra time for listeners
-- Safe to run on an existing database. It does not touch your data.

alter table public.app_settings add column if not exists tts jsonb not null default
  '{"enabled":true,"auto":true,"lang":"en-IN","voice":"","rate":0.95,"pitch":1,"volume":1,"pause_ms":500,"labels":true,"announce":true,"extra_secs":12}'::jsonb;

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

-- kbc_answer gains p_extra: seconds of extra time a player who listened to the question may claim.
-- It is capped by the admin's "extra seconds" setting (and 0 if read-aloud is switched off).
drop function if exists public.kbc_answer(text, uuid, int, int);
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
    update game_sessions set lvl = lvl + 1, hidden = '[]'::jsonb, q_started_at = now() where id = g.id;
    return jsonb_build_object('ok', true, 'correct', true, 'finished', false, 'score', (_ladder())[g.lvl + 1], 'correct_index', ans, 'explanation', q->>'explanation');
  end if;
  sc := _safe(g.lvl);
  perform _finish(g.id, sc, g.lvl + 1);
  return jsonb_build_object('ok', true, 'correct', false, 'timeout', timed_out or p_choice < 0, 'finished', true, 'score', sc, 'correct_index', ans, 'explanation', q->>'explanation');
end $$;

revoke execute on function public.get_config(), public.admin_save_tts(text, jsonb), public.kbc_answer(text, uuid, int, int, int) from public, anon, authenticated;
grant execute on function public.get_config(), public.admin_save_tts(text, jsonb), public.kbc_answer(text, uuid, int, int, int) to anon, authenticated;
