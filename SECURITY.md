# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately through GitHub instead: open the repository's **Security** tab and choose **Report a vulnerability**.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply within a week.

## What's in scope

- The macOS app and its handling of API keys, session tokens and the local database
- The Supabase backend: database policies, functions and storage rules in `Backend/`
- The phone web app in `Web/`

## How Kairos handles secrets

- API keys and sign-in sessions live only in the macOS Keychain, never in files, the database or logs.
- The app ships only Supabase's publishable key, which is safe to expose. Every user's data is protected by row-level security on the server.
- Work-authorization details never leave the Mac.
