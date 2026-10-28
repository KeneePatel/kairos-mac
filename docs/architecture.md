# How Kairos is built

A SwiftUI app over one Swift package, `KairosCore`, with no third-party packages and one bundled binary (`typst`). [`product.md`](product.md) says what it does.

## Modules

```
KairosKit, SQL, Secrets          foundations: HTTP, text, time, ids, concurrency; SQLite; keys
AI                               providers, typed tasks, schema checks, the router
Jobs, Resume                     postings and the master resume
Screening, Tailoring, Render     judging a job, writing for it, printing it
Store                            the only module that knows the schema
Engine                           runs fetches, screening and builds over the store
kairos (KairosCLI)               the command-line tool
App/Kairos                       the SwiftUI screens
```

Each module is its own target, so the compiler enforces the direction: a module only imports those above it. The domain modules (`Jobs`, `Resume`, `Screening`, `Tailoring`, `AI`) hold logic and value types with no SQLite and no UI, so they're tested without a database. `Store` turns rows into those types. `Engine` puts them together.

| Module | Holds |
| --- | --- |
| `KairosKit` | `HTTPClient` (one protocol for job readers and AI, value types, a fake in tests), HTML → Markdown, text folding, UUIDv7 and content ids, the wall clock, `ConcurrencyGate`, `Locked` |
| `SQL` | `Database` (an actor over one connection: WAL, statement cache, transactions with savepoints, read-only opening, `VACUUM INTO` backups), `Migrator` (numbered files, `PRAGMA user_version`) |
| `Secrets` | `SecretStore`: the key file the first Kairos wrote, the keychain, memory, and a caching store |
| `AI` | `AITask` (typed input and output, schema, own checks), the OpenAI-compatible adapter with its structured-output fallbacks (schema, then JSON mode, then prompt only), `AISettings`, and `AIRouter` |
| `Jobs` | readers for nine board systems and three searches, the normalizer (place, Markdown, canonical URL, dedup key), roles, geography, the board catalog, discovery (ATS detection, board probing) |
| `Resume` | the master resume model, validation, contact redaction, resume and GitHub import tasks |
| `Screening` | preferences and work profile, the prefilter, the analysis task, the verdict engine, ranking |
| `Tailoring` | selection, the writers, the verifier, polish and spelling, shortening, gap bullets, the cover letter, page fitting, the match score and report |
| `Render` | the Typst runner (sandbox-safe, timed), the Harvard and letter templates, layout measurement |
| `Store` | the schema, the repositories, the listing ledger, retention, and the importer for the first Kairos |
| `Engine` | `Fetcher`, `Screener`, `BuildQueue`, `JobLists`, `ImproveReport`, `Workspace` |

## Data

One SQLite file, STRICT tables, foreign keys with cascades, times in milliseconds, JSON checked with `json_valid` (`Packages/KairosCore/Sources/Store/Schema/001_schema.sql`).

| Table | Rows |
| --- | --- |
| `source` | a company board (kind, slug) or a search; origin, status, ETag, streaks, rest |
| `job`, `listing`, `job_event` | an opening; each source's copy of it; what happened to it |
| `analysis`, `screening` | what the AI found; where screening left the job (filtered, waiting, judged) |
| `resume_header`, `resume_entry`, `resume_bullet`, `resume_skill`, `resume_snapshot` | the master resume, versioned, with snapshots before a replace |
| `build`, `build_file` | a tailored resume (and letter) and its PDFs, paths relative to the data folder |
| `application`, `application_event` | applications and their timelines |
| `ai_call`, `ai_cache` | every provider call (codes and counts, never text or keys); validated replies |
| `run`, `fetch_log`, `lead`, `company_lookup`, `search_turn`, `setting` | runs, reads, Adzuna's leads, board lookups, Google Jobs turns, JSON settings |

Ids: a job and a listing are the first 16 bytes of SHA-256 of the posting's canonical URL, so the same posting is the same row however it arrives. Everything else is a UUIDv7.

## A fetch

`Fetcher.run` reads every watched, non-resting source, boards before searches, through a `ConcurrencyGate` of four per board system and sixteen in all. Each answer goes to `ListingLedger.record` in one transaction:

- a listing seen before is seen again; an edit updates it, and the job takes the text when it's the primary listing and is screened again (unless you acted on it);
- another source's copy (same company, titles at least 0.9 alike, same city) is attached, and a company's board becomes primary over a search's copy;
- anything else is a new job, unless it's older than your limit or not at your roles;
- only a complete answer closes a listing, after two misses; HTTP 304 repeats the last answer.

When what a fetch keeps changes (roles, titles, age limit, countries), every ETag is forgotten once. Searches spend what their plan allows (counted from the fetch log); Google Jobs searches the least recently searched role-and-city pairs. Afterwards: leads are looked up (catalog first, then probing the name's slugs), boards found are read, stale search listings close, retention runs and the logs are trimmed.

## Screening

`Screener.run` takes jobs without a verdict (`.new`) or every job you haven't acted on (`.everything`). The prefilter runs on each (unless you brought it back); a job that passes is judged from its stored analysis if the prompt version matches, or waits for the AI, which runs two at a time. `VerdictEngine.decide` makes the verdict. A missing key, a spent budget, a used-up quota or a stop ends analysis; the rest wait for the next run.

## A build

`BuildQueue` keeps its queue in the database (queued, running, done, failed, stopped) with two workers. A build reads the job, its analysis (making one if screening hadn't), your master resume (it must be ready), Stretch and page settings, then runs `Tailor`: select, write sections in parallel, add gap bullets in Stretch, shorten, fit pages by measuring the real PDF, write the letter. The PDFs land in `Library/Builds/<build id>/` under your name. A build that outlives its 15-minute deadline is stopped even if a step ignores cancellation.

## The AI router

Every reliability rule lives in `AIRouter`, each from a real failure: keys rotate on a 429 and rest per model; a quota of 0 skips the key for that model; network errors and 5xx retry with backoff, but a slow model isn't waited out when another is in the chain; a model that just failed is skipped for two minutes; a reply that fails its checks gets one repair; a model that refuses a structured-output mode is remembered at the next; a daily budget, a cache, and a call log.

## The app

`AppModel` holds the open `Workspace`, the lists (job summaries, builds, applications, sources, settings), the run in progress and builds in flight. Screens keep their own state and write through the store, then reload. Each section is a feature folder under `App/Kairos/`; shared components and the generated tokens are in `Design/`. Colours come only from the asset catalog, generated from `design/kairos/tokens.json` by `scripts/gen-tokens.swift`.

## Testing

- Every module has a test target; tests never touch the network (`FakeHTTP` refuses unscripted requests, `ScriptedChat` answers AI tasks).
- Readers are tested against answers recorded from live boards; screening against analyses recorded from real models; the evals replay 30 labelled postings' recorded replies.
- The store's importer is tested against a database built from the first Kairos's own migration files.
- Builds are tested end to end through the real Typst binary.
- Live checks are opt-in: `scripts/live-llm.sh` (Gemini and Ollama), `kairos fetch` against real boards, and the app's `--import-check`.
