# Schema migrations

One file per change, named `NNN_name.sql` (`001_sources_jobs.sql`, `002_master_resume.sql`, …), numbered from 001 with no gaps. `Migrator` applies each new file once, in order, inside a transaction, and records the number in `PRAGMA user_version`.

Migrations are append-only: never edit or delete one that has shipped; add the next number instead (SPEC §12). Synced tables carry `updated_hlc` and `deleted`, and have no `FOREIGN KEY` constraints (SPEC §6.1).
