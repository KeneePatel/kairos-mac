The one place Kairos says what it's doing: fetching, screening, building, or when it last checked and when it checks next. It sits at the bottom of the sidebar, above a `separator` hairline, in every section.

- Line one: `callout` in `ink` with the count that matters ("212 of 821 boards", "40 of 120 jobs", "2 resumes"); the trailing plain button is Stop while running, Find now or Resume otherwise.
- The meter: 6 px, `accent` on `separator`; `maybe` when a run stopped early. Line two: `caption` in `ink-secondary` with the detail (new so far, the stop reason, the next check).
- Provide: the current run's phase and counts, the last and next check, the stop reason. Nothing else in the app shows a progress bar for these runs.
- Don't: stack two runs (show the one in progress, then the queue count), use `error` for a budget stop (that's `maybe`), or animate beyond the meter.
