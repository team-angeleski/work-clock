-- NOT APPLIED. Saved for later, when characters come back (Costume.enabled in Sources/Characters.swift).
--
-- Plan: legends are hard to unlock and get harder. Each needs a streak of workdays at a focus
-- target, worked out on the server from real logged time. Days off neither count nor break a
-- streak; once unlocked a legend is kept. Wearing one stays the day's winner's reward.
--
--   1 Ice Cube                5 workdays at 2h
--   2 50 Cent                 7 workdays at 2h 30m
--   3 Barack Obama           10 workdays at 3h
--   4 Martin Luther King Jr. 14 workdays at 3h 30m
--   5 Mike Tyson             21 workdays at 4h
--
-- After applying: change focus_sync to return 'legends', focusboard.legend_progress(me.id),
-- and show progress in the app ("Next: 50 Cent · 3 of 7 days at 2h 30m").

create or replace function focusboard.legends() returns table (legend text, rank int, need_days int, need_seconds int)
language sql immutable set search_path = '' as $$
  values ('icecube', 1, 5, 7200), ('fifty', 2, 7, 9000), ('obama', 3, 10, 10800), ('mlk', 4, 14, 12600), ('tyson', 5, 21, 14400)
$$;

-- Current streak of workdays at or above a target. Today only counts once reached.
create or replace function focusboard.streak_at(p_member uuid, p_seconds int) returns int
language plpgsql stable security definer set search_path = '' as $$
declare m focusboard.members; d date; today date; n int := 0; s int; i int := 0; wd int;
begin
  select * into m from focusboard.members where id = p_member;
  today := focusboard.local_now(m.tz_minutes)::date;
  wd := case when m.workdays = 0 then 127 else m.workdays end;
  d := today;
  while i < 90 loop
    if ((wd >> (extract(isodow from d)::int - 1)) & 1) = 1 then
      select seconds into s from focusboard.days where member_id = p_member and day = d;
      if coalesce(s, 0) >= p_seconds then n := n + 1;
      elsif d <> today then exit;
      end if;
    end if;
    d := d - 1; i := i + 1;
  end loop;
  return n;
end $$;

-- Progress on every legend, unlocking any whose streak is reached.
create or replace function focusboard.legend_progress(p_member uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare l record; st int; today date; out_ json[] := '{}';
begin
  today := focusboard.local_now((select tz_minutes from focusboard.members where id = p_member))::date;
  for l in select * from focusboard.legends() order by rank loop
    st := focusboard.streak_at(p_member, l.need_seconds);
    if st >= l.need_days then
      insert into focusboard.unlocks (member_id, character, unlocked_on) values (p_member, l.legend, today)
      on conflict do nothing;
    end if;
    out_ := out_ || json_build_object('id', l.legend, 'need_days', l.need_days, 'need_seconds', l.need_seconds,
                                      'streak', least(st, l.need_days),
                                      'unlocked', exists (select 1 from focusboard.unlocks u where u.member_id = p_member and u.character = l.legend));
  end loop;
  return array_to_json(out_);
end $$;

revoke all on function focusboard.legends(), focusboard.streak_at(uuid, int), focusboard.legend_progress(uuid)
  from public, anon, authenticated;

-- And in public.focus_set_character: drop the "unlock by winning" branch, and require
--   exists (select 1 from focusboard.unlocks where member_id = me.id and character = p_character)
-- before letting the winner wear it.
