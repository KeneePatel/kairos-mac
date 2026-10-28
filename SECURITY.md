# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately through GitHub instead: open the repository's **Security** tab and choose **Report a vulnerability**.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply within a week.

## What's in scope

- The macOS app and its handling of API keys and the local database
- What the app sends to job boards and AI providers

## How Kairos handles secrets and data

- API keys live in `api-keys.json` in the app's container, readable only by your user (mode 600) and left out of backups, or in the macOS Keychain. Never in the database, logs or test output.
- Everything else stays on the Mac: there are no accounts and no server.
- What reaches an AI provider: job postings, and your resume with your name, email, phone, links and work status removed. Never your keys, contact details or work authorization.
- The AI call log keeps codes and counts, never prompt or reply text. Logs carry ids and counts only.
- Typst, the one bundled binary, runs inside the app's sandbox with a timeout.
