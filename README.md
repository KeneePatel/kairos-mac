<img src="design/kairos/logo/png/app-icon-default-128.png" width="64" height="64" alt="Kairos app icon">

# Kairos for macOS

Kairos finds software jobs in Canada and the US, Canada first, explains why each one fits or doesn't, and builds a tailored resume and cover letter for the ones worth applying to. It's a native macOS app, with a small phone web app for checking in on the go. A few invited friends can use it, each with their own private account.

**Status:** pre-alpha. The design and plan are approved; the first release (a local MVP) is being built.

## What it does

- **Finds jobs** from company job boards (Greenhouse, Lever, Ashby), the Adzuna API, and optional boards you turn on yourself.
- **Screens them** with free rule-based filters first (title, seniority, location, work authorization, French requirements), then an AI read of each posting. The verdict (Yes, Maybe or No) shows exactly which requirements you cover.
- **Builds a resume** for a job from your master resume, the one complete record of everything you've done. Every line traces back to it, and code checks each claim before the PDF is made.
- **Tracks applications** from applied to offer, with reminders.
- **Syncs** to your private account so you can restore on a new Mac or check in from your phone.

## Built with

- Swift 6 and SwiftUI on macOS 26 or later (Apple silicon), with no third-party Swift packages
- SQLite on the Mac; Supabase for accounts and sync
- Typst for resume PDFs
- Your choice of AI provider: Gemini, Ollama or any OpenAI-compatible service, with your own key

## Documents

| File | What's in it |
| --- | --- |
| [`SPEC.md`](SPEC.md) | What the app does, and why each choice was made |
| [`tasks/plan.md`](tasks/plan.md) | The build plan, in four releases |
| [`CONSTRAINTS.md`](CONSTRAINTS.md) | The quality bar every change must pass |
| [`design/kairos/`](design/kairos/README.md) | Brand guidelines, design tokens and the logo |
| [`AGENTS.md`](AGENTS.md) | Rules for AI coding agents working in this repo |

## Credits

Kairos for macOS is a rebuild of [Kairos](https://github.com/sneh2102/Kairos) by Sneh Patel, released under the MIT License. The rebuild is written from scratch. If any code or prompts from the original are reused, its copyright notice will be kept alongside them.

## License

[MIT](LICENSE)
