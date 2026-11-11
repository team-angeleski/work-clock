-- Focus board for the Work Clock app: a private race between up to 5 friends.
-- Yesterday's winner earns 3 taunts: short messages that pop up on friends' screens.
--
-- Isolation: everything lives in the `focusboard` schema, which the public API cannot see.
-- Apps can only call the six public focus_* functions, and each checks the member's secret key.
-- Touches no existing table. To remove it all, see the bottom of this file.

create schema if not exists focusboard;
revoke all on schema focusboard from public, anon, authenticated;

create table focusboard.groups (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  created_at timestamptz not null default now()
);

create table focusboard.members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references focusboard.groups(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 20),
  secret uuid not null default gen_random_uuid(),
  platform text,
  level int not null default 1,
  streak int not null default 0,
  focusing boolean not null default false,
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index on focusboard.members (group_id);

create table focusboard.days (
  member_id uuid not null references focusboard.members(id) on delete cascade,
  day date not null,
  seconds int not null default 0 check (seconds between 0 and 57600),
  score int not null default 0 check (score between 0 and 90000),   -- seconds with bonuses (early bird, clean morning)
  clamped int not null default 0,   -- seconds the server refused as impossible (anti-cheat)
  updated_at timestamptz not null default now(),
  primary key (member_id, day)
);

create table focusboard.taunts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references focusboard.groups(id) on delete cascade,
  from_member uuid not null references focusboard.members(id) on delete cascade,
  to_member uuid not null references focusboard.members(id) on delete cascade,
  day date not null,
  message text not null check (char_length(message) between 1 and 80),
  seen_at timestamptz,
  created_at timestamptz not null default now()
);
create index on focusboard.taunts (to_member, seen_at);
create index on focusboard.taunts (from_member, day);

alter table focusboard.groups enable row level security;
alter table focusboard.members enable row level security;
alter table focusboard.days enable row level security;
alter table focusboard.taunts enable row level security;

create or replace function focusboard.authed(p_member uuid, p_secret uuid) returns focusboard.members
language plpgsql security definer set search_path = '' as $$
declare m focusboard.members;
begin
  select * into m from focusboard.members where id = p_member and secret = p_secret;
  if m.id is null then raise exception 'Not a member of this board'; end if;
  return m;
end $$;

-- Taunts left today: 3 for each of yesterday's winners by score (ties all win), minus what they've sent.
create or replace function focusboard.taunts_left(p_member uuid, p_group uuid, p_day date) returns int
language sql stable security definer set search_path = '' as $$
  select case when p_member in (
           select d.member_id from focusboard.days d
             join focusboard.members m on m.id = d.member_id
            where m.group_id = p_group and d.day = p_day - 1 and d.seconds >= 600
              and d.score = (select max(d2.score) from focusboard.days d2
                                 join focusboard.members m2 on m2.id = d2.member_id
                                where m2.group_id = p_group and d2.day = p_day - 1))
         then greatest(3 - (select count(*) from focusboard.taunts
                             where from_member = p_member and day = p_day)::int, 0)
         else 0 end
$$;

create or replace function public.focus_create(p_name text, p_platform text)
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid; m focusboard.members; c text; alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 20 then raise exception 'Name must be 1-20 characters'; end if;
  loop
    c := '';
    for i in 1..6 loop c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from focusboard.groups where code = c);
  end loop;
  insert into focusboard.groups (code) values (c) returning id into g;
  insert into focusboard.members (group_id, name, platform) values (g, trim(p_name), p_platform) returning * into m;
  return json_build_object('member_id', m.id, 'secret', m.secret, 'code', c);
end $$;

create or replace function public.focus_join(p_code text, p_name text, p_platform text)
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid; m focusboard.members;
begin
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 20 then raise exception 'Name must be 1-20 characters'; end if;
  select id into g from focusboard.groups where code = upper(trim(p_code));
  if g is null then raise exception 'No board with that code'; end if;
  if (select count(*) from focusboard.members where group_id = g) >= 5 then
    raise exception 'That board is full (5 max)';
  end if;
  if exists (select 1 from focusboard.members where group_id = g and lower(name) = lower(trim(p_name))) then
    raise exception 'Someone on that board already uses that name';
  end if;
  insert into focusboard.members (group_id, name, platform) values (g, trim(p_name), p_platform) returning * into m;
  return json_build_object('member_id', m.id, 'secret', m.secret, 'code', upper(trim(p_code)));
end $$;

-- Report today's focus, get the race back.
-- Anti-cheat: focus can't grow faster than real time since the last check-in (plus a minute of slack),
-- so editing the app's data file or replaying requests can't add hours.
create or replace function public.focus_sync(
  p_member uuid, p_secret uuid, p_day date, p_seconds int, p_score int,
  p_level int, p_streak int, p_focusing boolean)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; prev int; allowed int; accepted int; score_ int;
begin
  me := focusboard.authed(p_member, p_secret);
  if p_day not between current_date - 2 and current_date + 2 then raise exception 'Check your Mac''s date'; end if;

  select seconds into prev from focusboard.days where member_id = me.id and day = p_day;
  allowed := coalesce(prev, 0) + ceil(extract(epoch from now() - me.last_seen))::int + 90;
  accepted := least(greatest(coalesce(p_seconds, 0), 0), allowed, 57600);
  -- Bonuses can at most make every second count 1.5x, plus the 30-minute clean-morning bonus.
  score_ := least(greatest(coalesce(p_score, 0), 0),
                  greatest(accepted, coalesce((select seconds from focusboard.days where member_id = me.id and day = p_day), 0)) * 3 / 2 + 1800);

  insert into focusboard.days (member_id, day, seconds, score, clamped, updated_at)
  values (me.id, p_day, accepted, score_, greatest(p_seconds - accepted, 0), now())
  on conflict (member_id, day) do update
    set seconds = greatest(focusboard.days.seconds, excluded.seconds),
        score = greatest(focusboard.days.score, excluded.score),
        clamped = focusboard.days.clamped + excluded.clamped,
        updated_at = now();

  update focusboard.members
     set level = coalesce(p_level, level), streak = coalesce(p_streak, streak),
         focusing = coalesce(p_focusing, false), last_seen = now()
   where id = me.id;

  return json_build_object(
    'code', (select code from focusboard.groups where id = me.group_id),
    'taunts_left', focusboard.taunts_left(me.id, me.group_id, p_day),
    'accepted', (select seconds from focusboard.days where member_id = me.id and day = p_day),
    'members', (select coalesce(json_agg(row_to_json(x) order by x.score desc, x.name), '[]'::json) from (
        select m.id, m.name, m.level, m.streak,
               (m.focusing and m.last_seen > now() - interval '6 minutes') as focusing,
               coalesce((select seconds from focusboard.days where member_id = m.id and day = p_day), 0) as today,
               coalesce((select score from focusboard.days where member_id = m.id and day = p_day), 0) as score,
               coalesce((select score from focusboard.days where member_id = m.id and day = p_day - 1), 0) as yesterday,
               coalesce((select sum(score) from focusboard.days where member_id = m.id
                          and day between p_day - 6 and p_day), 0) as week,
               (select count(*) from focusboard.taunts where from_member = me.id and to_member = m.id
                  and day = p_day)::int as taunted_today
          from focusboard.members m where m.group_id = me.group_id) x),
    'incoming', (select coalesce(json_agg(row_to_json(y) order by y.created_at), '[]'::json) from (
        select t.id, t.message, t.created_at, f.name as from_name
          from focusboard.taunts t join focusboard.members f on f.id = t.from_member
         where t.to_member = me.id and t.seen_at is null
           and t.created_at > now() - interval '3 days') y)
  );
end $$;

-- Spend one of yesterday's winnings on a friend.
create or replace function public.focus_taunt(
  p_member uuid, p_secret uuid, p_target uuid, p_message text, p_day date)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; left_ int;
begin
  me := focusboard.authed(p_member, p_secret);
  if char_length(trim(coalesce(p_message, ''))) not between 1 and 80 then
    raise exception 'Taunts are 1-80 characters';
  end if;
  if not exists (select 1 from focusboard.members where id = p_target and group_id = me.group_id and id <> me.id) then
    raise exception 'Pick a friend on your board';
  end if;
  -- Lock my row so two quick clicks can't both spend the last taunt.
  perform 1 from focusboard.members where id = me.id for update;
  left_ := focusboard.taunts_left(me.id, me.group_id, p_day);
  if left_ < 1 then raise exception 'No taunts left. Win a day to earn 3 more.'; end if;
  insert into focusboard.taunts (group_id, from_member, to_member, day, message)
  values (me.group_id, me.id, p_target, p_day, trim(p_message));
  return json_build_object('ok', true, 'taunts_left', left_ - 1);
end $$;

-- The receiving app marks a taunt once it has popped up.
create or replace function public.focus_seen(p_member uuid, p_secret uuid, p_taunt uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members;
begin
  me := focusboard.authed(p_member, p_secret);
  update focusboard.taunts set seen_at = now() where id = p_taunt and to_member = me.id and seen_at is null;
  return json_build_object('ok', true);
end $$;

create or replace function public.focus_leave(p_member uuid, p_secret uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members;
begin
  me := focusboard.authed(p_member, p_secret);
  delete from focusboard.members where id = me.id;
  delete from focusboard.groups g where g.id = me.group_id
    and not exists (select 1 from focusboard.members where group_id = g.id);
  return json_build_object('ok', true);
end $$;

revoke all on function focusboard.authed(uuid, uuid), focusboard.taunts_left(uuid, uuid, date)
  from public, anon, authenticated;
revoke all on function public.focus_create(text, text), public.focus_join(text, text, text),
  public.focus_sync(uuid, uuid, date, int, int, int, int, boolean),
  public.focus_taunt(uuid, uuid, uuid, text, date),
  public.focus_seen(uuid, uuid, uuid), public.focus_leave(uuid, uuid) from public;
grant execute on function public.focus_create(text, text), public.focus_join(text, text, text),
  public.focus_sync(uuid, uuid, date, int, int, int, int, boolean),
  public.focus_taunt(uuid, uuid, uuid, text, date),
  public.focus_seen(uuid, uuid, uuid), public.focus_leave(uuid, uuid) to anon;

-- ── Hardening (applied after the first version) ─────────────────────────────
-- Bonus points must be earned in time the server actually saw:
--   early bird only for focus added before 9am local, the clean-morning 30 only after 1pm local
--   and only once a real hour was logged before 1pm. Time zone is locked at the first check-in.

alter table focusboard.members add column tz_minutes int check (tz_minutes between -720 and 840);
alter table focusboard.days add column early_ok int not null default 0;
alter table focusboard.days add column morning_ok int not null default 0;
drop function public.focus_sync(uuid, uuid, date, int, int, int, int, boolean);
-- public.focus_sync(…, p_tz_minutes int) is then recreated; see the live definition with:
--   select pg_get_functiondef('public.focus_sync(uuid,uuid,date,int,int,int,int,boolean,int)'::regprocedure);

-- To remove the whole board:
--   drop function public.focus_create, public.focus_join, public.focus_sync,
--     public.focus_taunt, public.focus_seen, public.focus_leave;
--   drop schema focusboard cascade;
