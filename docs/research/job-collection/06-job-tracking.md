# Tracking jobs over time (research, 2026-10-23)

How a job should be identified, merged across sources, kept current, closed and referred
back to. Today Kairos stores a job once, from its first source, and never looks at it again
(00-current-system.md).

## What postings say about themselves

Google's JobPosting structured data (developers.google.com/search/docs/appearance/
structured-data/job-posting) is what employers publish for Google for Jobs. It is the
vocabulary the ATS feeds approximate:

- Required: `datePosted` ("the original date that employer posted the job"), `description`
  (full HTML), `hiringOrganization`, `jobLocation`, `title`.
- `validThrough` for jobs with an end date; `jobLocationType: TELECOMMUTE` plus
  `applicantLocationRequirements` for remote jobs; `baseSalary`; `directApply`;
  `employmentType`; `identifier` ("the hiring organization's unique identifier for the job").
- A filled or expired job is **removed** (404/410), or its `validThrough` is set to the past.
  There is no "filled" flag: **disappearing is the signal.**

ATS feeds follow the same rule: a closed job simply stops appearing in the board's list.

## Identity

| Level | Key | Why |
|---|---|---|
| Listing (one source's copy) | the source's own id (Greenhouse job id, Lever posting id, Adzuna `id`), else the canonical URL | stable while the posting lives; URLs change with tracking parameters |
| Job (the real opening) | first listing's canonical-URL hash, kept forever (today's `job.id`) | ids must stay stable across devices for sync (SPEC §6.1) |

A job can have several listings: the company's board, Adzuna, Himalayas. Today the second
copy is thrown away as a duplicate; it should be attached instead, so the best description
and the company's own apply link win, and every place the job appears is known.

## Matching copies (near-duplicates)

- Field gates first: same company (normalized: suffixes, punctuation, known aliases), a
  compatible place (same city or region, or remote in the same country), title similar after
  normalizing (abbreviations such as Sr, SDE; bracketed notes such as "(US + Calgary)").
- Then text: for two full descriptions, word-shingle Jaccard (MinHash at scale)
  (skeptric.com/minhash-lsh). For an Adzuna snippet against a full posting, **containment**:
  Adzuna's 500 characters come from the posting's text, so most of the snippet's shingles
  should appear in the full text. Kairos has a few hundred jobs, so exact comparison is fine;
  no index needed.
- Pitfalls: companies reuse boilerplate ("About us") across jobs, so a high text score with a
  different title or city isn't a match (skeptric.com/near-duplicate-review); true duplicates
  can score as low as 0.37 when rewritten (Textkernel), so text alone isn't enough either.
  The gates do the work; text confirms.
- Evidence (2026-10-23): Adzuna's "Software Engineer, Integrations (US Calgary) · Syndio" is
  Greenhouse `syndio` "Software Engineer, Integrations (US + Calgary)"; Adzuna's "Software
  Engineer (Full stack) · Revic" is Ashby `revic` "Software Engineer (Full stack)".

## Lifecycle

| State | How Kairos knows |
|---|---|
| open | the listing was in its source's latest complete answer |
| seen again | same, on a later run: `last_seen_at` moves |
| changed | the listing's text hash differs from the stored one: store the new text, note it, re-screen |
| closed | a **complete** board answer no longer lists it, twice in a row (one miss can be a glitch); or the posting URL answers 404/410; or `validThrough` passed |
| probably closed | search-only listings (Adzuna) can't prove absence; not seen for 30 days and posted over 45 days ago |
| reopened | a closed listing appears again |

Rules that keep this safe:
- Only a **successful, complete** fetch can close anything. A failed, partial, rate-limited
  or 304 answer closes nothing (304 means "unchanged": everything stays open and seen).
- Closing never deletes. A closed job you saved, built or applied to stays, marked closed.
- A job is closed when all its listings are.

## Keeping a record

- `first_seen_at`, `last_seen_at`, `closed_at` on each listing and job.
- A short event history per job: found, seen on another source, text changed, closed,
  reopened, upgraded from snippet. This answers "where did this come from, and is it still
  up?" months later, next to the build and the application.
- A fetch log per source and request: when, what was asked (board, or query and page), status,
  bytes, items, new, changed, closed, and whether it was a 304. It is how coverage is
  measured, budgets kept (Adzuna's 2,500 a month), and failures explained.
- Retention (T46) keeps its 60/120-day rules for untouched jobs; closed untouched jobs can go
  sooner.
