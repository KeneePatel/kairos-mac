# What Kairos does

Kairos is a macOS app that finds software jobs in Canada and the US (Canada first), says which ones fit and why, and builds a tailored resume and cover letter for the ones worth applying to. Everything runs and stays on your Mac. This document describes the app as it is; [`architecture.md`](architecture.md) says how it's built, and [`decisions/`](decisions/) why.

## The workflow

1. **Find jobs.** Kairos reads companies' public job boards and a few searches, keeps the postings in your countries, at your roles and recent enough, and de-duplicates the same opening across sources.
2. **Screen them.** Free filters run first (your roles and titles, levels, places, work authorization, clearance, French, companies you blocked, staffing agencies, age, jobs you already applied to). An AI reads each remaining posting once, listing its requirements and whether your master resume shows each. Code, not the model, turns that into Yes, Maybe or No.
3. **Decide.** The Inbox lists judged jobs, best first, one key per decision.
4. **Build.** For a job you want, Kairos writes a one-page resume (two if you allow it and the posting needs it) and, if asked, a cover letter, from your master resume only, then makes the PDFs.
5. **Track.** Mark a job applied; move it through screen, interview and offer; set follow-ups; keep notes.

## Sources

| Source | What it gives | Limits |
| --- | --- | --- |
| Company boards: Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR, Teamtailor | Every open job, in full | Read a few at a time per system; unchanged boards answer "not modified" |
| Kairos's catalog | About 800 boards with jobs in Canada, found ahead of time and bundled | Watched when "Watch the catalog" is on; a board with nothing for you rests for 3, then 6, then 7 days |
| Himalayas | Remote jobs, searched by your roles | 30 requests a fetch |
| Google Jobs (SerpApi key) | Postings from across the web, city by city | The free plan's 250 a month, spread at 8 a fetch |
| Adzuna (app ID and key) | **Leads**, never jobs: its 500-character snippets name companies hiring at your roles, and Kairos looks up their own boards | 80 a fetch, 200 a day, 2,400 a month |

A company board behind a search's link, or found for a lead, is added and read in the same fetch. A board you remove is never added back. A board that answers "not found" three times in a row is marked gone until you resume it.

A job stays open while any source lists it. Only a board's complete answer can close a listing, after two misses in a row; search listings close after 30 days unseen once they're 45 days old. Jobs you never acted on are archived 60 days after Kairos first saw them and slimmed (text and analysis dropped) at 120; they stay known, so the same posting isn't new again.

## Screens

| Section | What it shows |
| --- | --- |
| **Inbox** (⌘1) | Jobs to decide, grouped Decide and No from the AI, sorted by your countries, verdict, then rank. The pane: decisions with their keys, the verdict card, must-haves and nice-to-haves with evidence, where it's posted, and the posting. With nothing selected: today's counts, follow-ups due and what's saved. |
| **Saved** (⌘2) | Jobs you saved, until you apply. |
| **Resumes** (⌘3) | Builds grouped Building, Today, Yesterday and Earlier; the PDF, the cover letter, and an inspector with the match, checks, what to be ready to discuss, notes and the model calls. |
| **Applied** (⌘4) | Applications, scoped Waiting, In progress, Closed or All; the pane moves an application along, sets the next step and follow-up, and keeps notes and a timeline. |
| **Interviews** (⌘5) | The board of Screen, Interview and Offer. |
| **Improve** | What keeps your Maybe and No jobs from a Yes, as fixes ranked by the verdicts each could move, with where your resume stands. |
| **Filtered out** | Jobs your filters dropped, by reason, each with Bring back. |
| **Skipped** | Jobs you skipped, and judged jobs no longer posted. |
| **Master resume** | Contact, About you, every kind of entry with its bullets, and skills (Proven or Can discuss); import from a PDF or text, or a project from GitHub; export a PDF; readiness in the inspector. |
| **Sources** | Boards (yours, the catalog, all) with how each last read went, and the searches with their keys. |
| **Settings** | General (where you may work, resume length, Stretch mode, your data), Search (roles, titles, levels, countries, cities, limits, verdict thresholds) and AI (providers and keys, models per task, the daily budget, today's calls). |

The menu bar item shows what's waiting, what's new since you looked and a running build, with Find new jobs and Open Kairos.

### Keys

| Key | Does |
| --- | --- |
| B | Build a tailored resume |
| S | Save, or unsave |
| X | Skip, or bring back |
| O | Open the posting |
| A | Mark applied |
| V | Your verdict: Yes, Maybe, No, then screening's again |
| R | Re-evaluate: screen the job again with a fresh analysis |
| Return / Esc | The job full width, and back |
| ⌘R | Find new jobs (then screen what's new) |
| ⌘. | Stop |
| ⌘Z | Undo the last save or skip |

## Verdicts

- **Yes** when your resume shows at least 75% of the must-haves, **No** below 50%, **Maybe** between (both thresholds are in Settings, Search). A yes is worth 1 and a partial ½.
- Only skills, experience, education and languages count. Soft skills are never judged; location, authorization and availability are taken as met or left to the filters; enrolment is judged against your work profile.
- Before coverage, your profile decides: sponsorship you'd need and the posting won't give, a clearance you don't hold, French you don't speak, a level you turned off, or more years than your limit.
- Your own verdict (V) always wins. Judging everything again (Settings, Search, Re-check jobs) keeps each job's verdict until it gets a new one, reuses stored analyses, and leaves jobs you acted on alone.

## Resumes

- **Strict** (default): every bullet traces to your master resume's bullets, and a verifier rejects anything it can't trace: new numbers, technologies you don't list as Proven, another role's facts, the hiring company's name or products.
- **Lite:** your bullets word for word, in the best order for the job.
- **Stretch** (off until you turn it on): up to two extra bullets per role for Can discuss skills, each listed under "Be ready to discuss".
- Pages are fitted by measuring the real PDF: bullets that waste a line are shortened, and the least valuable lines go until it fits.
- Canadian or US spelling follows the job's country. The Harvard template prints no summary, so none is written.
- A writer that fails falls back to your words; an optional step that fails is skipped. Only stopping or the daily budget ends a build. Each build has a 15-minute deadline.

## AI

Any OpenAI-compatible provider: Google Gemini, Ollama on your Mac, Ollama Cloud, Groq, OpenRouter, OpenAI, or a custom endpoint. Each task has a chain of models; a later one takes over when an earlier one fails. Keys rotate on a rate limit, a key told to wait rests from that model only, and a day's quota refusal is remembered until it resets. Replies are checked against a schema and the task's own rules, with one repair call. Validated replies are cached, and a daily call budget caps spending.

What reaches a model: postings, and your resume with your name, email, phone, links and work status removed. Never your keys, contact details or work authorization.

## Your data

Everything lives in the app's container under Application Support/Kairos: the database (`Library/kairos.sqlite`), each build's PDFs (`Library/Builds/<build>/`), your keys (`api-keys.json`, readable by Kairos only and left out of backups), and backups (`Backups/`, the latest ten). On first launch Kairos imports the first version's data from `local/` read-only, after copying it to `Backups/`.

## Not built (roadmap)

Accounts, sync between Macs, and the phone web app from the first spec ([`archive/SPEC-v1.md`](archive/SPEC-v1.md)) aren't built. ADR-019 explains why they wait.
