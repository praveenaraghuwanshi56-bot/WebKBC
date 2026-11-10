-- WebKbc: profile features (icon, colour, username, delete account)
-- Safe to run on an existing database. It does not touch your data.

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

revoke execute on function public.update_profile(text, text, text), public.rename_user(text, text), public.delete_account(text, text) from public, anon, authenticated;
grant execute on function public.update_profile(text, text, text), public.rename_user(text, text), public.delete_account(text, text) to anon, authenticated;
