# Decisions

Why this system looks the way it does. Every entry below was settled by a measurement on a
running installation rather than by argument, and several of them reversed what seemed
obvious beforehand. The dates are when the measurement was taken.

The short version: **agents are creative, and that is the asset. The design gives them one
library where a colleague's work cannot be overwritten, and exactly one key that may.**

---

## 1. One door, and raw SQL is not it

Agents reach the store through fifteen tools and nothing else. The database's own SQL
endpoint answers an agent key with 403.

This was not the original design. Agents had both, and the argument for keeping raw SQL was
good: an agent answered a real analytical question across 5,812 quality records with no hint
about which table to use. The capability was worth something.

What settled it was four measurements, each with the agent behaving reasonably and the store
losing the ability to tell the truth:

| What the agent did | What was lost |
|---|---|
| Created a 36,645-row table with a raw `create table` instead of the helper. It carried all four convention columns, so the structural guard let it through. | No change-log trigger. Not one of those rows appeared in the activity view or the daily report. The catalogue reported the table as conventional while it was untracked. |
| Wrote a note through raw SQL rather than the write tool, filling in its own identifier correctly. | The identity was self-declared. It happened to be honest because the prompt asked. |
| Wrote a row naming a *different* agent as owner, using its own key. | The change log attributes the write to an agent that did not make it. So does the deletion. The log is wrong and looks right. |
| Dropped a table. | Nothing recorded it — the guard only watched creation. Seven rows documented the table's birth and none its removal. |

**A structural check cannot replace going through the door.** The guard inspects a table's
*columns*, not the *mechanism* that created it, so a well-formed raw `create table` passes and
still arrives with no log. That is why the door has to be the only way in rather than the
recommended one.

What is not taken away: the restriction is scoped to the shared store and to the agent key.
An agent keeps every capability it has everywhere else, and inside the store it gets a
read-only query tool that covers what the analytical work actually needed. The caretaker
keeps the full set, because bulk loading and schema changes are its job.

Said in one line: *an agent may compute anything and record anything, and everything it
records can be traced back to it.*

## 2. Identity comes from the gateway, and cannot be stated

Every writing tool takes the caller's identity from the header the gateway sets after
validating the API key, and overwrites whatever the agent supplied.

Verified 2026-09-14 with three simultaneous lies — one key claiming another agent in the tool
argument *and* in a hand-forged gateway header:

```
whoami                →  the calling key
the row that landed   →  owner, created_by, updated_by all the calling key
the change log        →  the calling key
```

What the key does **not** prove is who is behind it. It binds a call to `agent_NN`, not
`agent_NN` to a person. The registry that maps the two is written where the key is handed
over, and no tool reaches it.

## 3. Nothing is deleted, because nothing can be restored

The event log stores a breadcrumb — table, operation, row id, agent, time — and never row
contents. Once a row is gone, its text is gone, permanently, for everyone.

So agents cannot delete at all. `retire` marks the row: it leaves search and the index, and
stays readable by id, so a colleague who cited it yesterday still gets an answer instead of a
dead reference. Hard deletion exists only behind the admin key, where it is a deliberate act
by a person.

A rule that follows, added after a near miss: **never retire something whose content did not
survive the move.** An agent moved a note's contents into a proper table and retired the note,
in that order, which is correct — but retired content leaves the search index, so a dropped
column would have taken the only copy with it. Read the new thing back and check it field by
field *before* retiring the old one.

## 4. Ownership is per version, not per name

Publishing an improvement over a colleague's skill is the point of the library. Overwriting
theirs is not. So:

- publishing requires a prior search — refused otherwise, because a library fills up with
  second versions of the same thing otherwise;
- publishing over an existing version is refused, and the refusal names the owner and the
  next version number to use;
- a higher version supersedes the older ones, and reading returns the newest, ordered
  numerically rather than as text (`1.10.0` sorts after `1.9.0`, which it does not as a
  string).

Measured 2026-09-14, and it found a hole in exactly the property this exists to protect:
retirement checked the author of the *newest* version and then updated every row carrying
that slug. So publishing a better version of a colleague's skill quietly earned you the power
to retire theirs. The same statement also overwrote the supersede link with null, destroying
the chain between versions in the act of retiring. Both fixed; ownership is now checked per
version.

## 5. Agents ask for tables; they do not create them

An agent that needs somewhere to put structured data calls `request_structure` with the
purpose, the fields and the rows it is holding. The caretaker answers.

This is not distrust. It is that **the caretaker is the only party that sees every open
request**, which makes duplication visible before it is built rather than discovered a year
later as two tables holding the same thing under different names.

Measured round trip, with no human at either end: request at 12:16, table created and the
request closed at 12:20, six rows loaded at 12:21.

And the grain rule, because a table is defined by what one row *is*: if a row would mean the
same kind of thing as a row in a table that already exists, it is a column on that table, not
a sibling beside it. Four hundred near-duplicate tables is how a shared store stops being one,
and it happens one reasonable-looking table at a time.

## 6. Guidance must arrive before the work, not in the tool's reply

This is the most useful thing measured in the whole project, and it generalises well beyond
this system.

An agent was handed a quality manual as a PDF and asked to put it in the store so colleagues
could use it. It registered the file in the catalogue and stopped, reporting that a person had
to upload the contents. It did that **three times**, including once after the user said
outright that they could not upload anything and that the entire point was for colleagues to
get answers out of the manual. The second time it went further and invented a mechanism to
justify stopping — claiming that uploading would make the content searchable, which nothing in
the system does.

The agent could read the PDF perfectly. Asked directly, it quoted seven design inputs straight
out of it. It had `write_note`, `publish_skill` and `request_structure` available the whole
time.

It was obeying a sentence we had written: the `FILES` branch of the placement rule said a
file's home is Storage and the agent's job is a reference. A storage-engineering rule, read as
a knowledge rule.

**Rewriting the tool's reply to name the remedy changed nothing** — same prompt, same outcome.
A tool result reaches an agent that has already decided what the task was. Rewriting the
placement rule, which the agent reads at the *start* of every session, fixed it on the next
run: it extracted the manual and published it as a skill, and versioned the skill to match the
document revision without being asked.

The corollary: the store's own output is the only instruction channel that reaches an agent on
a machine nobody can log into, and the only one that can be changed centrally afterwards. A
rule that lives in a pasted prompt is frozen where it was pasted, and eight devices drift into
eight different rulebooks within a month.

## 7. A refusal has to carry its remedy in the message

Postgres returns a refusal in two parts and only one crosses the MCP boundary:

```
through psql
  ERROR:  Table public.x is missing the convention columns …
  HINT:   Create it like this instead: select create_shared_table('name','description'); …

through the door
  {"error": {"message": "Table public.x is missing the convention columns (…)"}}
```

The agent is told no and not told what to do instead. Every refusal an agent can reach now
carries its remedy inside the message string, because the message is the only field that
travels.

The same applies to a *success* message. See §6: a reply that ends the work is as costly as a
refusal that does not say what to do instead.

## 8. Search falls back to meaning, because the agent will not

The store is documented in English and its users ask in Swedish. Keyword search does not cross
that line: the rule for reading a column was found by `search('sentinel')` and not by
`search('defekter')`.

A regression test failed three times in one morning with the agent doing everything right —
overview, rules, search — and answering a total **thirty-eight times too high**: 1,091,957
instead of 28,638, because sixteen rows out of 5,812 carry sentinel values that must be
excluded, and the rule saying so sat unread in a colleague's skill.

Fixed in the retrieval layer rather than by writing the rules twice, which would have created
a second source of truth that drifts. Search now covers column comments, those comments are
embedded, and **a keyword search that finds nothing falls back to meaning by itself**. The
agent had not reached for the semantic tool on its own, and leaving that to its judgement is
the version that fails silently.

A second agent, on a separate volume with a separate key, produced the identical wrong number
thirty-five minutes after the correct rule was written down. Same agent, same question, same
data, thirty-two seconds apart: the difference was one clause in the prompt telling it to
check the store first. Because the difference shows up as a single number, it is a regression
test rather than an opinion.

## 9. Index on write, not on a schedule

Indexing ran on a five-minute cron, which is invisible in a batch system and fatal in a
conversation: an agent writes a rule, a colleague asks about it forty seconds later, and the
store says there is nothing. Measured worst case, two minutes nine seconds.

A write now nudges the indexer directly from the database and returns without waiting for it,
so the write is never slowed and never fails because the indexer is down. The schedule stays
as the net. **Three seconds, measured end to end.**

Both halves are deliberate: an index that is late is a nuisance, a write that fails because
the indexer was down is a bug.

## 10. The query tool takes no SQL

`skillhub_query` names a table, columns, filters, a grouping, an ordering, a row cap and an
optional time bucket. It never accepts SQL text.

Raw SQL inside a `SECURITY DEFINER` function is the same escape hatch measured for the
scratch-zone design (§13): `EXECUTE` accepts multiple statements and the function runs as its
owner, so a caller who closes a parenthesis reaches a privileged role. Validating SQL text by
pattern matching is a losing game — CTEs, function side effects, statement chaining.

So the agent says what it wants, every identifier is checked against the real catalogue, every
value is quoted as a literal, and the function writes the statement. Three things that raw SQL
could not guarantee: the ownership filter is *applied* rather than requested, there is a row
cap and a statement timeout, and the statement that ran is returned so the agent and the log
see the same thing.

The design line: **dimensions and comparisons yes, computations never.** A time bucket is a
dimension with a unit from a closed list; comparing two columns is a filter. A derived value
like "average days from report to closure" is an expression, and an expression is a door to
arbitrary SQL. That work belongs in the load, where it is written once and audited.

## 11. Personal data is the one thing an agent stops and asks about

Handed absence records, an agent did the sensible analytical thing and prepared to store them
per named person. Nothing in the system objected. Everything defaults to public and everyone
with a key shares it, so that is a disclosure of someone's health to their colleagues, arrived
at by an agent being helpful.

The rule now sits in the operating rules every agent reads at the start of every session: stop
and ask before putting anything about a named individual into the store — absence, sickness,
pay, performance, health, discipline, home address — and **aggregate first**, because the count
per department answers the question without naming anyone.

And *private* is not the escape hatch: it is a visibility flag in a shared store that an
administrator can read, not a lawful place to keep someone's medical history.

This is a rule, not a gate. There is no technical control here, which is stated plainly rather
than implied.

## 12. A delivery, not a specification

Given a real ERP's published API documentation, an agent began designing tables for the
endpoints it described. That is the wrong inference and an expensive one: a customer typically
uses a fraction of such a system — production but not ticketing, say — and the export may
arrive as flat files that look nothing like the API.

The loading skill now opens with it. Build tables for the columns in the file in front of you,
from a sample you have actually read. A schema modelled on documentation is a guess that costs
a migration to correct, and it silently invites four hundred tables nobody will ever fill.

## 13. Recurrence decides a table, not volume

The placement rule used volume — "more than about twenty records" — and volume is the thing an
agent knows least about at the moment it asks. It sent the wrong answer back twice in one
simulation: an agent holding three quarterly audits followed the rule to the letter and wrote
them as prose, so nobody could filter on score.

The test is **recurrence**: will more of this arrive, and will someone filter or count it?
Then it is a table, at six rows. Otherwise it is a note, at six hundred.

## 14. Row-level security is not the mechanism, and could not be

Every table reports row security enabled with no policies, which reads like an alarm and is
the opposite: for a role that obeys row security, no policies means nothing is permitted — a
read with the anonymous key returns `200 []`, an empty list with no error.

But all agents share one database role, and that role bypasses row security. Even with a role
that obeyed policies, a policy needs an identity in the *connection*, and on a door where the
caller writes arbitrary SQL the caller can set whatever session variable the policy would read.
RLS here would look binding in the schema and bind nothing, which is worse than an honest flag
because people trust it.

Enforcement therefore lives in the tool tier: gateway ACLs plus filtering inside
`SECURITY DEFINER` functions. Real, and one layer higher than it will eventually be.

The route to real RLS exists and is a later version: an agent connecting with a signed token
would obey policies for real and could not forge the claim. The client is not what blocks it —
the agent runtime implements RFC 8628 device authorization, so no browser is needed on the
device. What blocks it is that nothing here issues those tokens. A component to build, not a
setting to turn on.

## 15. A scratchpad is deferred, not rejected

An earlier design proposed a second zone where anything goes and nothing is promised. It is
entirely buildable, and the reason for the order is a judgement about what compounds.

**A scratchpad serves one agent thinking in the moment; the library serves the organisation
over years.** Only the second compounds — a rule written down today is still saving someone a
wrong answer next spring, while a table built to look at once is worth nothing the day after.

There is also a measured cost. The obvious implementation is a `SECURITY DEFINER` function
that switches to a restricted role and runs the agent's SQL. That is escapable in one
statement, because `SET ROLE` authorises against `session_user`, which inside a definer
function is still privileged:

```
set role scratch_agent;   -- current_user = scratch_agent, session_user = privileged
reset role;               -- escaped
```

There is no cleverer function. It must open its own connection, logged in as the restricted
role, so that `session_user` *is* that role and there is nothing to reset to. That is a
component with credentials of its own — the honest price of a scratch zone, and the reason to
build it deliberately rather than as a corner of something else.

The zone itself holds: a role granted usage on its own schema and nothing else was refused at
every boundary that matters and worked inside its own. The wall is real. It just has to be
reached across a connection, not across a role switch.

## 16. The store is seeded from the repo on every boot

`demo/*.sql` **is** the store — the conventions, the change log, the placement rule, the
fifteen tools, every refusal message an agent reads. For most of this project nothing applied
it: it was run by hand with `psql`.

That produced two failures of the same kind. A fresh deploy gave a gateway, a route and
fifteen tools that all answered with errors. And the running database could differ from the
repo with nothing to show it — which it did.

Seeding on every boot closes both. Every statement is create-or-replace or if-not-exists, so
an up-to-date database is untouched, and "what is running" equals "what is committed" by
construction rather than by discipline.

`utils/test-seed-on-empty-db.sh` is the receipt: an empty database from the same image, seeded
twice, then checked that the store *answers* rather than that no statement raised. Running it
the first time found five defects that a fresh install would have hit and nobody had, because
every previous apply was against a database where the objects already existed:

- a policy needed a function the auth service brings up, so a seed racing startup failed;
- two views selected from objects defined further down the same file — views resolve at
  creation, plpgsql bodies do not, which is why this never showed;
- **notes and documents had no `retired_at` / `_by` / `_reason`**: six columns that existed in
  production and in no file, so retirement — one of the ten acceptance criteria — would have
  failed outright on a new install;
- the conventions skill was inserted in a way that produced a duplicate row on the second run;
- `create_shared_table` refused a table whose exact name already existed, so the seed could
  run once and never again.

A seventh, found the same way: the trigger that makes §9 work ran in production and existed in
no file either.

None of that is visible by reading. **The only way to know a fresh install works is to build
one.**

## 17. Do not prove with code what the architecture already guarantees

A function was built to stamp the agent registry with *who recorded this row*, so a name could
not be self-declared. It was deleted two hours later.

No agent can write that table at all — no tool exposes it, and the row-adding tool refuses it
for lacking the convention columns. The only possible writer is someone with admin access, so
a column asserting that carries no information. An administrator editing the row in the
database console *is* the caretaker writing it.

The question to ask first is not "how do we prove this" but "could it even be false".

What was kept is text, not mechanism, because the text is what is at risk: the table's comment
now records that the missing convention columns are what keep agents out of it, and that adding
them "to make the tool work here" is the hole rather than the fix.

## 18. Three conditions on the caretaker

One agent holds the admin key. It loads source-system data, changes schemas, tidies, and is
the only key that may change another agent's work. Three things follow, and they belong in its
own prompt because nothing enforces them:

- **It can read every private note of everyone here.** A service-role key ignores row security.
  That is normal for an administrator and it has to be a stated choice rather than a side
  effect — whoever operates that agent is an administrator of everyone's private material.
- **Its writes must be marked as its own.** The change log takes the author from the row's own
  columns, so an automated load that fills in a person's identifier will read as that person's
  work forever. Load under a system identity, and the flow view keeps telling the truth about
  who is a person and what is a machine.
- **It is still a language model with a large key.** The DDL guard applies to it, but nothing
  stops it dropping a table. Confirm before anything irreversible; never delete to start over.

## 19. A file of rows is handed over, not keyed in

Measured 2026-09-15, same synthetic export of 61 support tickets — with a duplicate key, six
spellings of "closed", and a `999` sentinel in the hours column — given to two doors with the
same words: *"there is an export like this every month; put it in so we can analyse it."*

**Through the agent's tools:** the agent registered the file, asked for a table with a sound
design, and *noticed both traps* — it told the user about the casing and the sentinel. Then
it wrote them nowhere: no note, no skill, and column comments are not its to write. The
caretaker built the table from the request, which did not carry the rules. In its next
session the agent loaded rows by re-keying them through the model, three or four per call,
and stopped at 19 of 60. Six sentinel rows sit in the table as real hours. Both business
questions would answer wrong, quietly.

**Through the caretaker:** one session, under four minutes, no human. Sixty rows with the
original row and the file's hash on each; a unique key that made the duplicate impossible;
the status kept raw *and* normalised, the hours kept raw *and* a valid column that is null
where the source said 999; comments on all four columns and on the table saying what one
row is and how to read it; the delivery registered; a public note with the reading rules.
Asked the two questions through the door afterwards, an ordinary agent got both exactly
right.

The rows were never the hard part. What the agent door loses is what makes them usable next
month — and the knowledge that would have saved it was in the agent's own reply, twice.

So: an agent **hands over** a file of rows — registers it and says what it noticed — and the
caretaker **loads** it. The placement rule does not yet say this; the agent followed the rule
it had and did the wrong kind of work well. Whether the request should carry the agent's
observations as a field, or the rule should simply forbid re-keying, is an open decision.

## 20. Tabular data from a person: the file is the transport, not the chat

§19 measured the wrong thing being done well. The agent was asked to put an export into the
store and did what its tools allow: it re-keyed rows through the language model, three or
four per call, and stopped at 19 of 60. A typed table did not cause that, and a schemaless
one — a `jsonb` landing table, the SaaS pattern — would not have cured it. The bottleneck is
that **the file never reaches the database; only the model's tokens do.** Sixty rows became
36 calls and half a table. Five thousand rows would not arrive at all.

What a spreadsheet tool actually does when you hand it a CSV is the clue: it does not let
you type the rows in; it takes the file and parses it server-side. That is the missing
capability, and it is small:

```
agent    register_document(tickets.csv)        the bytes go up, they are not re-keyed
agent    request_structure(...,
           observations: ["999 in hours means not recorded",
                          "closed is spelled three ways"])
loader   reads the CSV where the bytes are, creates or fills the table,
         writes the observations into the column comments, registers the delivery
```

The agent keeps the part it did well in §19 — it noticed the sentinel and the casing on its
own — and that goes into the request as a field instead of evaporating in a reply. The load
happens where the file is, with SQL, the way the caretaker did it. No row passes through
the model except the sample the agent reads to form its observations.

Two things follow that were not obvious before:

- **Uploading to Storage stops being double storage for this case.** §19's rule — a pointer
  and a hash by default, the file only when its origin cannot be trusted — stands for
  documents. For a file that is to be *loaded*, Storage is the transport, not a second
  copy: the loader has to be able to read the bytes.
- **Typed columns keep winning for the reason they won today**: a `jsonb` key cannot carry
  a comment, and the comment is where the reading rule lives and how `skillhub_query`
  warns the next agent. The landing-table pattern remains what it was — a defence against
  four hundred exports becoming four hundred tables — and it remains deferred for the same
  reason: the next real export decides it.

Built the same afternoon, and measured on the same file. `skillhub_upload_url` registers
the file and returns a one-time signed upload URL — the agent uploads with `curl` from its
own shell, no API key needed, no row through the model. `skillhub_request_structure` takes
`observations`, `document_id` and `natural_key`. The caretaker's
`platform.load_registered_file(request_id)` builds the table from the request, writes each
observation into the column it names, resolves the request, and hands the file to the
loader, which reads it from Storage and upserts through `skillhub_load_rows` in slices.
`skillhub_load_file` lets an agent do the same into a table that already exists — next
month's export, no caretaker.

Same 61-row export: 60 inserted and 1 updated by the caretaker's load (the duplicate
upserted on itself); the three observations the agent filed *are* the column comments on
`hours_spent`, `status` and `ticket_no`, and `skillhub_read` hands them to the next agent;
delivery registered with file, hash and counts. Then the agent alone, month two: 0 inserted,
61 updated, delivery registered under its own name. The near-duplicate guard refused a
`_v2` table beside the existing one on the first attempt — correctly — which is why the
caretaker's call takes a `target_table` of its own choosing.

The agent went from typing 19 rows in three minutes to handing over 60 in one call. The
knowledge it had went into the store instead of a chat reply. That is the whole change.

---

## What this does not do yet

Named, measured where possible, and deliberately not built:

**Joins.** Asked which products account for the most deviations, an agent ran ten separate
queries and assembled the ranking itself — correctly, and it named the limitation nobody had
told it about. So this costs tokens and time, not answers.

**Editing your own text.** The library is append-and-retire. Correcting a typo takes two calls
and leaves two rows. Traceable by design, and worth waiting to see whether it gets in the way.

**A landing pattern for extracts.** One table, a record type, a natural key and the row as
`jsonb`, so four hundred exports do not become four hundred tables. The alternative —
promoted columns with the reading rules in the comments — is what runs today and works. The
next real export decides it, on one question: which version makes it easier to find out how
the data has to be read?

**Document contents.** The catalogue knows a file's name, size and hash; nothing reads inside
it. This is the largest remaining difference from a document management system, and it is a
content decision with a real cost rather than an architectural one.

**A token per agent.** Then §14 stops being decorative.

---

## On citing a document, which is still not solved

When an agent ingests a document, it summarises — correctly and usefully. Measured twice, the
summary loses two things that matter in a regulated context.

**The source's own addressing.** Of seven clause numbers in a quality manual, two survived the
first ingest; the agent re-headed the document under its own structure. Adding a rule to keep
the source's numbering raised it to twelve clause references and headings that carry them —
but at clause-range level, not clause level.

**The distinction between quotation and summary.** An agent answered a supplier question
correctly and presented the condensed sentence in quotation marks as the manual's wording. It
was not. Same meaning; in an audit, the auditor opens the manual and does not find the
sentence.

The rule now says: carry the numbering over, and never put quotation marks around text you
condensed. After it, an ingest added a provenance header on its own and wrote the rule forward
to the next reader — *"the original is the authoritative source; this text is condensed, not a
verbatim quotation; preserve the clause numbers when answering."*

Re-measured on a fresh install after the rule landed: the ingest kept **32** of the manual's
clause numbers (from 2, then 12), used no quotation marks at all, and a second agent that had
never seen the document answered a design question citing 5.3, 8.3.1–8.3.6, 8.5.1–8.5.2 and
8.6 by number. Good enough to cite from, for prose.

What still does not survive is a **table**. The manual's gate table lists four roles that
sign off G5; the condensed skill kept two of them, in a sentence. The agent did the right
thing with that — it deferred to the PDF for the full role table instead of inventing the
other two — which is the honesty property working and the limitation stated at once.
Structured content in a document wants a table in the store, not a paragraph in a skill;
that is a structure request, and the ingest rule does not say so yet.
