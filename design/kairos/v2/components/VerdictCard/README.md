The first thing on a job pane after the title: the match score, the verdict pill (large), the deciding reason in `body`, and one `callout` line with when it was decided and Re-evaluate.

- `surface-raised` with a `separator` hairline and `radius-card`; never a filled box without an edge.
- The reason is one sentence, the screener's first reason. Who decided ("your filters", "code from the AI's reading", "you") is in the tooltip of the callout line, not a sentence of its own.
- A snippet-only job adds the snippet callout beneath the card. A job Build can't start on yet adds a `callout` line with a lock glyph and the reason ("Finish your master resume first: add a phone number").
- Provide: verdict, score, reason, decided-by, decided-at. Don't: show the rule name or the prompt version here.
