-- APPLIED 2026-11-20. Office hours off: the punishment made work feel worse.
-- focus_sync (11 and 13 args): late_ := 0, due_min returned as null.
-- tick: the clock-in loop runs over no members (still flushes queued mail).
-- Today's and yesterday's late_min were zeroed. To bring it back, re-apply office_hours.sql
-- and clock_in_on_start.sql.

-- UPDATED 2026-11-20, same day: office hours are back as a counter, no punishment.
-- focus_sync 13 args: clock_in = p_clock_in (the app's first focused second) as soon as any time
-- is logged. due_min is returned again (friends see "due 9:00" / "in 9:07"). late_ stays 0 and
-- tick stays off, so no late points and no late emails.
