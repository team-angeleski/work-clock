-- Work Clock v1.3: office hours and email alerts.
--
-- Office hours: each member commits to a clock-in time and workdays. Changes only start
-- tomorrow, so today's start can't be pushed back once you're running late.
-- Clocking in = your first 5 focused minutes of the day. Late costs 1 point a minute
-- (after 5 minutes' grace, capped at 120), and the server emails you and your friends.
--
-- Email goes through Resend (the Team Angeleski account), sent from the database with
-- pg_net. The key lives in Supabase Vault under the name 'focusboard_resend'.
-- A cron job runs focusboard.tick() every minute.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

alter table focusboard.members
  add column if not exists email text
    check (email is null or (char_length(email) <= 120 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  add column if not exists start_min int not null default 540 check (start_min between 240 and 840),
  add column if not exists workdays int not null default 31 check (workdays between 0 and 127),  -- bit 0 = Monday
  add column if not exists next_start_min int check (next_start_min between 240 and 840),
  add column if not exists next_workdays int check (next_workdays between 0 and 127),
  add column if not exists next_from date;

alter table focusboard.days
  add column if not exists clock_in timestamptz,
  add column if not exists late_min int not null default 0 check (late_min between 0 and 120),
  add column if not exists alerts int not null default 0;   -- 1 due, 2 fifteen late, 4 hour late

create table if not exists focusboard.outbox (
  id bigserial primary key,
  to_email text not null,
  subject text not null,
  body text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  request_id bigint
);
alter table focusboard.outbox enable row level security;

create table if not exists focusboard.passes (
  day date not null,
  passer uuid not null references focusboard.members(id) on delete cascade,
  passed uuid not null references focusboard.members(id) on delete cascade,
  primary key (day, passer, passed)
);
alter table focusboard.passes enable row level security;

-- Existing members: office hours start tomorrow at 9am, Monday to Friday.
update focusboard.members
   set workdays = 0, next_start_min = 540, next_workdays = 31, next_from = current_date + 1
 where next_from is null and created_at < now();

-- ── Helpers ────────────────────────────────────────────────────────────────

create or replace function focusboard.local_now(p_tz int) returns timestamp
language sql stable set search_path = '' as $$
  select (now() at time zone 'UTC') + make_interval(mins => coalesce(p_tz, 0))
$$;

-- Apply a pending schedule change once its day has come.
create or replace function focusboard.promote(p_id uuid) returns focusboard.members
language plpgsql security definer set search_path = '' as $$
declare m focusboard.members;
begin
  update focusboard.members
     set start_min = coalesce(next_start_min, start_min), workdays = coalesce(next_workdays, workdays),
         next_start_min = null, next_workdays = null, next_from = null
   where id = p_id and next_from is not null and next_from <= focusboard.local_now(tz_minutes)::date;
  select * into m from focusboard.members where id = p_id;
  return m;
end $$;

-- When the member is due on a day, or null on a day off.
create or replace function focusboard.due_at(m focusboard.members, d date) returns timestamptz
language sql stable set search_path = '' as $$
  select case when m.tz_minutes is null or ((m.workdays >> (extract(isodow from d)::int - 1)) & 1) = 0 then null
              else ((d + make_interval(mins => m.start_min)) - make_interval(mins => m.tz_minutes)) at time zone 'UTC' end
$$;

-- Minutes late, after 5 minutes' grace, capped at 2 hours.
create or replace function focusboard.late_for(p_due timestamptz, p_in timestamptz) returns int
language sql stable set search_path = '' as $$
  select case when p_due is null then 0 else
    (select case when x <= 5 then 0 else least(x, 120) end
       from (select floor(extract(epoch from coalesce(p_in, now()) - p_due) / 60)::int as x) s) end
$$;

create or replace function focusboard.hm(s int) returns text
language sql immutable set search_path = '' as $$
  select case when s >= 3600 then (s / 3600) || 'h ' || ((s % 3600) / 60) || 'm' else greatest(s / 60, 0) || 'm' end
$$;

create or replace function focusboard.clock_text(mins int) returns text
language sql immutable set search_path = '' as $$
  select to_char(make_time(mins / 60, mins % 60, 0), 'FMHH12:MI') || lower(to_char(make_time(mins / 60, mins % 60, 0), 'am'))
$$;

create or replace function focusboard.enqueue(p_to text, p_subject text, p_body text) returns void
language sql security definer set search_path = '' as $$
  insert into focusboard.outbox (to_email, subject, body)
  select p_to, p_subject, p_body where p_to is not null
$$;

-- Sends queued email through Resend. At most 60 a day across the board, and anything
-- older than 30 minutes is dropped rather than sent late.
create or replace function focusboard.flush() returns void
language plpgsql security definer set search_path = '' as $$
declare k text; r record; budget int;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'focusboard_resend';
  if k is null then return; end if;
  update focusboard.outbox set sent_at = now(), request_id = -1
   where sent_at is null and created_at < now() - interval '30 minutes';
  budget := greatest(0, 60 - (select count(*) from focusboard.outbox
                               where sent_at > now() - interval '24 hours' and request_id > 0)::int);
  for r in select * from focusboard.outbox where sent_at is null order by id limit least(budget, 20) loop
    update focusboard.outbox set sent_at = now(), request_id = net.http_post(
        url := 'https://api.resend.com/emails',
        body := jsonb_build_object(
          'from', 'Work Clock <clock@teamangeleski.com.au>',
          'to', jsonb_build_array(r.to_email),
          'subject', r.subject,
          'text', r.body || E'\n\n—\nWork Clock. To stop these emails: right-click your clock, then Email alerts, then Turn off.'),
        headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'))
     where id = r.id;
  end loop;
  delete from focusboard.outbox where created_at < now() - interval '14 days';
end $$;

-- Every minute: lateness, alerts, then send.
create or replace function focusboard.tick() returns void
language plpgsql security definer set search_path = '' as $$
declare m focusboard.members; d date; due_ timestamptz; row_ focusboard.days; late_ int; flags int; f record;
        due_txt text;
begin
  for m in select * from focusboard.members where tz_minutes is not null loop
    m := focusboard.promote(m.id);
    d := focusboard.local_now(m.tz_minutes)::date;
    due_ := focusboard.due_at(m, d);
    continue when due_ is null or m.created_at >= due_ or now() < due_;
    insert into focusboard.days (member_id, day) values (m.id, d) on conflict do nothing;
    select * into row_ from focusboard.days where member_id = m.id and day = d;
    continue when row_.clock_in is not null or row_.seconds >= 300;
    late_ := focusboard.late_for(due_, null);
    flags := row_.alerts;
    due_txt := focusboard.clock_text(m.start_min);

    if (flags & 1) = 0 and late_ < 15 then
      flags := flags | 1;
      perform focusboard.enqueue(m.email, 'Clock in. It''s ' || due_txt || '.',
        'You said you''d start at ' || due_txt || '. Open your Mac and click the clock.' || E'\n\n'
        || 'At 15 minutes late your friends get an email. Every minute late costs you a point.');
    end if;
    if late_ >= 15 and late_ < 60 and (flags & 2) = 0 then
      flags := flags | 2;
      perform focusboard.enqueue(m.email, 'You''re 15 minutes late',
        'Your friends have just been told. −' || late_ || ' points and counting. Clock in now to stop it.');
      for f in select * from focusboard.members where group_id = m.group_id and id <> m.id and email is not null loop
        perform focusboard.enqueue(f.email, m.name || ' hasn''t clocked in',
          m.name || ' was due at ' || due_txt || ' and is 15 minutes late. It costs them a point a minute.'
          || E'\n\n' || 'Good time to get ahead.');
      end loop;
    end if;
    if late_ >= 60 and (flags & 4) = 0 then
      flags := flags | 4;
      perform focusboard.enqueue(m.email, 'An hour late',
        'You were due at ' || due_txt || '. That''s −60 points so far. Your office would have noticed by now.');
      for f in select * from focusboard.members where group_id = m.group_id and id <> m.id and email is not null loop
        perform focusboard.enqueue(f.email, m.name || ' is an hour late',
          m.name || ' still hasn''t clocked in (due ' || due_txt || '). Down 60 points.');
      end loop;
    end if;
    update focusboard.days set late_min = late_, alerts = flags where member_id = m.id and day = d;
  end loop;
  perform focusboard.flush();
end $$;

-- ── Sync, now with clock-in, lateness and overtake emails ──────────────────

create or replace function public.focus_sync(
  p_member uuid, p_secret uuid, p_day date, p_seconds int, p_score int,
  p_level int, p_streak int, p_focusing boolean, p_tz_minutes int)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; prev int; prev_early int; prev_morning int; prev_score int; prev_late int;
        prev_clock timestamptz; allowed int; accepted int; score_ int; tz int; local_now timestamp;
        early int; morning int; added int; max_score int; due_ timestamptz; clock_ timestamptz; late_ int;
        before_net int; after_net int; fr record;
begin
  me := focusboard.authed(p_member, p_secret);
  if p_day not between current_date - 2 and current_date + 2 then raise exception 'Check your Mac''s date'; end if;

  -- Time zone is locked at the first check-in, so it can't be changed to fake an early morning.
  tz := coalesce(me.tz_minutes, least(greatest(coalesce(p_tz_minutes, 0), -720), 840));
  if me.tz_minutes is null then update focusboard.members set tz_minutes = tz where id = me.id; end if;
  me := focusboard.promote(me.id);
  local_now := focusboard.local_now(tz);

  select seconds, early_ok, morning_ok, score, late_min, clock_in
    into prev, prev_early, prev_morning, prev_score, prev_late, prev_clock
    from focusboard.days where member_id = me.id and day = p_day;
  allowed := coalesce(prev, 0) + ceil(extract(epoch from now() - me.last_seen))::int + 90;
  accepted := least(greatest(coalesce(p_seconds, 0), 0), allowed, 57600);
  accepted := greatest(accepted, coalesce(prev, 0));
  added := accepted - coalesce(prev, 0);

  -- Bonus-eligible time is only what the server saw being added before 9am / 1pm local.
  early := coalesce(prev_early, 0);
  morning := coalesce(prev_morning, 0);
  if local_now::date = p_day and extract(hour from local_now) < 9 then early := early + added; end if;
  if local_now::date = p_day and extract(hour from local_now) < 13 then morning := morning + added; end if;

  max_score := accepted + early / 2
             + case when (extract(hour from local_now) >= 13 or local_now::date > p_day) and morning >= 3600
                    then 1800 else 0 end;
  score_ := greatest(least(greatest(coalesce(p_score, 0), 0), max_score, 90000), coalesce(prev_score, 0));

  -- Clocked in once the first 5 minutes are done; the clock-in time is when they started.
  clock_ := prev_clock;
  if clock_ is null and accepted >= 300 and local_now::date = p_day then
    clock_ := now() - make_interval(secs => accepted);
  end if;
  due_ := focusboard.due_at(me, p_day);
  late_ := coalesce(prev_late, 0);
  if local_now::date = p_day and due_ is not null and me.created_at < due_ and (clock_ is not null or now() > due_) then
    late_ := focusboard.late_for(due_, clock_);
  end if;

  insert into focusboard.days (member_id, day, seconds, score, early_ok, morning_ok, clamped, clock_in, late_min, updated_at)
  values (me.id, p_day, accepted, score_, early, morning, greatest(coalesce(p_seconds, 0) - accepted, 0), clock_, late_, now())
  on conflict (member_id, day) do update
    set seconds = excluded.seconds,
        score = excluded.score,
        early_ok = excluded.early_ok,
        morning_ok = excluded.morning_ok,
        clamped = focusboard.days.clamped + excluded.clamped,
        clock_in = coalesce(focusboard.days.clock_in, excluded.clock_in),
        late_min = excluded.late_min,
        updated_at = now();

  update focusboard.members
     set level = coalesce(p_level, level), streak = coalesce(p_streak, streak),
         focusing = coalesce(p_focusing, false), last_seen = now()
   where id = me.id;

  -- Overtakes: email a friend the moment you pass them (3 a day at most, 7am to 10pm).
  before_net := greatest(coalesce(prev_score, 0) - coalesce(prev_late, 0) * 60, 0);
  after_net := greatest(score_ - late_ * 60, 0);
  if local_now::date = p_day and extract(hour from local_now) between 7 and 21 and after_net > before_net then
    for fr in select m.id, m.name, m.email, greatest(coalesce(d.score, 0) - coalesce(d.late_min, 0) * 60, 0) as net
               from focusboard.members m
               left join focusboard.days d on d.member_id = m.id and d.day = p_day
              where m.group_id = me.group_id and m.id <> me.id and m.email is not null loop
      if fr.net >= 600 and fr.net >= before_net and fr.net < after_net
         and (select count(*) from focusboard.passes where day = p_day and passed = fr.id) < 3 then
        insert into focusboard.passes (day, passer, passed) values (p_day, me.id, fr.id) on conflict do nothing;
        if found then
          perform focusboard.enqueue(fr.email, me.name || ' just passed you',
            me.name || ': ' || focusboard.hm(after_net) || '. You: ' || focusboard.hm(fr.net) || '.' || E'\n\n'
            || focusboard.hm(after_net - fr.net + 60) || ' of focus takes it back.');
        end if;
      end if;
    end loop;
  end if;

  return json_build_object(
    'code', (select code from focusboard.groups where id = me.group_id),
    'taunts_left', focusboard.taunts_left(me.id, me.group_id, p_day),
    'accepted', accepted,
    'me', json_build_object('email', me.email, 'start_min', me.start_min, 'workdays', me.workdays,
                            'next_start_min', me.next_start_min, 'next_workdays', me.next_workdays,
                            'next_from', me.next_from),
    'members', (select coalesce(json_agg(row_to_json(x) order by x.score desc, x.name), '[]'::json) from (
        select m.id, m.name, m.level, m.streak,
               (m.focusing and m.last_seen > now() - interval '6 minutes') as focusing,
               coalesce(d.seconds, 0) as today,
               greatest(coalesce(d.score, 0) - coalesce(d.late_min, 0) * 60, 0) as score,
               coalesce(d.late_min, 0) as late,
               case when focusboard.due_at(m, p_day) is not null and m.created_at < focusboard.due_at(m, p_day)
                    then m.start_min end as due_min,
               case when d.clock_in is not null then
                    (extract(epoch from ((d.clock_in at time zone 'UTC') + make_interval(mins => coalesce(m.tz_minutes, 0)))::time) / 60)::int
               end as in_min,
               coalesce((select greatest(y.score - y.late_min * 60, 0) from focusboard.days y
                          where y.member_id = m.id and y.day = p_day - 1), 0) as yesterday,
               coalesce((select sum(greatest(w.score - w.late_min * 60, 0)) from focusboard.days w
                          where w.member_id = m.id and w.day between p_day - 6 and p_day), 0) as week,
               (select count(*) from focusboard.taunts where from_member = me.id and to_member = m.id
                  and day = p_day)::int as taunted_today
          from focusboard.members m
          left join focusboard.days d on d.member_id = m.id and d.day = p_day
         where m.group_id = me.group_id) x),
    'incoming', (select coalesce(json_agg(row_to_json(y) order by y.created_at), '[]'::json) from (
        select t.id, t.message, t.created_at, f.name as from_name
          from focusboard.taunts t join focusboard.members f on f.id = t.from_member
         where t.to_member = me.id and t.seen_at is null
           and t.created_at > now() - interval '3 days') y)
  );
end $$;

-- Yesterday's winner is decided on score after lateness.
create or replace function focusboard.taunts_left(p_member uuid, p_group uuid, p_day date) returns int
language sql stable security definer set search_path = '' as $$
  select case when p_member in (
           select d.member_id from focusboard.days d
             join focusboard.members m on m.id = d.member_id
            where m.group_id = p_group and d.day = p_day - 1 and d.seconds >= 600
              and d.score - d.late_min * 60 = (select max(d2.score - d2.late_min * 60) from focusboard.days d2
                                 join focusboard.members m2 on m2.id = d2.member_id
                                where m2.group_id = p_group and d2.day = p_day - 1 and d2.seconds >= 600))
         then greatest(3 - (select count(*) from focusboard.taunts
                             where from_member = p_member and day = p_day)::int, 0)
         else 0 end
$$;

-- Taunts also land in the friend's inbox.
create or replace function public.focus_taunt(
  p_member uuid, p_secret uuid, p_target uuid, p_message text, p_day date)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; left_ int; target focusboard.members;
begin
  me := focusboard.authed(p_member, p_secret);
  if char_length(trim(coalesce(p_message, ''))) not between 1 and 80 then
    raise exception 'Taunts are 1-80 characters';
  end if;
  select * into target from focusboard.members where id = p_target and group_id = me.group_id and id <> me.id;
  if target.id is null then raise exception 'Pick a friend on your board'; end if;
  perform 1 from focusboard.members where id = me.id for update;
  left_ := focusboard.taunts_left(me.id, me.group_id, p_day);
  if left_ < 1 then raise exception 'No taunts left. Win a day to earn 3 more.'; end if;
  insert into focusboard.taunts (group_id, from_member, to_member, day, message)
  values (me.group_id, me.id, p_target, p_day, trim(p_message));
  perform focusboard.enqueue(target.email, '👑 ' || me.name || ': ' || trim(p_message),
    me.name || ' won yesterday and spent a taunt on you:' || E'\n\n' || '"' || trim(p_message) || '"'
    || E'\n\n' || 'Win today to send some back.');
  return json_build_object('ok', true, 'taunts_left', left_ - 1);
end $$;

-- Pick your clock-in time and workdays. Takes effect tomorrow.
create or replace function public.focus_schedule(p_member uuid, p_secret uuid, p_start_min int, p_workdays int)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members;
begin
  me := focusboard.authed(p_member, p_secret);
  if p_start_min is null or p_start_min not between 240 and 840 or p_start_min % 5 <> 0 then
    raise exception 'Pick a start time between 4am and 2pm';
  end if;
  if p_workdays is null or p_workdays not between 0 and 127 then raise exception 'Pick your workdays'; end if;
  update focusboard.members
     set next_start_min = p_start_min, next_workdays = p_workdays,
         next_from = focusboard.local_now(tz_minutes)::date + 1
   where id = me.id;
  update focusboard.members set next_start_min = null, next_workdays = null, next_from = null
   where id = me.id and next_start_min = start_min and next_workdays = workdays;
  return json_build_object('ok', true);
end $$;

-- Where alerts go. Empty turns them off.
create or replace function public.focus_set_email(p_member uuid, p_secret uuid, p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; v text;
begin
  me := focusboard.authed(p_member, p_secret);
  v := nullif(lower(trim(coalesce(p_email, ''))), '');
  if v is not null and (char_length(v) > 120 or v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then
    raise exception 'That email doesn''t look right';
  end if;
  if v is distinct from me.email then
    update focusboard.members set email = v where id = me.id;
    if v is not null and (select count(*) from focusboard.outbox where to_email = v and created_at > now() - interval '1 day') < 3 then
      perform focusboard.enqueue(v, 'Work Clock alerts are on',
        'You''ll get an email here when a friend passes you, when you''re late to clock in, and when someone taunts you.'
        || E'\n\n' || 'Tip: add clock@teamangeleski.com.au to your contacts so these land in your inbox, not spam.');
    end if;
  end if;
  return json_build_object('ok', true);
end $$;

-- Only the service role can store the mail key.
create or replace function focusboard.set_mail_key(p_key text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from vault.secrets where name = 'focusboard_resend') then
    perform vault.update_secret((select id from vault.secrets where name = 'focusboard_resend'), p_key);
  else
    perform vault.create_secret(p_key, 'focusboard_resend', 'Resend key for Work Clock emails');
  end if;
  return json_build_object('ok', true);
end $$;
create or replace function public.focus_admin_set_mail_key(p_key text) returns json
language sql security definer set search_path = '' as $$ select focusboard.set_mail_key(p_key) $$;

revoke all on function focusboard.local_now(int), focusboard.promote(uuid),
  focusboard.due_at(focusboard.members, date), focusboard.late_for(timestamptz, timestamptz),
  focusboard.hm(int), focusboard.clock_text(int), focusboard.enqueue(text, text, text),
  focusboard.flush(), focusboard.tick(), focusboard.set_mail_key(text) from public, anon, authenticated;
revoke all on function public.focus_admin_set_mail_key(text) from public, anon, authenticated;
grant execute on function public.focus_admin_set_mail_key(text) to service_role;
revoke all on function public.focus_schedule(uuid, uuid, int, int), public.focus_set_email(uuid, uuid, text) from public;
grant execute on function public.focus_schedule(uuid, uuid, int, int), public.focus_set_email(uuid, uuid, text),
  public.focus_sync(uuid, uuid, date, int, int, int, int, boolean, int),
  public.focus_taunt(uuid, uuid, uuid, text, date) to anon;

select cron.unschedule('focusboard-tick') where exists (select 1 from cron.job where jobname = 'focusboard-tick');
select cron.schedule('focusboard-tick', '* * * * *', 'select focusboard.tick()');

-- To remove v1.3: select cron.unschedule('focusboard-tick'); then drop the functions above.
-- pg_net and pg_cron were enabled for this; drop them only if nothing else uses them.
