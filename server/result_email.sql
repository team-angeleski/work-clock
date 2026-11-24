-- Darnell Jr. 2.6: the blind race's reveal, by email.
-- Today's times are sealed in the apps. Each morning (7am to noon, the member's own time)
-- everyone with an email gets yesterday's result: every score, and who won.
-- Nothing is sent for a day nobody reached 10 minutes, or to a board of one.
-- Run after office_hours.sql (uses its outbox, enqueue, hm and local_now).

create table if not exists focusboard.results_sent (
  member_id uuid not null references focusboard.members(id) on delete cascade,
  day date not null,
  primary key (member_id, day)
);
alter table focusboard.results_sent enable row level security;   -- no policies: functions only

-- The email one member gets about one day. Null subject = nothing to send.
create or replace function focusboard.result_email(p_member uuid, p_day date, out subject text, out body text)
language plpgsql stable security definer set search_path to '' as $$
declare me focusboard.members; r record; best int; mine int := 0; second int := 0; winners int := 0;
        top_name text; lines text := ''; msg text;
begin
  select * into me from focusboard.members where id = p_member;
  if me.id is null or (select count(*) from focusboard.members where group_id = me.group_id) < 2 then return; end if;
  select coalesce(max(d.score), 0) into best
    from focusboard.members m left join focusboard.days d on d.member_id = m.id and d.day = p_day
   where m.group_id = me.group_id;
  if best < 600 then return; end if;

  for r in select m.id, m.name, coalesce(d.score, 0) as s
             from focusboard.members m left join focusboard.days d on d.member_id = m.id and d.day = p_day
            where m.group_id = me.group_id order by 3 desc, 2 loop
    lines := lines || case when r.s = best then '👑 ' else '      ' end
                   || case when r.id = me.id then 'You' else r.name end || ': ' || focusboard.hm(r.s) || E'\n';
    if r.s = best then winners := winners + 1; end if;
    if r.id = me.id then mine := r.s;
    else
      second := greatest(second, r.s);
      if r.s = best and top_name is null then top_name := r.name; end if;
    end if;
  end loop;

  if mine = best and winners = 1 then
    subject := 'You won yesterday 👑 ' || focusboard.hm(mine) || ' to ' || focusboard.hm(second);
    msg := 'You took it. Your taunts are ready: right-click your clock to send one.';
  elsif mine = best then
    subject := 'Yesterday was a tie at ' || focusboard.hm(best);
    msg := 'Dead level with ' || top_name || '. Settle it today.';
  else
    subject := top_name || ' won yesterday: ' || focusboard.hm(best) || ' to your ' || focusboard.hm(mine);
    msg := top_name || ' took it by ' || focusboard.hm(best - mine) || '. Expect taunts.';
  end if;
  body := 'Yesterday''s result' || E'\n\n' || lines || E'\n' || msg || E'\n\n'
       || 'Today''s race is already on. Times stay sealed until tomorrow morning, so it''s anyone''s.';
end $$;

-- Queues each member's result once, in their own morning.
create or replace function focusboard.results() returns void
language plpgsql security definer set search_path to '' as $$
declare m focusboard.members; ln timestamp; d date; s text; b text;
begin
  for m in select * from focusboard.members where email is not null loop
    ln := focusboard.local_now(m.tz_minutes);
    continue when extract(hour from ln) < 7 or extract(hour from ln) >= 12;
    d := ln::date - 1;
    continue when exists (select 1 from focusboard.results_sent where member_id = m.id and day = d);
    insert into focusboard.results_sent (member_id, day) values (m.id, d);
    select e.subject, e.body into s, b from focusboard.result_email(m.id, d) e;
    if s is not null then perform focusboard.enqueue(m.email, s, b); end if;
  end loop;
end $$;

revoke all on function focusboard.result_email(uuid, date) from public, anon, authenticated;
revoke all on function focusboard.results() from public, anon, authenticated;

-- The minute tick runs it just before it sends the outbox.
do $$
declare src text;
begin
  src := pg_get_functiondef('focusboard.tick'::regproc);
  if position('focusboard.results()' in src) = 0 then
    execute replace(src, 'perform focusboard.flush();', E'perform focusboard.results();\n  perform focusboard.flush();');
  end if;
end $$;

-- To switch it off: recreate focusboard.tick() without the results() line.

-- "X just passed you" emails would give today's scores away, so they're off: the pass condition
-- in every focus_sync can never hold.
do $$
declare f record; src text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'focus_sync' loop
    src := pg_get_functiondef(f.oid);
    if position('passed = fr.id) < 3 then' in src) > 0 then
      execute replace(src, 'passed = fr.id) < 3 then', 'passed = fr.id) < 0 then  -- blind race: no pass emails');
    end if;
  end loop;
end $$;
notify pgrst, 'reload schema';
