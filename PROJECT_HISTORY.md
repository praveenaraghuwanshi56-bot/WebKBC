# WebKbc: project history and hand-over guide

Purpose of this file: so the project can be continued in a new chat, with a different AI, or by another developer, without losing anything. Keep it updated after each change (see the last section).

> Never write passwords or API keys in this file. The Supabase URL and anon key are public by design and live in `public/index.html`.

## 1. What the project is

**WebKbc** is a KBC-style quiz website with a Study Mode, built for an Indian school audience (classes 5 to 12 plus General GK).

- Hosting: Cloudflare Pages, deployed from the `public/` folder of a private GitHub repo.
- Backend: Supabase (Postgres, SQL functions, and one Edge Function named `generate`).
- Question writer: Google Gemini through the Edge Function, using ONE master key that the admin stores in the database.
- Front end: one HTML file with no build step (`public/index.html`).

## 2. Current architecture (the important decisions)

| Decision | Why |
|---|---|
| One master Gemini key, stored in `app_settings`, read only by the Edge Function | Players never see or need a key. A key in browser code would leak. |
| Questions with answers are stored in `game_sessions`; the browser gets text and options only | Players can't read answers from the page, so scores can't be faked. |
| Every table is locked (RLS on, no policies, access revoked). All access goes through `SECURITY DEFINER` SQL functions that check a session token | The public anon key can't read or write anything directly. |
| The server checks answer order, the timer (+4 s grace), lifelines used once, winnings, and writes the leaderboard row | Anti-cheat. The client is never trusted. |
| Custom username and password accounts (not Supabase Auth), copied from the owner's other website | Owner's choice. No email needed. Passwords hashed with bcrypt via pgcrypto. |
| One device at a time; 5 wrong passwords locks 15 minutes | Mirrors the owner's other site. |
| Leaderboard ranks class level first (General GK > 12th > ... > 5th), then score, then date; one row per player (their best at their highest level) | Owner's rule: higher-level points count more than lower-level points, whatever the numbers. |
| KBC topics are chosen on the page and sent as ids; the Edge Function validates them against its own `CATEGORIES` list. Choosing every topic equals the normal full mix and reuses its cache | Keeps cache keys tidy (`kbc:<class>:<sorted ids>`). Topic ids exist in two places: `CATEGORIES` in `index.ts` and `CATS` in `index.html`. Keep them in step. |
| CBSE quizzes run as mode `study` (10 questions, `study_submit`), with the class stored as `"<class> · <subject>"`; they are not ranked | Reuses the existing server-side grading. Only KBC is ranked. |
| Chapter lists come from Gemini, are cached in `curriculum_cache` for 120 days, and players can add their own chapter names | The real textbooks aren't available to the app and NCERT revises books in stages, so a hard-coded list would go stale or be wrong. The screen says plainly that the AI's version may differ and points to uploading the real chapter PDF. |
| Player-typed subject and chapter names are reduced to letters, numbers, spaces and simple punctuation before they enter a prompt, and at most 8 chapters are used | Limits prompt injection and keeps prompts short. |
| Subject lists per class live only in `index.html` (`SUBJECTS`); the function accepts any sanitised subject text | One place to edit when NCERT adds or renames a subject. |
| Difficulty (easy, medium, hard) applies to KBC and CBSE quizzes, not to "My notes". Easy keeps the original prompt text and the original cache keys byte for byte; medium and hard add `:medium` / `:hard` to the key | The owner asked that Easy stay exactly as hard as it was, so existing saved quizzes and behaviour are untouched. |
| The leaderboard ranks class level, then difficulty, then score; the row stores the difficulty; each player shows once at their highest level and hardest difficulty | Otherwise everyone would play Easy for the biggest score. Same spirit as the owner's rule that higher-level points count more. It is one `order by` in `leaderboard()` if this ever needs changing. |
| The edge function passes `p_difficulty` to the database only when it is not easy | Easy games keep working even if the function is deployed before patch 06. |
| Only KBC scores go on the leaderboard | Study quizzes can be made easy by uploading trivial notes, so ranking them would be unfair. |
| Quiz cache (`cached_quizzes`), N sets per level then reuse | Saves the Gemini free-tier quota. Admin can change N or clear it. |
| Model name is a free-text admin setting | Google retires models; no code change needed next time. |
| Read-aloud uses the browser's Web Speech API, with all options set by the admin | Free, no key, no quota. Voices vary by device. |
| Lifeline answers (audience poll, phone a friend) are spoken after the lifeline is used; 50:50 and the answer reveal are never spoken. Lifeline speech follows the player's Auto-read switch | The brief asked for it; reveals use tunes only. |
| Gemini calls make exactly ONE attempt per model: the Admin model first, then `GEMINI_FALLBACK_MODEL` (default `gemini-3.1-flash-lite`). Overload (503, other 5xx), timeout (45 s), network errors, a 404 on the fallback and answers that fail validation move to the next model; 429, 400/403 and a 404 on the main model stop at once. If both fail, a saved set for the exact same cache key is played; otherwise a clear error | Keeps players able to start a game during an outage without wasting quota on repeats. The main model stays the admin-editable setting (not hard-coded), so a retired model is still a one-field fix. A saved set is only used for the identical class, topics and difficulty, never a different one. |
| Sound effects are synthesised with Web Audio (no files); the player can mute them | No assets to host or license. |
| `kbc_ready` moves the clock start to when the question is shown | The suspense pause plus reveal (up to about 7 s) would otherwise cut into the next question's time. |
| Extra clock seconds for players who listen (admin-set, capped on the server) | Reading aloud takes time. The client claims `p_extra`; the server caps it at the admin's value and ignores it if read-aloud is off. |

## 3. Files

```
public/index.html                        Entire site. Settings at the top: SUPABASE_URL, SUPABASE_ANON_KEY.
schema.sql                               Complete database for a NEW project (includes everything in patches/).
patches/01-profile-update.sql            update_profile, rename_user, delete_account.
patches/02-speech-and-timer.sql          app_settings.tts, get_config, admin_save_tts, kbc_answer with p_extra.
patches/03-lock-in-clock.sql             game_sessions.ready, kbc_ready, kbc_answer resets ready (fair clock for the lock-in pause). Needs patch 02.
patches/04-leaderboard-by-level.sql      _tier() helper; leaderboard() ranks class level first, then score.
patches/05-curriculum-cache.sql          curriculum_cache table (saved chapter lists); admin_clear_cache also clears it.
patches/07-remove-seen-questions.sql     drops the unused seen_questions table (only needed if it exists on your database).
patches/06-difficulty.sql                difficulty columns on game_sessions and leaderboards, _diff_rank(), create_game(..., p_difficulty), leaderboard ranks class level, then difficulty, then score. Run BEFORE deploying the matching Edge Function.
supabase/functions/generate/index.ts     Edge Function: gate, cache, Gemini call, log, create_game.
README.md                                Public-facing setup and usage.
PROJECT_HISTORY.md                       This file.
```

### Database objects (all in schema `public`)
- **Tables:** `app_users`, `app_sessions`, `app_settings` (one row, id = 1), `game_sessions`, `leaderboards`, `cached_quizzes`, `api_logs`.
- **Callable by the browser (anon key):** `signup`, `login`, `check_session`, `logout`, `change_password`, `update_profile`, `rename_user`, `delete_account`, `leaderboard`, `kbc_answer`, `kbc_quit`, `kbc_lifeline`, `kbc_ready`, `study_submit`, `get_config`, and the admin set `admin_get_settings`, `admin_save_settings`, `admin_save_tts`, `admin_remove_key`, `admin_clear_cache`, `admin_logs`, `admin_users`, `admin_delete_user`.
- **Service role only (the Edge Function):** `gate`, `create_game`.
- **Internal helpers:** `_uid`, `_is_admin`, `_ladder`, `_safe`, `_finish`, `_user_json`.
- **Parameters** of all browser-callable functions are prefixed `p_` (the client passes them by name).

### Game rules (enforced in SQL)
- 15 questions. Prizes: 1,000 / 2,000 / 3,000 / 5,000 / 10,000 / 20,000 / 40,000 / 80,000 / 1,60,000 / 3,20,000 / 6,40,000 / 12,50,000 / 25,00,000 / 50,00,000 / 1,00,00,000.
- Safe havens: after question 5 (₹10,000) and question 10 (₹3,20,000). A wrong or late answer pays the last safe haven.
- Time per question: 30 s (Q1 to 5), 45 s (Q6 to 10), 60 s (Q11 to 15), plus 4 s grace, plus read-aloud extra if claimed.
- **Lock in:** an option tap only selects it; the player presses Lock. The answer is sent to the server at that moment (this stops the clock honestly) while the browser holds the reveal for a random 2 to 5 second pause (`SUSPENSE` in `index.html`). If the timer ends with an option selected, it is locked automatically; with nothing selected the answer is -1 and counts as wrong.
- **Clock start:** a question's server clock starts when the browser calls `kbc_ready` (the question is on screen), once, and only within 15 s of the previous answer. If it is never called, the older start time (the moment of the previous answer) applies, which is stricter.
- Starting a new game while one is active ends the old one at its safe haven. Refreshing mid-game does the same.

## 4. Live deployment state (tick what applies to your project)

- [ ] Supabase project created; `schema.sql` run (or v1 then patches)
- [ ] Patch `01-profile-update.sql` applied
- [ ] Patch `02-speech-and-timer.sql` applied
- [ ] Patch `03-lock-in-clock.sql` applied (run AFTER 02)
- [ ] Patch `04-leaderboard-by-level.sql` applied
- [ ] Patch `05-curriculum-cache.sql` applied (needed for the CBSE chapter lists)
- [ ] Patch `06-difficulty.sql` applied (order for v2.9: SQL 06, then the Edge Function, then SQL 07, then `index.html`)
- [ ] Patch `07-remove-seen-questions.sql` applied (only after the new Edge Function is deployed)
- [ ] Edge Function `generate` redeployed after v2.10 (the version in this project, not a copy edited elsewhere)
- [ ] Optional secret `GEMINI_FALLBACK_MODEL` set in Supabase → Edge Functions → Secrets
- [ ] (v2.9 note) Edge Function `generate` redeployed after v2.9 (topics, CBSE quizzes, chapter lists and difficulty live in it)
- [ ] Edge Function `generate` deployed (latest `index.ts`); Verify JWT setting: ______
- [ ] Admin password changed from the starting one
- [ ] Gemini key saved in Admin, and the old key from the chat history revoked
- [ ] Model name set in Admin (currently used: `gemini-3.1-flash-lite`; `gemini-3.8-flash` also valid in Nov 2026)
- [ ] GitHub repo is **private**
- [ ] Cloudflare Pages: build output directory `public`, auto-deploys from `main`

## 5. History (oldest first)

| Version | What happened |
|---|---|
| v1 | First build from the owner's brief: single HTML file, each user pasted their own Gemini key into a settings modal, KBC mode (15-level ladder, 50:50, audience poll, phone a friend), Study mode (pdf.js), passcode-protected console (`2468`), anonymous Supabase scores. |
| v2 | Rebuilt for one master key and real anti-cheat. Added accounts, server-side scoring, Edge Function, admin console (key, limits, request log, users), classes 5th to 12th, and a UI based on the owner's other website (fonts, pill tabs, cards, avatar menu, sign-in card). Passcode console removed; replaced by an `admin` account. Tested against a real Postgres with attack scenarios (forged scores, replays, wrong owner, slow answers). |
| v2.1 | Gemini now issues keys that start with `AQ.` as well as `AIza`. Key validation loosened in the browser and in SQL. |
| v2.2 | Google retired `gemini-2.0-flash` (HTTP 404). The model became an editable admin text field; the Edge Function reports 404 clearly and stops retrying. |
| v2.3 | Site renamed **WebKbc**. Owner's Supabase URL and anon key were put into `index.html`. |
| v2.4 | Profile features: icon (letter or emoji), colour, username change, delete account (password required, admin protected). Fixed a bug where menu views closed themselves (click-outside check now uses `composedPath`). |
| v2.5 | Read-aloud: question, then Option A and its text, Option B and so on, with the current option highlighted. Admin "Read aloud" tab (language, voice, speed, pitch, volume, pause, labels, auto-read, extra seconds, preview). `kbc_answer` gained `p_extra`. Added README and this history. Repo restructured into `public/`, `patches/`, `supabase/`. |
| v2.6 | Lock button (select, then lock; Lock-in pause of 2 to 5 s; right and wrong tunes; unlocked selection is auto-locked when time runs out). Lifeline speech for Audience poll and Phone a friend (50:50 silent). `kbc_ready` and patch 03 so the suspense pause doesn't eat the next question's time. Speech and audio calls wrapped so a browser error can never stop a game starting. |
| v2.7 | Admin: Delete account hidden from the admin menu (the server already refused it). Pencil icon beside the username (menu and home page) opens the profile editor; custom colour picker added. Icons on the three lifelines and a "Leave with ₹X" button. Leaderboard order changed to class level first (patch 04). Many more animations (all transform, opacity and colour only). JavaScript lowered to ES2017 and CSS given fallbacks for older engines (Pale Moon, MyPal). |
| v2.8 | Topic-mixed KBC quizzes (16 topics, pick any, mixed together). Study page split into **My notes** and **CBSE / NCERT** (class, subject, optional chapters, custom chapter names). Edge Function rewritten with kinds `kbc`, `study`, `cbse`, `chapters`. Patch 05 adds `curriculum_cache`. |
| v2.9 | Easy / Medium / Hard for KBC and CBSE quizzes (selector on both pages, a difficulty badge during the game, difficulty shown on the leaderboard, ranking changed to class level then difficulty then score). Patch 06. Edge function takes `difficulty`; Easy output verified identical to v2.8. |
| v2.10 | Model fallback and saved-quiz recovery in the Edge Function (see section 2). Invalid answers no longer retry the same model: they go to the fallback. |

## 6. Lessons learned (avoid repeating these)

- **Never re-run `schema.sql` on a live database.** It drops and recreates some tables and would delete scores. Use a file from `patches/`.
- Google changes model names and key formats. Check the request log before assuming code is wrong.
- Supabase may reject the function call at the JWT check; turning Verify JWT off for `generate` is safe because the function validates the session token itself.
- Browser caching causes "my fix didn't work" reports. Check with Ctrl+Shift+R or `view-source:`.
- Copying text from collapsed sections (like the log's Request/Response panels) copies nothing; expand them first.
- Changing a SQL function's parameter list creates an overload unless the old one is dropped first (this is why patch 02 drops the old `kbc_answer`).
- A server clock that starts when an answer is saved is unfair once the browser adds delays (suspense, reveal). Start it when the question is displayed (`kbc_ready`) and cap how late that signal may arrive.
- Wrap every speech and audio call in try/catch: an exception there must never stop a game from starting.
- **Keep the script at ES2017.** No `?.`, `??`, object spread (`{...a}`), or bare `catch {` in `public/index.html`; use `Object.assign` and `catch (_e)`. Check with `acorn` (`ecmaVersion: 2017`). Supabase-js 2.45.4 itself needs ES2017; pdf.js needs newer.
- CSS: put a plain fallback before any `clamp()`; use `top/right/bottom/left` instead of `inset`; flex `gap` has a margin fallback inside `@supports not (gap:1px)`.
- The Edge Function can be tested outside Supabase: transpile `index.ts` with esbuild and run it in Node with a fake `Deno`, a fake Supabase client and a fake `fetch` for Gemini. This caught nothing in v2.8 but checks prompts, sanitising, caching and error codes in seconds.
- **Never leave `create_game` callable by players.** It takes the questions as an argument, so anyone who can call it can write their own questions and score a perfect game. It must stay service-role only. Another AI once added a five-argument copy of it by hand, granted it to `service_role`, and did not revoke the default access for everyone else, which left it open to any signed-in player. Patch 06 now closes every version of it. Likewise any table created by hand needs row level security on and `revoke all ... from anon, authenticated`, because Supabase gives new tables to the public key by default.
- **Do not paste in an Edge Function edited by another tool or AI without comparing it to this project's `index.ts`.** The fallback change was described by another AI, but its source reached us only as a summary, and its description suggested it was built on the old function that tracked seen questions. This project's `index.ts` already contains the fallback, tested, on top of the correct base.
- **During a Gemini outage every attempt is logged and counts toward the hourly and daily limits**, including failed ones, so players retrying during an outage use their allowance twice as fast (two attempts per start). If that becomes a problem, change `gate()` to ignore rows with status 503.
- **A deployed Edge Function and the database must be changed together.** An older Edge Function (from an interrupted attempt) called `create_game` with an extra argument and used a `seen_questions` table, neither of which existed on the live database, so every game failed with "Couldn't start the game" (HTTP 404 on the RPC). Always check the function version matches the SQL patches before debugging anything else.
- Check a requested change touches only what was asked. An earlier, interrupted attempt at this feature also added per-player tracking of seen questions and rewrote the Easy prompts; both were removed. Easy must stay identical to the previous behaviour, so compare old and new prompts directly (see the tests in section 7) when changing prompts.
- Test pages over `http://`, not `file://`: headless Chromium sometimes loses localStorage across reloads on `file://`, which looks like a bug but isn't.
- iPhones may block automatic speech unless it follows a tap. The code "unlocks" speech on the Play button; the Read aloud button always works.

## 7. Testing notes

How it was verified (no live Supabase or Gemini was available to the builder):
- SQL was loaded into a real Postgres (with a stand-in for `pgcrypto`) and attacked as the `anon` and `service_role` roles: direct table access, forged leaderboard rows, replayed and out-of-order answers, another user's game, slow answers, lifeline reuse, parameter abuse, lockout, single-device sessions.
- The front end was run in headless Chromium against a stubbed Supabase client, and speech against a recording stub that captured the exact spoken order.
- Not tested: real Gemini output quality, real device voices, Cloudflare deployment.

## 8. Ideas not built yet

- Admin password reset for players (there is no recovery today).
- Resume an interrupted KBC game.
- A personal history page (the data is in `game_sessions`).
- Read the explanation aloud after answering.
- Admin controls for the suspense pause range and the volume of sound effects.
- Only the first question's text is needed at the start: sending questions one at a time would stop players from looking ahead.
- Fresher questions between games (mixing questions from several saved sets, or remembering which questions a player has seen). Not built; it needs per-player storage, so decide deliberately.
- A small topic label on each question (the model could return one; `create_game` would need to pass it through).
- Admin-editable curriculum (chapter lists and subjects stored in the database instead of AI-written).
- Search-grounded chapter lists (Gemini with Google Search) if that works with structured output on the model in use.
- Optionally fall back on 429 too (the fallback model has its own quota on the free tier) and on a retired main model (404), instead of stopping. Both are deliberately not done yet.
- Real-device testing on MyPal / Pale Moon (only syntax and CSS were checked, not run).
- Hindi-language questions (needs a prompt change and a Hindi voice).
- Per-IP rate limiting in the Edge Function.
- Shared quiz links or timed class competitions.

## 9. How to continue with a new chat or a different AI

1. Open a new chat and upload: `PROJECT_HISTORY.md`, `README.md`, `public/index.html`, `schema.sql`, `supabase/functions/generate/index.ts`, and the files in `patches/`.
2. Paste this message:

```
I'm continuing an existing project called WebKbc. Please read PROJECT_HISTORY.md and README.md first,
then the code files. Follow the decisions in section 2 (server-side scoring, locked tables, master Gemini
key only in the database, all browser access through SECURITY DEFINER functions with p_ parameters).
Rules: never ask me to re-run schema.sql on my live database; give me a new numbered file in patches/
for any database change; keep my Supabase URL and anon key already set in public/index.html; never put
secrets in the repo. When you finish a change, give me the updated files and the exact steps to apply them,
and add a line to the history table in PROJECT_HISTORY.md.
My request: <describe what you want>
```

3. Check that the AI reads the live state (section 4) and asks which patches you have applied if unsure.

## 10. Keeping this file up to date

After every change: add a row to the table in section 5, tick or add items in section 4, and add any new lesson to section 6. If you change the database, add a new `patches/NN-name.sql` and also fold the same change into `schema.sql` so new installs match.

## 11. Integrity check: finding games with questions the generator did not write

Run this in the Supabase SQL Editor. It lists scored KBC games containing any question text that never appeared in a saved quiz set. Normal games are built from saved sets, so a flagged game is suspicious. (False alarms are possible for old games if you have since used "Clear quiz cache".) To remove a cheater's scores, delete the player in Admin → Users.

```sql
select g.id, u.username, g.class_level, g.score, g.created_at
  from game_sessions g join app_users u on u.id = g.user_id
 where g.mode = 'kbc' and g.score > 0
   and exists (select 1 from jsonb_array_elements(g.questions) e
                where not exists (select 1 from cached_quizzes c, jsonb_array_elements(c.questions) ce where ce->>'q' = e->>'q'))
 order by g.created_at desc
```
