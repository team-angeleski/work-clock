-- Darnell Jr. 1.9: instant taunts and "friend started" alerts.
-- Apps call public.focus_inbox every 20 seconds: unseen taunts (shown at once, if the person is at
-- their computer) and friends who just started focusing (focusboard.events, handed over once).
-- focus_sync adds a 'started' event for everyone else on the board when someone goes from not
-- focusing to focusing, at most once per 20 minutes.
-- Live definitions: select pg_get_functiondef('public.focus_inbox(uuid,uuid)'::regprocedure);
create table if not exists focusboard.events (
  id bigserial primary key,
  to_member uuid not null references focusboard.members(id) on delete cascade,
  from_member uuid not null references focusboard.members(id) on delete cascade,
  kind text not null,
  created_at timestamptz not null default now(),
  seen_at timestamptz
);
