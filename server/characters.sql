-- Darnell Jr. v1.6: the day's winner dresses up.
-- Yesterday's winner (top score after lateness, 10+ minutes) picks one of eight original
-- characters for today and can give it any name (up to 24 characters). Everyone on the board
-- sees it in the race, on the winner's clock, and on taunts (pop-ups and emails).
-- Applied live with execute_sql; see focusboard.won_yesterday, public.focus_set_character,
-- and the character fields added to public.focus_sync and public.focus_taunt.

alter table focusboard.members add column if not exists character text;
alter table focusboard.members add column if not exists character_name text
  check (character_name is null or char_length(character_name) between 1 and 24);
alter table focusboard.members add column if not exists character_day date;
-- Characters: boss, sergeant, professor, techbro, nana, gentleman, scientist, champ.
-- Live definitions: select pg_get_functiondef('public.focus_set_character(uuid,uuid,text,date,text)'::regprocedure);

-- v1.7: only the five legends (obama, mlk, tyson, fifty, icecube), and they must be unlocked:
-- each day you win unlocks one of your choice, kept for good (focusboard.unlocks). On a day you
-- won, you can wear any you've unlocked. focus_sync returns `unlocked` and `can_unlock`.
create table if not exists focusboard.unlocks (
  member_id uuid not null references focusboard.members(id) on delete cascade,
  character text not null,
  unlocked_on date not null,
  primary key (member_id, character)
);
