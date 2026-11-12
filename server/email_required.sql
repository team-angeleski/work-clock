-- Work Clock v1.3: an email is part of your account. Joining needs one, and it can be
-- changed but not removed: the race reaches you on your phone whether or not your Mac is on.
-- Joining also sets your office hours straight away (your first day is never counted late).

create or replace function focusboard.check_email(p_email text) returns text
language plpgsql immutable set search_path = '' as $$
declare v text := lower(trim(coalesce(p_email, '')));
begin
  if v = '' then raise exception 'An email is required. It''s how the race reaches your phone.'; end if;
  if char_length(v) > 120 or v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That email doesn''t look right';
  end if;
  return v;
end $$;

create or replace function focusboard.add_member(g uuid, p_name text, p_platform text, p_email text,
                                                 p_start_min int, p_workdays int) returns focusboard.members
language plpgsql security definer set search_path = '' as $$
declare m focusboard.members; v text;
begin
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 20 then raise exception 'Name must be 1-20 characters'; end if;
  v := focusboard.check_email(p_email);
  if coalesce(p_start_min, 540) not between 240 and 840 then raise exception 'Pick a start time between 4am and 2pm'; end if;
  if coalesce(p_workdays, 31) not between 0 and 127 then raise exception 'Pick your workdays'; end if;
  insert into focusboard.members (group_id, name, platform, email, start_min, workdays)
  values (g, trim(p_name), p_platform, v, coalesce(p_start_min, 540) / 5 * 5, coalesce(p_workdays, 31))
  returning * into m;
  perform focusboard.enqueue(v, 'Welcome to Work Clock, ' || m.name,
    'Alerts for the race come here: when a friend passes you, when you''re late to clock in, and when you get taunted.'
    || E'\n\n' || 'Tip: add clock@teamangeleski.com.au to your contacts so these land in your inbox, not spam.');
  return m;
end $$;

drop function if exists public.focus_create(text, text);
drop function if exists public.focus_join(text, text, text);

create or replace function public.focus_create(p_name text, p_platform text, p_email text, p_start_min int, p_workdays int)
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid; m focusboard.members; c text; alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  perform focusboard.check_email(p_email);
  loop
    c := '';
    for i in 1..6 loop c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from focusboard.groups where code = c);
  end loop;
  insert into focusboard.groups (code) values (c) returning id into g;
  m := focusboard.add_member(g, p_name, p_platform, p_email, p_start_min, p_workdays);
  return json_build_object('member_id', m.id, 'secret', m.secret, 'code', c);
end $$;

create or replace function public.focus_join(p_code text, p_name text, p_platform text, p_email text, p_start_min int, p_workdays int)
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid; m focusboard.members;
begin
  select id into g from focusboard.groups where code = upper(trim(p_code));
  if g is null then raise exception 'No board with that code'; end if;
  if (select count(*) from focusboard.members where group_id = g) >= 5 then raise exception 'That board is full (5 max)'; end if;
  if exists (select 1 from focusboard.members where group_id = g and lower(name) = lower(trim(p_name))) then
    raise exception 'Someone on that board already uses that name';
  end if;
  m := focusboard.add_member(g, p_name, p_platform, p_email, p_start_min, p_workdays);
  return json_build_object('member_id', m.id, 'secret', m.secret, 'code', upper(trim(p_code)));
end $$;

-- Change your email. It can't be removed.
create or replace function public.focus_set_email(p_member uuid, p_secret uuid, p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare me focusboard.members; v text;
begin
  me := focusboard.authed(p_member, p_secret);
  v := focusboard.check_email(p_email);
  if v is distinct from me.email then
    update focusboard.members set email = v where id = me.id;
    if (select count(*) from focusboard.outbox where to_email = v and created_at > now() - interval '1 day') < 3 then
      perform focusboard.enqueue(v, 'Work Clock alerts are on',
        'You''ll get an email here when a friend passes you, when you''re late to clock in, and when someone taunts you.'
        || E'\n\n' || 'Tip: add clock@teamangeleski.com.au to your contacts so these land in your inbox, not spam.');
    end if;
  end if;
  return json_build_object('ok', true);
end $$;

revoke all on function focusboard.check_email(text), focusboard.add_member(uuid, text, text, text, int, int)
  from public, anon, authenticated;
revoke all on function public.focus_create(text, text, text, int, int), public.focus_join(text, text, text, text, int, int) from public;
grant execute on function public.focus_create(text, text, text, int, int), public.focus_join(text, text, text, text, int, int) to anon;

-- Email footer: alerts are part of the account now.
do $$
declare src text;
begin
  src := pg_get_functiondef('focusboard.flush()'::regprocedure);
  src := replace(src, 'Work Clock. To stop these emails: right-click your clock, then Email alerts, then Turn off.',
                      'Work Clock. Change your email in Work Clock → Settings → Account.');
  execute src;
end $$;
