# Kairos for macOS: rules for agents

Every agent working in this repository (Claude Code, Codex or any other) follows these rules. `CLAUDE.md` imports this file.

## 1. Check skills before every request

Before acting on any prompt, including follow-ups and small fixes:

1. Look at the installed skills (`~/.agents/skills/*/SKILL.md`, plus any `.agents/skills/` or `.claude/skills/` in this repo) and read their descriptions. When unsure which apply, start from `using-agent-skills`.
2. Pick every skill that fits the request and say so in one line before starting, for example: `Skills: spec-driven-development, security-and-hardening`. If none fit, say `Skills: none apply`.
3. Follow the chosen skills' workflows, including their gates and verification steps.

## 2. Commit authorship

- Every commit is authored **and** committed as `Kenee Patel <patelkenee2804@gmail.com>`.
- Right after `git init` or cloning, set it for the repository:
  ```bash
  git config user.name "Kenee Patel"
  git config user.email "patelkenee2804@gmail.com"
  ```
- Don't add `Co-Authored-By` lines, "Generated with" lines or any other AI attribution to commit messages or pull request descriptions.
- Before pushing, check that only that identity appears and no trailers were added:
  ```bash
  git log --format='%an <%ae> | %cn <%ce> | %(trailers:only,unfold)' origin/main..HEAD
  ```
  `scripts/check-commits.sh` automates this once it exists.
- Commit or push only when asked.

## 3. Before writing code

- Read the parts of `SPEC.md` that apply to the task, and `CONSTRAINTS.md` once it exists.
- Follow the boundaries in `SPEC.md` §12: Always, Ask first, Never.
- Never weaken `CONSTRAINTS.md`, skip tests, or add suppressions to make a change pass.

## 4. Everyday commands

```bash
swift test   --package-path Packages/KairosCore
swift format lint --strict --recursive Packages App
xcodebuild -project App/Kairos.xcodeproj -scheme Kairos -destination 'platform=macOS,arch=arm64' build
scripts/check-deps.sh
```

The full list is in `SPEC.md` §8.
