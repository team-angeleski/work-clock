-- Work Clock v1.4: one account per email, on as many computers as you like.
--
-- Each computer reports its own focus for the day; the server adds them up. A computer can
-- only add as much as real time allows since it last checked in, and the day's total can never
-- exceed the time since local midnight. Score (bonuses included) is now worked out here,
-- not trusted from the app.
-- Signing in on another computer: a 6-digit code goes to the account's email.

create table if not exists focusboard.device_days (
  member_id uuid not null references focusboard.members(id) on delete cascade,
  device_id uuid not null,
  day date not null,
  reported int not null default 0,   -- the computer's own count for the day, as last reported
  credited int not null default 0,   -- what the server accepted from it
  updated_at timestamptz not null default now(),
  primary key (member_id, device_id, day)
);
alter table focusboard.device_days enable row level security;

alter table focusboard.members add column if not exists focus_until timestamptz;   -- "focusing" dot, any computer
alter table focusboard.members add column if not exists focus_device uuid;
alter table focusboard.days add column if not exists blown boolean not null default false;  -- socials before 1pm

create unique index if not exists members_email_unique on focusboard.members (lower(email)) where email is not null;

create table if not exists focusboard.logins (
  id bigserial primary key,
  email text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0,
  created_at timestamptz not null default now()
);
alter table focusboard.logins enable row level security;

-- One account per email.
do $$
declare src text;
begin
  src := pg_get_functiondef('focusboard.add_member(uuid,text,text,text,int,int)'::regprocedure);
  src := replace(src, '  v := focusboard.check_email(p_email);',
    '  v := focusboard.check_email(p_email);
  if exists (select 1 from focusboard.members where lower(email) = v) then
    raise exception ''That email already has an account. Sign in with it instead.'';
  end if;');
  execute src;
  src := pg_get_functiondef('public.focus_set_email(uuid,uuid,text)'::regprocedure);
  src := replace(src, '  if v is distinct from me.email then',
    '  if exists (select 1 from focusboard.members where lower(email) = v and id <> me.id) then
    raise exception ''Another account already uses that email'';
  end if;
  if v is distinct from me.email then');
  execute src;
end $$;

-- The 1.3 sync (9 arguments) is dropped once every app is on 1.4:
--   drop function public.focus_sync(uuid, uuid, date, int, int, int, int, boolean, int);

create or replace function public.focus_sync(
  p_member uuid, p_secret uuid, p_day date, p_seconds int, p_score int,
  p_level int, p_streak int, p_focusing boolean, p_tz_minutes int,
  p_device uuid, p_blown boolean)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; dev uuid; dd focusboard.device_days; prev focusboard.days;
        tz int; local_now timestamp; midnight timestamptz; since timestamptz;
        delta int; allowed int; added int; accepted int; early int; morning int; blown_ boolean;
        score_ int; due_ timestamptz; clock_ timestamptz; late_ int; before_net int; after_net int; fr record; legacy int := 0;
begin
  me := focusboard.authed(p_member, p_secret);
  if p_day not between current_date - 2 and current_date + 2 then raise exception 'Check your computer''s date'; end if;

  -- Time zone is locked at the first check-in, so it can't be changed to fake an early morning.
  tz := coalesce(me.tz_minutes, least(greatest(coalesce(p_tz_minutes, 0), -720), 840));
  if me.tz_minutes is null then update focusboard.members set tz_minutes = tz where id = me.id; end if;
  me := focusboard.promote(me.id);
  local_now := focusboard.local_now(tz);
  midnight := (p_day::timestamp - make_interval(mins => tz)) at time zone 'UTC';
  dev := coalesce(p_device, '00000000-0000-0000-0000-000000000000'::uuid);

  select * into dd from focusboard.device_days where member_id = me.id and device_id = dev and day = p_day;
  select * into prev from focusboard.days where member_id = me.id and day = p_day;

  -- This computer may add what it counted since its last report, but no faster than real time,
  -- and the whole day can't hold more than the time since midnight.
  delta := greatest(coalesce(p_seconds, 0) - coalesce(dd.reported, 0), 0);
  -- First report under per-computer counting, on a day that already has time from before: that
  -- time came from this computer, so don't count it twice.
  if dd.member_id is null and prev.member_id is not null
     and not exists (select 1 from focusboard.device_days where member_id = me.id and day = p_day) then
    delta := greatest(coalesce(p_seconds, 0) - prev.seconds, 0);
    legacy := prev.seconds;
  end if;
  since := greatest(coalesce(dd.updated_at, midnight), midnight);
  allowed := greatest(ceil(extract(epoch from now() - since))::int, 0) + 90;
  added := least(delta, allowed,
                 greatest(ceil(extract(epoch from now() - midnight))::int + 90 - coalesce(prev.seconds, 0), 0),
                 57600 - coalesce(prev.seconds, 0));
  added := greatest(added, 0);
  accepted := coalesce(prev.seconds, 0) + added;

  insert into focusboard.device_days (member_id, device_id, day, reported, credited, updated_at)
  values (me.id, dev, p_day, greatest(coalesce(p_seconds, 0), 0), added + legacy, now())
  on conflict (member_id, device_id, day) do update
    set reported = excluded.reported, credited = focusboard.device_days.credited + excluded.credited, updated_at = now();

  -- Bonuses, worked out here: before 9am counts 1.5x; a clean morning (no socials before 1pm on
  -- any computer, and an hour of focus by then) is worth 30 minutes once 1pm has passed.
  early := coalesce(prev.early_ok, 0);
  morning := coalesce(prev.morning_ok, 0);
  if local_now::date = p_day and extract(hour from local_now) < 9 then early := early + added; end if;
  if local_now::date = p_day and extract(hour from local_now) < 13 then morning := morning + added; end if;
  blown_ := coalesce(prev.blown, false) or coalesce(p_blown, false);
  score_ := least(accepted + early / 2
                  + case when (extract(hour from local_now) >= 13 or local_now::date > p_day)
                              and morning >= 3600 and not blown_ then 1800 else 0 end, 90000);

  -- Clocked in once the first 5 minutes are done.
  clock_ := prev.clock_in;
  if clock_ is null and accepted >= 300 and local_now::date = p_day then
    clock_ := now() - make_interval(secs => accepted);
  end if;
  due_ := focusboard.due_at(me, p_day);
  late_ := coalesce(prev.late_min, 0);
  if local_now::date = p_day and due_ is not null and me.created_at < due_ and (clock_ is not null or now() > due_) then
    late_ := focusboard.late_for(due_, clock_);
  end if;

  insert into focusboard.days (member_id, day, seconds, score, early_ok, morning_ok, blown, clamped, clock_in, late_min, updated_at)
  values (me.id, p_day, accepted, score_, early, morning, blown_, delta - added, clock_, late_, now())
  on conflict (member_id, day) do update
    set seconds = excluded.seconds, score = excluded.score, early_ok = excluded.early_ok,
        morning_ok = excluded.morning_ok, blown = excluded.blown,
        clamped = focusboard.days.clamped + excluded.clamped,
        clock_in = coalesce(focusboard.days.clock_in, excluded.clock_in),
        late_min = excluded.late_min, updated_at = now();

  update focusboard.members
     set level = coalesce(p_level, level), streak = coalesce(p_streak, streak),
         focusing = coalesce(p_focusing, false),
         focus_until = case when coalesce(p_focusing, false) then now() + interval '3 minutes'
                            when focus_device = dev then null else focus_until end,
         focus_device = case when coalesce(p_focusing, false) then dev else focus_device end,
         last_seen = now()
   where id = me.id;

  -- Overtakes: email a friend the moment you pass them (3 a day at most, 7am to 10pm).
  before_net := greatest(coalesce(prev.score, 0) - coalesce(prev.late_min, 0) * 60, 0);
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
                            'next_from', me.next_from, 'name', me.name),
    -- My other computers: today's time they added, and the last two weeks' totals across all of them.
    'mine', json_build_object(
        'others_today', accepted - (select credited from focusboard.device_days
                                     where member_id = me.id and device_id = dev and day = p_day),
        'history', (select coalesce(json_object_agg(h.day::text, h.seconds), '{}'::json)
                      from focusboard.days h where h.member_id = me.id and h.day between p_day - 14 and p_day - 1)),
    'members', (select coalesce(json_agg(row_to_json(x) order by x.score desc, x.name), '[]'::json) from (
        select m.id, m.name, m.level, m.streak,
               coalesce(m.focus_until > now(), false) as focusing,
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

-- Sign in on another computer: step 1, email a code.
create or replace function public.focus_login_start(p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare v text; m focusboard.members; code text;
begin
  v := focusboard.check_email(p_email);
  select * into m from focusboard.members where lower(email) = v;
  if m.id is null then raise exception 'No account uses that email. Set up a new one instead.'; end if;
  if (select count(*) from focusboard.logins where email = v and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many codes. Try again in an hour.';
  end if;
  code := lpad(floor(random() * 1000000)::int::text, 6, '0');
  insert into focusboard.logins (email, code_hash, expires_at)
  values (v, encode(extensions.digest(v || ':' || code, 'sha256'), 'hex'), now() + interval '10 minutes');
  perform focusboard.enqueue(v, 'Your Work Clock code: ' || code,
    'Enter ' || code || ' on your other computer to sign in as ' || m.name || '. It expires in 10 minutes.'
    || E'\n\n' || 'If this wasn''t you, ignore this email. Nobody can sign in without the code.');
  perform focusboard.flush();
  delete from focusboard.logins where created_at < now() - interval '1 day';
  return json_build_object('ok', true);
end $$;

-- Step 2: trade the code for the account.
create or replace function public.focus_login_finish(p_email text, p_code text)
returns json language plpgsql security definer set search_path = '' as $$
declare v text; l focusboard.logins; m focusboard.members;
begin
  v := focusboard.check_email(p_email);
  select * into l from focusboard.logins where email = v and expires_at > now() order by id desc limit 1;
  if l.id is null then return json_build_object('error', 'That code has expired. Send a new one.'); end if;
  if l.attempts >= 5 then return json_build_object('error', 'Too many tries. Send a new code.'); end if;
  if l.code_hash <> encode(extensions.digest(v || ':' || trim(coalesce(p_code, '')), 'sha256'), 'hex') then
    -- Returned, not raised, so the failed attempt is saved and the 5-try limit holds.
    update focusboard.logins set attempts = attempts + 1 where id = l.id;
    return json_build_object('error', 'That code isn''t right');
  end if;
  delete from focusboard.logins where email = v;
  select * into m from focusboard.members where lower(email) = v;
  return json_build_object('member_id', m.id, 'secret', m.secret, 'name', m.name,
                           'code', (select code from focusboard.groups where id = m.group_id));
end $$;

revoke all on function public.focus_sync(uuid, uuid, date, int, int, int, int, boolean, int, uuid, boolean),
  public.focus_login_start(text), public.focus_login_finish(text, text) from public;
grant execute on function public.focus_sync(uuid, uuid, date, int, int, int, int, boolean, int, uuid, boolean),
  public.focus_login_start(text), public.focus_login_finish(text, text) to anon;
