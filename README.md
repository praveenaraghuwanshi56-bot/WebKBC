# WebKbc

A KBC-style (Kaun Banega Crorepati) quiz game with a Study Mode that turns your notes into quizzes. Questions are written by Google Gemini, accounts and scores live in Supabase, and the site is a single HTML file hosted free on Cloudflare Pages.

> **Keep this repository private.** `schema.sql` creates the first admin account with a starting password. Anyone who can read the repo can read that password until you change it.

## What it does

- **KBC quiz:** 15 levels of Indian GK from ₹1,000 to ₹1 crore, with safe havens at Level 5 and Level 10, a countdown per question, and three lifelines (50:50, Audience poll, Phone a friend). Classes 5th to 12th, plus General GK.
- **Study mode:** Upload a PDF or `.txt` file and get 10 multiple-choice questions with explanations.
- **Read aloud:** Questions and options are read in order (question, then Option A and its text, Option B, and so on) using the browser's built-in voices. The admin controls language, voice, speed, pitch, volume, pauses and more.
- **Accounts:** Username and password sign-up and sign-in, one active device per account, lockout after 5 wrong passwords, and a profile menu (icon, colour, username, password, delete account).
- **Leaderboard:** Best KBC score per player, per class. Scores are calculated and saved by the server, so they can't be faked from the browser.
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
patches/                                 Small updates for an EXISTING database, run in number order.
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

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "One step left" screen | The two Supabase values are missing in `public/index.html`, or the site hasn't finished redeploying. |
| "Couldn't reach the quiz writer" | The function isn't named exactly `generate`, isn't deployed, or Verify JWT needs turning off. |
| "The quiz writer isn't set up yet" | No Gemini key saved in Admin. |
| 404 in the request log | The model was retired. Enter the current model name in Admin. |
| "Busy" or limit messages | Gemini free-tier limit. Wait a minute or raise limits in Admin. |
| Old text after an update | Hard refresh (Ctrl+Shift+R) or open a private window. |
| Site stops after weeks of no use | Supabase pauses idle free projects. Open the dashboard and click Restore. |
| No sound | Not every browser or device has voices. Try another browser. On phones, tap the Read aloud button once. |

## Known limits

- There is no password recovery, because accounts have no email. An admin tool to reset a password is a good next step.
- Refreshing in the middle of a KBC game ends it at your last safe haven.
- Read-aloud voices are chosen by each device, so the sound differs between phones and computers.
- Gemini can make factual mistakes, so spot-check questions, especially on smaller models.
