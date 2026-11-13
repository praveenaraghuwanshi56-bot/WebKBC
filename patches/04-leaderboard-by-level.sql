-- WebKbc: leaderboard ranks the higher class level first, then the score
-- Safe to run on an existing database. It does not touch your data.
--
-- Order: General GK (highest) > 12th Class > ... > 5th Class, then higher score, then earlier date.
-- So a player's ₹10,000 in 12th Class ranks above someone else's ₹3,20,000 in 5th Class.
-- Each player appears once, with their best result at their highest class level.

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
    select row_number() over (order by b.tier desc, b.best desc, b.at) as rank, u.username, u.avatar_letter, u.avatar_color,
           b.best as score, b.reached, b.cls
      from (select distinct on (l.user_id) l.user_id, _tier(l.class_level) as tier, l.score as best, l.reached,
                   l.created_at as at, l.class_level as cls
              from leaderboards l where (p_cls is null or l.class_level = p_cls)
             order by l.user_id, _tier(l.class_level) desc, l.score desc, l.created_at) b
      join app_users u on u.id = b.user_id
     order by b.tier desc, b.best desc, b.at limit least(coalesce(p_lim, 20), 50)
  ) t
$$;

revoke execute on function public._tier(text) from public, anon, authenticated;
revoke execute on function public.leaderboard(text, int) from public, anon, authenticated;
grant execute on function public.leaderboard(text, int) to anon, authenticated;
