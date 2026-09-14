# Refactor: Swedish identifiers to English

Everything in code and documentation is English from 2026-09-11. The `plattform`
schema and several `public` tables predate that decision. This is the plan, written
before touching anything, because a rename pass has one failure mode that is worse
than the work itself.

## The strategy changed, and the risk went with it

The first version of this plan was a migration: rename in place, recreate every
function, re-point every trigger, republish seven skills. It described a real trap --
`ALTER TABLE ... RENAME` does not rewrite function bodies, so renaming
`plattform.handelser` leaves the logging trigger inserting into a table that no longer
exists, silently, until the next write.

That whole class of risk is gone. **The content is disposable** -- every row is test
data, and an agent can load the real thing again from the USB stick. So this is a
re-seed with English names from the start, not a migration:

1. drop the `plattform` schema and the seeded `public` tables
2. run the rewritten files
3. let an agent fill the store again

No ordering constraints, no stale bodies, no triggers to re-point, and no published
skill left describing names that no longer exist.

A dump is taken first anyway (`/root/backup/preflight-*.sql.gz`, 12 MB) because it
costs nothing and "disposable" is easier to say before than after.

## What has to be rewritten

1909 lines across eleven files. The identifiers are mechanical; the prose is not, and
the prose is the larger half -- comments, table and column descriptions, the rows in
the entry-point table, the text `overview()` and `daily_report()` return, and two
seeded skills. All of it is read by agents, so all of it is English now.

| File | Lines | What it carries |
|---|---|---|
| `konventioner.sql` | 150 | the conventions skill and the shared-table template |
| `plattform.sql` | 544 | the overview schema: event log, catalog, search, placement rule, DDL guard |
| `plattform_livscykel.sql` | 256 | skill lifecycle, document catalogue, rot list, daily report |
| `plattform_tools_en.sql` | 218 | the eleven house RPCs (names already English) |
| `plattform_skillhub.sql` | 168 | the skillhub wrappers |
| `plattform_inlasning.sql` | 195 | loading from a source system |
| `plattform_embed.sql` | 134 | embedding queue and the cron job |
| `plattform_ingang.sql` | 72 | the rows in the entry-point table an agent sees first |
| `plattform_vektor.sql` | 61 | the vector column and dimension switch |
| `bokhandel.sql` | 99 | demo data, the least important file here |
| `skill_library.sql` | 12 | the skill table |

## Name map

Functions: `sok`→`search`, `oversikt`→`overview`, `liknande`→`similar`,
`radantal`→`row_estimate`, `placeringsregel`→`placement_rule`,
`dagsrapport`→`daily_report`, `logga`→`log_change`,
`spara_historik`→`attach_change_log` (**the current name lies** -- it attaches the
logging trigger and saves no history), `registrera_leverans`→`register_delivery`,
`ddl_bevakning`→`ddl_guard`, `bekrafta_skill`→`confirm_skill`,
`pensionera_skill`→`retire_skill`, `skapa_delad_tabell`→`create_shared_table`,
`embed_kandidater`→`embed_candidates`, `embed_spara`→`embed_save`.

Tables: `handelser`→`events`, `ddl_logg`→`ddl_log`, `inbaddningar`→`embeddings`,
`leveranser`→`deliveries`, `anteckningar`→`notes`, `dokument`→`documents`,
`bocker`→`books`, `kunder`→`customers`, `ordrar`→`orders`,
`orderrader`→`order_lines`, `borja_har`→`start_here`, `agenter`→`agents`.

Views: `v_katalog`→`v_catalog`, `v_flode`→`v_flow`, `v_atgardas`→`v_action_items`,
`v_ruttnar`→`v_going_stale`, `v_vektorlage`→`v_index_status`, `v_dygn`→`v_last_24h`,
`v_utan_vektor`→`v_not_indexed`, `v_embed_jobb`→`v_embed_queue`,
`v_kallor`→`v_sources`, `v_dubbletter`→`v_duplicates`, `v_forbehall`→`v_caveats`,
`v_nya_tabeller`→`v_new_tables`, `v_oregistrerad_data`→`v_unregistered_data`,
`v_aktivitet`→`v_activity`, `v_dokument`→`v_documents`.

Columns: `titel`→`title`, `innehall`→`content`, `taggar`→`tags`,
`filnamn`→`filename`, `beskrivning`→`description`, `sokvag`→`path`,
`kalla`→`source`, `storlek`→`bytes`, `mimetyp`→`mime_type`, `roll`→`role`,
`kommando`→`command`, `objekt`→`object`, `tidpunkt`→`at`, `rad_id`→`row_id`,
`synlighet`→`visibility`, `sammanfattning`→`summary`, `modell`→`model`,
`vektor`→`vector`, `skapad`→`created_at`.

Dropped rather than renamed: `skillhub_liknande`, a dead Swedish duplicate of
`skillhub_similar` that the edge function never calls.

One substring trap: `sok` is inside `sokvag`. Word-bounded matching separates them
(25 occurrences against 12), so the replacement must be anchored, not naive.

## Two skills to write in English

The store should ship knowing how it is meant to be used, rather than waiting for
someone to write that down. Two are enough:

- **how an agent works against the store** -- orient, search before answering, read
  whole objects, where a new thing belongs, and how ownership works
- **how to load a source system** -- an export arrives as xlsx or csv; what becomes a
  table, what becomes a document record, what the source hash is for

The first one is the important one. Today's measurements showed an agent answering a
quality question thirty-eight times too high because it never read what a colleague
had already written down, and answering it correctly the moment it did.

## Verification: re-seed, then exercise every path

- a write through a house tool lands with the right owner and appears in the flow view
- keyword search returns a private row to its owner and to nobody else
- the DDL guard refuses a non-conforming table and says what to do instead
- the embed job finds new rows and the vector count goes up
- `overview` and `daily_report` return something a human can read
- an agent asked the defect question answers 28,638, not 1,091,957
