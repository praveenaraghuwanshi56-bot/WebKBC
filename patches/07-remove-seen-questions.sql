-- WebKbc: remove the unused seen_questions table
-- Only relevant if your database has this table (an older version of the Edge Function that is no longer part of the project used it).
-- Safe to run either way: if the table doesn't exist this does nothing. It held only question fingerprints, and nothing in the
-- current app reads it. It should not stay, because a table created by hand can be readable and writable by anyone with the public key.

drop table if exists public.seen_questions;
notify pgrst, 'reload schema';
