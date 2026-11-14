# WebKbc

A KBC-style (Kaun Banega Crorepati) quiz game with a Study Mode that turns your notes into quizzes. Questions are written by Google Gemini, accounts and scores live in Supabase, and the site is a single HTML file hosted free on Cloudflare Pages.

> **Keep this repository private.** `schema.sql` creates the first admin account with a starting password. Anyone who can read the repo can read that password until you change it.

## What it does

- **KBC quiz:** 15 levels of Indian GK from ₹1,000 to ₹1 crore, with safe havens at Level 5 and Level 10, a countdown per question, and three lifelines (50:50, Audience poll, Phone a friend). Classes 5th to 12th, plus General GK.
- **Lock it in:** Tapping an option only selects it. You press **Lock answer**, wait a 2 to 5 second suspense pause, and then hear a tune for a right or wrong answer. If the timer runs out while an option is selected but not locked, that option becomes your answer.
- **Difficulty:** Every KBC quiz (and every CBSE quiz) has an **Easy / Medium / Hard** setting. Easy is exactly the quiz as it has always been, so existing saved quizzes still apply. Medium is noticeably tougher, and Hard is aimed at top students, with close wrong options. The prize ladder, timers and lifelines are the same on every difficulty.
- **Topics:** On the KBC page you can pick one or several topics (technology, software, physics, chemistry, biology, nature, geography, history, civics, economy, current affairs, sports, arts and culture, space, health, maths) and they are mixed into one quiz. No topic selected means a full mix.
- **Study mode, two tabs:**
  - **My notes:** upload a PDF or `.txt` file and get 10 multiple-choice questions with explanations, written from your material only.
  - **CBSE / NCERT:** choose a class (5th to 12th), a subject, and optionally chapters (up to 8, or add your own chapter names), and get a 10-question quiz. Questions are written by the AI from its knowledge of the NCERT textbooks that CBSE prescribes, so they can differ from the very newest edition. For exact accuracy, download the chapter PDF (free at ncert.nic.in) and use it under *My notes*.
- **Read aloud:** Questions and options are read in order (question, then Option A and its text, Option B, and so on) using the browser's built-in voices. The Audience poll and Phone a friend lifelines are spoken too ("The audience seems to think it's option B…"); 50:50 is silent, and so is the reveal, which only plays a tune. The admin controls language, voice, speed, pitch, volume, pauses and more.
- **Sounds:** The lock, right-answer and wrong-answer tunes are made in the browser, so there are no audio files to host. Players can switch them off with the **Sounds** box.
- **Accounts:** Username and password sign-up and sign-in, one active device per account, lockout after 5 wrong passwords, and a profile menu. A pencil icon next to your name opens the editor for your username, icon (a letter or emoji), and colour (10 presets or any custom colour). You can also change your password or delete your account. The admin account cannot be deleted.
- **Leaderboard:** One row per player. A higher class level always ranks above a lower one (General GK, then 12th down to 5th). Within a class level, a harder difficulty ranks above an easier one (Hard, then Medium, then Easy), and within the same difficulty the higher score wins. So ₹10,000 in 12th Class ranks above ₹3,20,000 in 5th Class, and ₹2,000 on Hard ranks above ₹3,20,000 on Easy in the same class. Scores are calculated and saved by the server, so they can't be faked from the browser.
- **Admin console:** Master Gemini key, model name, usage limits, request log, user list, quiz cache, and read-aloud settings.

## How it fits together

```
Browser (public/index.html)
   │  1. sign in, answer questions, lifelines, leaderboard ──► Supabase SQL functions (schema.sql)
   │  2. "start game" ───────────────────────────────────────► Edge Function "generate"
   │                                                              │ reads the master key from the database
   │                                                              ├──► Google Gemini (writes questions)
   │                                                              └──► stores questions WITH answers on the server
   └─ the browser only ever receives question text and options, never the answers or the Gemini key
```

Why it is built this way:
- **The Gemini key never reaches browsers.** It sits in a locked database table that only the edge function can read.
- **Scores can't be forged.** All tables are locked. The only way to change data is through functions that check your session token, the question order, the timer and each lifeline.
- **Free tier friendly.** Generated quiz sets are cached and reused, and the admin can set per-user and daily limits.

## Repository layout

```
public/index.html                        The whole website (HTML, CSS, JS). Cloudflare publishes this folder.
schema.sql                               Full database setup for a NEW Supabase project. Do not re-run on a live one.
patches/                                 Small updates for an EXISTING database, run in number order (01 to 07).
supabase/functions/generate/index.ts     The edge function that talks to Gemini.
README.md                                This file.
PROJECT_HISTORY.md                       Full history, decisions and a hand-over guide for any AI or developer.
```

## Setup from scratch

You need free accounts on GitHub, Supabase and Cloudflare, and a Gemini API key from https://aistudio.google.com/apikey.

### 1. Supabase
1. Create a project (the Mumbai region is closest for India).
2. Open **SQL Editor → New query**, paste all of `schema.sql`, and run it.
3. Open **Edge Functions → Deploy a new function → Via Editor**. Name it exactly `generate`, paste `supabase/functions/generate/index.ts`, and deploy. If calls fail with an auth error, turn **Verify JWT** off for this function. It checks the session token itself.
4. Open **Project Settings → API** and copy the **Project URL** and the **anon** key.

### 2. The website file
Open `public/index.html`, find these two lines near the top of the script, and paste your values:

```js
const SUPABASE_URL = "";
const SUPABASE_ANON_KEY = "";
```

The anon key is meant to be public. It cannot read or write any table. Never put your Gemini key in this repository.

### 3. GitHub and Cloudflare
1. Push this repository to GitHub (private).
2. In Cloudflare: **Workers & Pages → Create → Pages → Connect to Git**, pick the repo.
3. Framework preset **None**, build command empty, build output directory **`public`**.
4. Every commit now redeploys the site automatically.

### 4. First run
1. Sign in as `admin` using the starting password from `schema.sql`.
2. **Change the password straight away** (avatar menu → Change password).
3. **Admin → API key and limits:** paste your Gemini key, set the model name, and save.
4. Start a KBC game, then check **Admin → Request log** for a row with HTTP 200.

## Updating a live site

| What changed | What to do |
|---|---|
| `public/index.html` | Commit it. Cloudflare redeploys in about a minute. |
| `supabase/functions/generate/index.ts` | Paste it into the function in the Supabase dashboard and deploy. |
| A file in `patches/` | Run it once in the Supabase SQL Editor, in number order. |
| `schema.sql` | **Don't re-run it on a live project.** It drops and recreates some tables and would delete scores. |

## Admin guide

- **API key and limits:** The master Gemini key is write-only (you see only its last 4 characters). Set the model name here. Google retires models from time to time, so when the request log shows a 404, type the current name. Limits protect your free quota.
- **Read aloud:** Language, voice, speed, pitch, volume, pause between parts, whether to say "Question 3" and "Option A", automatic reading, and the extra seconds on the clock for players who listen. Voices come from each player's device.
- **Request log:** Each Gemini call with status, time, token estimate, and the raw request and response.
- **Users:** See players and delete them.

## When Gemini is overloaded

Each quiz request makes **one attempt on the model chosen in Admin**. If Google answers "overloaded" (503), another server error, or does not answer within 45 seconds, it makes **one attempt on a fallback model** (`gemini-3.1-flash-lite` unless you change it). If both fail, and a saved quiz exists for the same class, topics and difficulty, that saved quiz is played, so the player can still start. If nothing is saved for that choice yet, the player sees a clear "overloaded, try again in a minute" message. A rate-limit reply (429), a rejected key (400/403) or a retired main model (404) stop immediately with their usual messages, because a second model would not fix those.

- To use a different fallback, add a secret named `GEMINI_FALLBACK_MODEL` in Supabase → Edge Functions → Secrets. It is optional.
- If the model in Admin is the same as the fallback, only one attempt is made.
- Both attempts show in Admin → Request log, with the model name on each.

## Older browsers (Pale Moon, MyPal and similar)

The site is written to run on browsers from roughly the Firefox 52 era, and animations use only simple fades and movements, so nothing breaks if a browser can't animate. Things that may not work on very old browsers:
- **Study mode PDF upload:** the PDF reader library needs a newer browser. Plain `.txt` uploads may still work.
- **Read aloud:** classic Pale Moon-based browsers usually have no speech support. The buttons simply don't appear and the game plays as text.
- **Sign-in and quizzes** depend on the Supabase library and `fetch`. If the library can't load, the sign-in screen says so.
Browser-support claims here come from parsing the code, not from running it in those browsers, so report anything odd.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "One step left" screen | The two Supabase values are missing in `public/index.html`, or the site hasn't finished redeploying. |
| "Couldn't reach the quiz writer" | The function isn't named exactly `generate`, isn't deployed, or Verify JWT needs turning off. |
| "The quiz writer isn't set up yet" | No Gemini key saved in Admin. |
| 404 in the request log | The model was retired. Enter the current model name in Admin. |
| "Busy" or limit messages | Gemini free-tier limit. Wait a minute or raise limits in Admin. |
| Old text after an update | Hard refresh (Ctrl+Shift+R) or open a private window. |
| "The quiz writer is overloaded right now…" | Both Gemini models failed and nothing is saved for that exact class, topics and difficulty. Wait a minute, or play a choice that has been played before. |
| Site stops after weeks of no use | Supabase pauses idle free projects. Open the dashboard and click Restore. |
| No sound | Not every browser or device has voices. Try another browser. On phones, tap the Read aloud button once. |

## Known limits

- There is no password recovery, because accounts have no email. An admin tool to reset a password is a good next step.
- Refreshing in the middle of a KBC game ends it at your last safe haven.
- The suspense pause (2 to 5 seconds) is set by `SUSPENSE` in `public/index.html`, not in the admin panel. The sound effects are simple synthesised tones.
- Phones on silent mode, or with the media volume down, will not play the sound effects.
- Read-aloud voices are chosen by each device, so the sound differs between phones and computers.
- Gemini can make factual mistakes, so spot-check questions, especially on smaller models.
- **CBSE tab:** the chapter list is also written by the AI (and saved for 120 days), so it can be wrong or out of date, especially where NCERT has issued new textbooks. Tick what matches your book and add missing chapters by hand. *Admin → Clear quiz cache* also clears saved chapter lists.
- **Current affairs** questions come from the AI's knowledge, so the newest events may be missing.
- Medium and Hard are the AI's interpretation of "harder", so spot-check them. Each difficulty keeps its own saved quizzes, so every class, topic combination and difficulty needs its own fresh Gemini calls before saved sets are reused.
- Every new combination of topics, or of class + subject + chapters, needs up to a few fresh Gemini calls before saved sets are reused. If the free quota is tight, lower "Question sets kept per level" in Admin.
