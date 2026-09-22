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

**What the first live run showed (demo, 2026-09-15).** Same words, same file, an agent on the
demo instance. It searched the store first — correctly — found the house standard
`load-from-source-system` 1.0.0 and followed it. That text was written for a caretaker with
SQL and said *"the file itself is uploaded to Storage by a person — you cannot upload
bytes"*, so the agent planned the §19 path from a rule, not from ignorance: rows into
`sample_rows`, a document record, a skill. The tools carried the new path in their
descriptions; the skill an agent actually follows carried the old one, and the seed inserted
a skill only when its slug was absent, so no running instance would ever have received a
rewrite. Fixed as version 1.1.0 of the skill — the seed adds a version and marks the old one
superseded, never edits — and `request_structure` no longer invites rows into `sample_rows`
when a file exists. An agent does what the store says; the store had two answers.

**Second run, same day, after the fix — two agents, no human in the loop but the prompt.**
agent_04 uploaded the file (`skillhub_upload_url`, curl) and filed request #4 with the
document id, the natural key and its observations. The caretaker agent, holding the service
key, ran `platform.load_registered_file(4)`: table built, 60 rows in, 1 updated (the
duplicate), every observation on its column — and it added the value distributions it saw.
agent_04 then re-loaded the same file itself: 0 inserted, 61 updated, no caretaker. It also
raised a false alarm — a note and a skill version saying the comments were misplaced — and
retracted it in the next version after reading the table again. Both stand in the log. The
store now answers *how many tickets are closed* correctly only for an agent that reads the
comment on `status`, which is the test in VERIFY §6 with this data.

## 21. The index configures itself and embeds in chunks

The client's embedder is a vLLM at `--max-model-len 2048`, tuned for a RAG tool that feeds
it 512-token pieces. The store fed it whole objects: one vector per skill, note or
document. A 14,000-character skill was refused outright — not truncated, refused, and its
seven slice-mates with it, every five minutes. The workaround was a character cap, set by
hand, which embedded the opening of a long skill and lost the rest. Four variables had to
agree with each other and with the model (`URL`, `KEY`, `MODEL`, `DIM`), and the dimension
locked itself on the first row.

Since 2026-09-16 the indexer asks. On its first run it embeds one word and reads the
dimension off the answer; while the table is empty it sets the vector column to it. It asks
the server how much one input may carry — TEI answers on `/info`, vLLM on `/v1/models`; OpenAI
answers neither and gets sizes tried from 24,000 characters down. Where the limit is in
tokens it also measures characters per token on a Swedish-and-English sample from the
endpoint's own usage figures — Qwen's tokenizer spends more on Swedish than OpenAI's, and a
chunk sized on an assumed ratio would be refused — and on vLLM it asks for truncation at
the limit as a belt to those braces. What it found is written
to `platform.embedder` and shown by `skillhub_overview` under `index`, with the result of
every run — so "my colleague cannot find what I wrote" has a place to look. Three variables
remain.

Objects are cut on their own headings into chunks of that size, each carrying the title,
saved together or not at all. Similarity returns an object once, at its best chunk, and
names the section. Measured on dev with a 3,000-character budget: two skills became nine
chunks, and *"what to do with a csv export when the table already exists"* found the loading
skill at its first section. A RAG embedder at 512 tokens is now enough.

**Measured against the client's own embedder, 2026-09-16** (Qwen3-Embedding-8B FP8 on vLLM,
`--max-model-len 2048`, `--max-num-seqs 8`): the indexer read `max_model_len` off
`/v1/models`, measured 3.89 characters per token on a Swedish-and-English sample, chose
6,773 characters per chunk, found the model returns **4,096** dimensions and rebuilt the
column at that width — no HNSW above 4,000, so an exact scan, which is milliseconds here.
Then 62 objects in 66 chunks, nothing truncated, nothing failed. Matryoshka was the one
thing that would have bought an index: the endpoint refuses `dimensions=1024` outright, so
4,096 and an exact scan is the answer with evidence rather than by default. Real store
content tokenizes at 4.2-4.35 characters per token — better than the prose the probe
measures on, so the headroom holds. Swedish questions against English content on a private
model: *"vad gör jag med en csv-export när tabellen redan finns"* → the loading skill at
0.71; *"hur många ärenden är stängda"* → the comment on `support_tickets.status` that says
the column carries three spellings of closed. That is the whole retrieval layer, on hardware
the client owns, with nothing leaving the building.

The chunker found something else on its first run: the conventions skill on dev was 201,433
characters, holding "## Overview" sixteen times. Three seed statements strip their own
section and re-append it, and all three used the regex flag under which `.` stops at a
newline — so the strip removed one heading line and the skill grew by four sections on
every boot, for two weeks, on every instance. Nothing read it in full, so nothing noticed.
The empty-database test now seeds twice and counts each section once.

## 22. An agent sees what became of what it asked for

A structure request is the one place an agent hands work to a person and waits. Until
2026-09-16 the answer never came back: `platform.v_structure_requests` is the caretaker's
queue, and nothing on the agent side read it. Measured the same day, twice, on the demo —
agent_04 filed a request, saw it still open in the caretaker's queue, concluded the
delivery was done and waiting, and stopped. Correctly, on the only information it had.
Then it refused to fabricate the step it could not take, which is the behaviour you want
and no consolation at all.

`skillhub_overview` now carries `your_requests` for the calling agent: open ones, and
anything answered in the last thirty days with the caretaker's own sentence. Declined
usually means *it already exists somewhere* — the answer is worth reading before asking
again. It costs one more field in the tool every agent runs first.

The general shape, worth stating because it will happen again: **a queue with one reader is
a wall, not a queue.** Anywhere the store asks an agent to wait, the answer has to reach
the agent through a tool it already calls, not through a view someone else reads.

## 23. A vector outlives the thing it points at

Retiring takes an object out of keyword search. Making a note private keeps it out of the
index in the first place. Neither removed a vector that was already there — so a retired
skill stayed findable by meaning, and a note flipped from public to private kept the vector
it had while it was public. Private skills were indexed outright, where private notes and
documents never were.

Found on 2026-09-16 by arithmetic: a rebuild on the demo came back with 73 objects where
the index had held 79. The six were retired. Nothing was wrong with the rebuild; the six
should not have been there.

Two halves, because one is a guarantee and the other is hygiene. `skillhub_similar` asks
`platform.embedding_visible` before returning a hit, so correctness does not depend on the
index being tidy. The indexer prunes on every run, so the numbers an agent reads are true
and the filter almost never has to fire.

The general shape: **anything derived from content inherits the content's permissions, and
inherits them at the moment of reading, not at the moment of writing.** A cache that
remembers what something used to be allowed to be is a leak with a plausible explanation.

## 24. An operating surface, because nothing was asking

By 2026-09-16 the store could answer every operational question. `v_index_status`,
`v_embed_queue`, `v_action_items`, `v_going_stale`, `v_abandoned_tables`, `v_caveats`,
`v_structure_requests`, the change log — all of it was there, and every fault found that
day was found because somebody happened to look: a house standard that had gone stale, a
cron that swallowed its own failures, a skill that grew four sections a boot for two weeks,
vectors that outlived the objects they pointed at, chunks cut without a number moving.
That is not an operating model. It is luck with a good memory.

So: `platform.health()` — one call, a verdict of ok, attention or broken, and for each
check what is true and the call that deals with it. `utils/health.sh` runs it from a
monitor and exits non-zero **only** on broken, because a check that fires on work-in-
progress stops being read. `platform.index_runs` keeps seven days of runs, so "has this
been failing at night and recovering by morning" has an answer. `platform.backups` records
what `utils/backup-content.sh` did, so the question asked after an incident was answered
before one.

Two decisions inside it are worth naming.

**The caretaker gets it through the tool it already runs.** `skillhub_overview` returns a
`caretaker` section when the caller holds the service key, and nothing when it does not. No
second door, no separate thing to remember. The agent that reads the store at the start of
a session reads how the store is running in the same breath.

**Looking and changing are different keys.** An agent handed a list works through the list.
So the safe calls — every one a `select` — are a list called `look`, and the few that change
something are `decide`, each with a sentence saying what it changes. A store that says `ok`
needs nothing, and the surface says so in those words, because the failure mode of giving an
admin key a to-do list is an agent tidying a table that was next month's report.

And a house standard, `caretaker-operations`, tagged like the others so it is found by
searching rather than by being told: what to check, the four things a caretaker actually
does, and what to leave alone. The cheapest guard against improvisation is not a rule that
forbids — it is a ready answer for the thing that was about to be invented.

## 25. The shape of a search decides whether an index can serve it

Chunking made one object several vectors, so similarity search grouped them: one hit per
object, at its best chunk. The grouping and the visibility check went inside the ordered
scan — `distinct on (source, id) order by source, id, distance` — and that is a query no
vector index can serve. Measured on a scratch store at 4,096 dimensions, the client's case,
on a host deliberately starved to 1.5 GB:

| chunks | the search agents ran | the bare nearest-neighbour scan |
|---|---|---|
| 2,000 | 0.3 s | 0.03 s |
| 10,000 | 5.6 s | 0.2 s |
| 25,000 | **28 s** | 0.7 s |

Every row's distance computed, every row sorted, every row's object looked up. The same
shape kept the 1,536 HNSW index from being used at all, and the half-precision index built
for 2,000–4,000 dimensions had never been usable: the query compared `vector` to `vector`,
and the index is on `vector::halfvec(n)`. It was built, maintained, and read by nothing.

Now two stages. `platform.similar` returns the k nearest chunks and nothing else — `ORDER BY
distance LIMIT k`, written in the expression the index was built on, regenerated for the
dimension. `skillhub_similar` groups, filters and looks up titles on those k rows (twenty
per hit wanted, at least a hundred). Same 25,000 chunks:

| dimension | index | before | after |
|---|---|---|---|
| 4,096 | none | 28 s | **1.1 s** |
| 1,536 | HNSW | index unusable | **62 ms** |
| 3,072 | half-precision HNSW | index unusable | **78 ms**, against 685 ms for the same scan without the cast |

The empty-database test now asks whether the index *can* serve the search — sorting
disabled, so the vector index is the only path that returns rows in distance order — and was
shown to fail on the old shape put back by hand. An earlier version of that check disabled
only sequential scans and failed the correct query: on a small table the planner answered
with a bitmap scan on the primary key.

Two things the measurement leaves standing. At 4,096 dimensions there is no index, so a
search is linear in the number of chunks: about a second per 25,000 on a starved host,
tolerable into the tens of thousands and not beyond. And building HNSW on a full table with
the default `maintenance_work_mem` took 285 s at 1,536 and 404 s at 3,072 for 25,000 rows.
`platform.reindex` never does that — it empties the table and the index fills row by row —
but anyone recreating the index by hand should raise it first.

## 26. A noticeboard, not a bus: agents asking each other

Decided and built 2026-09-17.

Watching agent_01 write something and agent_02 find it raises the obvious next question: can
they ask each other? Somebody in an office says *does anyone know where the hole punch is*,
and whoever knows answers. A2A and the like exist for that, but the interesting version here
is the one that lives in the store.

**The thing that decides the design: these agents are not processes, they are conversations.**
A Hermes agent runs when a person is talking to it. Nothing is listening in between, so
nothing in the store can call an agent -- it can only leave something that is there when the
agent next looks. So this is a noticeboard in the tea room, not a walkie-talkie, and the joke
works precisely because the note stays up.

Which fits the grain of what already exists. A structure request is exactly this pattern for
tables: an agent that has nowhere to put data leaves one, and reads the answer in
`skillhub_overview`. What is missing is the same thing for knowledge -- an agent that cannot
find something has nowhere to put the question.

| Part | What |
|---|---|
| `platform.asks` | who asked, the question, an optional addressee, open or answered, when |
| `skillhub_ask(question, for_agent?)` | leaves the note |
| `skillhub_answer(ask_id, answer)` | answers it; more than one agent may |
| `skillhub_overview` → `asked_of_you`, `open_questions` | what an agent sees at the start of a session, beside `your_requests` |

**What makes it worth building is not the message but the trace it leaves.** An answered
question is a note waiting to be written, and the rule has to say so: *if you answered
something that was not in the store, write it down, so the next person does not have to ask.*
Then the noticeboard is a pump that fills the store rather than a conversation beside it.
Without that rule this is Slack in Postgres, which is a thing to avoid on purpose.

**The limit, stated plainly: there is no push.** A question is seen when a colleague's agent
next starts a session -- in ten minutes, or tomorrow. The store could push: pg_net is there
and a Hermes gateway has an HTTP API. It would mean holding every agent's URL and key in the
database, and *no key material in the database* is one of the few things this design has never
traded away. Live agent-to-agent belongs to A2A, and A2A assumes agents are addressable
services. Ours are people's laptops and a dashboard.

Two more things it gets right for the same reason. Eight agents each seeing a list of open
questions every session is a way to manufacture bad answers, so the list is five, oldest
first, an agent is never offered its own, and answering is optional. And a question closes
on the first answer -- one ask, its answers, done. The store is not a messaging app, and
there is no third tool for closing one.

**Built as `platform.asks` and `platform.ask_answers`, two tools, and a section in the
conventions skill.** `skillhub_ask` searches the store before it posts and hands back what it
found, for the same reason `skillhub_request_structure` answers with existing tables: the
cheapest answer is the one nobody had to give. `skillhub_answer` ends with the rule in capital
letters. `skillhub_overview` carries `questions` — addressed to you, open to anyone, and your
own with the answers — and `platform.health()` says when one has sat unanswered for days,
because nobody is notified and a person can fix that in one sentence. The board is
deliberately **not** indexed for meaning: a question is not knowledge.

Measured the same evening, through the gateway: agent_01 asked where the hole punch was,
agent_04 saw it under `asked_of_you` at the start of its session, answered, and agent_01 found
the answer under `your_questions` — with the tool telling agent_04, in those capitals, to write
it down so nobody has to ask again. The joke works.

## 27. The house's own document had no history

Every skill an agent publishes has kept every version since the beginning: publishing
supersedes, it never overwrites, and retiring marks. The conventions skill — the one document
every agent obeys — was the exception. Four seed files each rewrote their section of it in
place, on every boot, and the row carried whatever the last one left. One row, and what the
rule said last week was gone.

Two faults, and the second was worse. The text surgery bounded each section by the heading
that came next, so every file had to know what could follow it: the day a section was added
below, the file above it silently deleted the new one on every boot and the one below re-added
it. Two writes to the change log for nothing, found by the check that says a boot writes
nothing.

Sections are rows now. `platform.convention_sections` holds one per file that owns one, each
file declares its own with `platform.put_conventions_section` and writes nothing when the text
is unchanged, and `platform.assemble_conventions()` — last in the seed — joins them and
**publishes a new version** when the result differs from the current one, superseding the
previous. Ordered rows cannot delete each other, so the marker lists are gone.

On dev the first assembly after the change published 2.4.0 and marked 2.3.0 superseded. A
second boot writes nothing at all.

And the history is readable, which it was not: `skillhub_read` takes a `version` and always
lists the versions that exist, with who published each and what superseded it. Before this,
the rows were there and only the caretaker could see them, with SQL — *what did the rule say
last month* being the first question an auditor asks. Asking for a version that never existed
answers with the ones that do.

Still not versioned: notes, which are edited in place, and table rows, where the change log
keeps a breadcrumb and never the previous value. That is the same decision as ever — the log
holds no contents, which is exactly why agents may not delete — and changing it is a decision
to take deliberately, not a gap to close quietly.

## 28. A manual nobody could open

`start_here` was written when the store was built: nine ordered steps, each with what to do
and why, seeded on every boot. Nothing ever read it — not a function, not a tool, nothing but
one SQL line buried in the conventions skill. And every step told its reader to run raw SQL,
which is the single thing an agent key may not do. It was written before the tools existed and
never caught up: a manual nobody could open, telling its only reader to use a door that had
since been closed.

So the steps now name tools, and `skillhub_help` is the door. What it deliberately is **not**
is a second manual. The tour lives in `start_here` and nowhere else. The topics are the skills
tagged `house-standard`, read live, so a new one becomes a topic the moment somebody publishes
it — the store writing its own manual. The tools describe themselves in the client's own tool
list, and repeating them here would be two places to keep in step; `skillhub_overview` stopped
restating the tour too, and points at help instead.

Two details that decide whether it is used. It returns **text, not jsonb**, for the reason
`skillhub_report` does: the reader may be a person looking at a chat window, and a wall of
JSON is exactly what is unreadable there. And a topic resolves the way `man` resolves a word,
not by substring: *loading*, *csv* and *xlsx* all reach the loading standard, *admin* and
*operations* reach the caretaker's, and a word that reaches nothing answers with the words that
do. `loading` is not a substring of `load-from-source-system`, which is precisely the kind of
detail that decides whether somebody types it twice or never again.

## 29. The document's own words

Until 2026-09-18 the catalogue knew a file's name, size and hash, and nothing read inside it.
Every question about a manual was answered by an agent's condensation of it — a good one,
after §16, with the clause numbers kept and no invented quotation marks — but never by the
manual. In a regulated shop that is the wrong way round: the auditor opens the document, and
what the store could show was somebody's reading of it.

The store does not parse PDFs. The agent's machine does, with `pdftotext`, which the Hermes
image now carries — a born-digital PDF becomes text in tens of milliseconds, and the day an
agent spent minutes on OCR for one was the day that decided this. `skillhub_upload_url` gives
two curl lines instead of one: the file, and its text beside it. `skillhub_load_text` then
reads the text from Storage server-side, keeps the page breaks as page markers, and stores it
verbatim. No page passes through the model on the way in, for the reason no row does in §20.

From there the existing machinery does the rest. The text is indexed by keyword with a
generated tsvector, and the excerpt of a hit is the passage that matched rather than the
description. It is chunked and embedded like a long note, with the page markers as headings,
so a hit from `skillhub_similar` names the page — and a chunk cut from the middle of a long
page carries the page forward as *continued*, or half of every page would have been
uncitable. `skillhub_read` gives the text whole when it is short and by `pages` when it is
not; a 300-page manual is not something to hand a model in one piece, and a citation is a
page anyway.

Measured on a ten-page quality manual: 25,339 characters loaded, 14 chunks, a search for
supplier surveillance answered with the manual's own sentence as the excerpt, a Swedish
question answered with page 8, pages 7–8 returned verbatim on request.

What did **not** change is the placement rule's shape. `skillhub_register_document` alone is
still a pointer — name, bytes, hash — and still shares nothing of what the file says; the
rule now says so in those words instead of claiming that nothing ever reads inside a file.
And the condensed skill an agent publishes from a document is still the curated layer. The
loaded text is what it was condensed from, which is exactly what the skill lacked: something
to be checked against.

---

## 30. A third visibility, and one door that decides

**Decided 2026-09-18.** Rows can be `team` as well as `public` and `private`. A team is a
word in `public.agents.team`, typed by the caretaker; a team row is readable by every agent
whose word is the same as the owner's. The caretaker reads everything, as before.

**Why now.** ISO 9001 asks who may see a record, and the store had two answers: everyone, or
the one agent that wrote it. A purchasing note that sales should not read had nowhere to go
but private, where purchasing's other agent could not read it either. Departments are the
third answer, and a department is a word, not a mechanism: the same words another system
uses for its roles can be typed into the column, so "team" means one thing across systems.
The words to borrow are FlowWink's eight functional roles — `sales`, `hr`, `accounting`,
`support`, `warehouse`, `marketing`, `purchasing`, `projects` — its role matrix
(`role_module_access`) decides which *modules* each of those may open, and it deliberately
never restricts *rows* ("horizontal — never restricted", its own words). A team row here is
that horizontal axis, for the one store where it is needed: an agent's notes and documents
are the department's, not the company's, and FlowWink has no such thing to gate.

**What decided the shape.** The rule *may this agent read this row* existed as the same
two-clause expression in nine places — the three search branches, four read paths, the
query tool, the activity log. Adding a third clause in nine places is how one of them gets
missed, and a team row leaking through the door that was forgotten is exactly the failure
this is meant to prevent. So the rule became one function, `platform.may_read(visibility,
owner, agent)`, and every read path calls it. The activity log turned out to be the door that
was already open: it recorded the *title* of every write, and every agent read every title,
private ones included. It now takes the caller and asks the same function.

The write side has one door too: `platform.visibility_for(agent, wanted, private)` is what
every write tool stores. An agent with no team asking for `team` is refused rather than
stored, because a team row nobody can read is a row that vanished, and the writer would not
know.

**What is deliberately not done.** Team rows are not indexed by meaning. The rule "nothing
non-public is indexed" stays as it was, because the vector store has one filter and it is
the cheap one; a team's knowledge is found by its words and by its owner. If a department
one day needs meaning search over its own material, that is a separate decision with its
own cost — a visibility check inside the nearest-neighbour scan is the shape §25 measured at
28 seconds. And no agent can set a team, its own or anyone's: the agents table has no
convention columns, which is what keeps every tool out of it (§conventions), and that is
the whole guarantee. A wrong word in that column is wrong readers, and the caveat says so.

**Measured.** Empty-database test: an agent in the team reads the note, one outside does
not, the caretaker does; search, query and the activity log answer the same way; the
indexer never lists it; an agent with no team is refused. The same probe on dev, live.

---

## 31. A feed does not break, it goes quiet

**Decided and built 2026-09-19.** `platform.v_sources` is now one row per **feed** -- a source
system loading into a table -- with the rhythm it delivers on and whether the next load is
overdue. `platform.health()` reads it out as a `feeds` line.

**Why.** The store was always meant to be filled by agents on schedules: an agent with a cron
job against an ERP's API is an integration, and the store already recorded every load in
`platform.deliveries` (source, file, hash, inserted, updated). Nothing read that register.
And the failure mode of a scheduled load is not an error -- it is silence. The job stops, no
call fails, the table simply stops growing, and a report built on it is quietly wrong for a
fortnight. Freshness the organisation cannot see is freshness it does not have.

**What decided the shape.**

*Into the view that existed, not beside it.* `v_sources` already promised "start here when
someone asks whether the data is current"; the cadence columns finish that sentence. A second
view answering nearly the same question is the parallel surface §28 was written to avoid.

*Keyed on table AND source system.* Two systems feeding one table are two feeds with their own
freshness, which is the whole point once a store has several connections. The first thing the
change showed on dev was a real defect in the data: `support_tickets` had been loaded under
three spellings of the same system. So `skillhub_load_file` now says to keep the name stable,
because a new spelling is a new feed with no history.

*Three deliveries before anything is a feed.* A table loaded once is a **file**, and reporting
a one-off import as an overdue feed is how an operating surface becomes noise the caretaker
learns to skip. The rhythm is inferred from the deliveries themselves -- nothing declared,
nothing configured, the same posture as the self-configuring indexer -- and `quiet` means the
last load is more than twice that rhythm old.

*Attention, and a look, never a decide.* There is no call in this store that restarts somebody
else's cron job: the schedule lives in the agent that runs the load. So the check names the
feed and the person passes it on. It is never `broken`, because `utils/health.sh` exits 1 only
on broken and a quiet feed must not fail a cron.

**And loaded rows now carry a visibility.** Until today every loaded row was public whatever
the loader asked for, so a department's own feed had nowhere to land but in front of
everybody. `skillhub_load_file` and `skillhub_load_rows` take `visibility`, through the same
`platform.visibility_for` as every other write. The caretaker is refused `team` with its own
sentence: a row reaches a team through its **owner**, and a team row owned by `service_role`
would be readable by nobody at all -- so a department's feed is loaded by the department's
agent, which is also the only arrangement that stays true when somebody reads the change log.

**What this is not.** It watches feeds that register deliveries. An integration written as
direct `skillhub_add_rows` calls is invisible to it -- that is a property of the loading
standard, not a gap to patch here.

---

## 32. Watching the caretaker mirror a CRM

**2026-09-20.** The caretaker was given one instruction -- connect to a CRM and make the store
a read-only mirror of part of it -- and left alone overnight. What it did is the best evidence
this repository has about its own design, so it is written down as found.

**It needed nothing new.** It authenticated over JSON-RPC, inventoried twenty models, chose
four domains, built twelve tables through `create_shared_table` -- every one following the
convention -- kept the source's own identifiers as the key, and added columns the CSV standard
never mentions: `source_model`, `extraction_run_id`, `extracted_at`, `raw` as jsonb, and the
source's `write_date` as a watermark it then checked against the source on the next run. No new
tool, no new permission, no code. That is the claim this store makes, tested by somebody who
was not told how.

**Three things the store got wrong, all of them about seeing rather than doing.**

*A delivery was file-shaped.* `platform.deliveries` had `filename` and `file_sha256`, because
every load until then had been an export somebody uploaded. A mirror has no file -- it has a
model, a run, a watermark, and rows it read and deliberately did not write. So the caretaker
wrote its run journal as **notes**: six of them in seventeen minutes, each embedded at a cost,
each competing with real knowledge in search. It knew what it was doing, too; one of them ends
"public status note, no secrets". The register now has those columns, and
`skillhub_record_sync` hands it to the agent that knows the numbers. Same grain as before -- one
row per table per load -- so `v_sources` and the feeds check needed no change at all.

*Nothing was registered, so nothing was visible.* Twelve freshly filled tables and an empty
delivery register: the feeds line built the day before watched nothing, and the store could not
answer what fills it. The gap was named as theoretical in §31 twenty hours earlier. It took one
real integration to become the main finding.

*An idle sync and a broken one looked identical.* A healthy incremental run reads 39 and writes
0, because the watermark did its job. So does a run against a source that has stopped
answering. The register now keeps the watermark and says when it has not moved.

**And one thing that was neither the store's fault nor a mistake, exactly.** Nineteen structure
requests, all filed by the caretaker to itself, and a note titled "Approval: continue the
read-only mirror" -- also written by itself. Being both the agent that needs a table and the
only one who can build it, it simulated the approval loop the request flow implies. The flow
stays as it is; `platform.health()` now counts its own queue apart, so nineteen notes-to-self
stop reading as nineteen blocked colleagues, and the `mirror-a-live-system` standard says it
plainly: a request you filed and did not resolve is not deliberation, it is a stall, and nobody
else is coming.

**The shape it invented is now the house standard.** `mirror-a-live-system` 1.0.0 carries what
it got right and what it got wrong, dated, the same way `load-from-source-system` carries the
quality register an agent brought in. That is the intended way this library grows: an agent
solves something, and the solution becomes what the next one starts from.

---

## 33. What the first agent on a client install did with the rules

**2026-09-21.** A new SkillHub and a new Hermes on a client's own Easypanel. The first agent,
not the caretaker, was told in Swedish: research Monitor ERP, we intend to integrate with it
later, find out everything we need to understand. Nobody told it about the store. Its reasoning
is the only unprompted evidence we have of how the conventions read from the outside.

**What worked, and it is the part that matters.** It found `skillhub_overview` and ran it. It
read `skillhub_rules` before writing anything. It classified its own output correctly --
*"this is 'how the system works' -- i.e., text"* -- and wrote a note rather than inventing a
table or publishing a skill. On a virgin instance, with credentials and nothing else, an agent
followed the house conventions and chose the right shelf. That is the product's central claim
and it held.

**Three things went wrong, and none of them was the agent's judgement.**

*The rule it had was precise and did not apply.* The instruction reads "before you ANSWER a
question **from this data**, run `skillhub_search`". The task's answer was on the web, so by
its own words the rule was silent -- and the agent deliberated over it in five separate
thinking blocks, each time concluding "do it anyway, to follow convention", and ran
`skillhub_overview` twice on the way. The reason that *does* apply to research -- a colleague
may have done this last week, and the store is where they would have put it -- appeared in none
of the rules it had. Fixed where the rules live, in hermes-easy's identity block.

*The store was the afterthought.* Its plan for the finished report: *"I'll create a structured
research document and save it to a file in the workspace, then present a summary afterwards. I
might also save a note to skillhub."* A file in a container's filesystem, which is gone at the
next restart, was the default; the store was optional. Nothing had told it otherwise -- every
rule about writing said which *kind* of thing to write, never that writing it here at all is
the point. One bullet now says so.

*Its client could not send the note.* Building the `tool_call` JSON for a 5 KB markdown note
with literal newlines inside a string, Hermes produced invalid JSON -- *"Expecting ',' delimiter
at character 4919"*. The agent diagnosed it correctly and worked around it by flattening the
note to a single line with spaces instead of newlines. That is a client-side bug we cannot fix
from here, but the damage landed in the store, and that part was ours:

**`chunk_head` accepted 120 characters of prose as a heading.** A flattened note has exactly one
line, that line begins with `## `, and so the whole opening of the note became the retrieval
pointer -- the same pointer on every chunk, naming nothing. The predicate is now one function,
`platform.is_heading`, asked by all three places that used to decide it separately: a heading is
short and is the only heading on its line, because a line carrying several markers is text whose
line breaks were lost in transit. Measured before and after on the same note: one shared
120-character blob, versus a distinct pointer per chunk. The structured case is unchanged.

**And the rule that follows from it.** Past a few thousand characters, text does not go in a tool
argument at all -- it is written to a file and handed over with `skillhub_upload_url` plus
`skillhub_load_text`, the same route a manual takes, and a `.md` or `.txt` needs no sidecar. That
was already the route for a file somebody gives you; the conventions now say it for text an agent
wrote itself. The result is a document held verbatim rather than a note, which is the right shelf
for a long piece of writing anyway, and a file never passes through a JSON string -- so nothing
about the text has to survive being escaped by whichever client happens to be carrying it.

The lesson is the same one §31 taught about feeds: the agent's work was fine, and what needed
fixing was the store's ability to see and keep it.

**Where a rule has to live, decided by how the agents are installed.** The caretaker runs from
`hermes-easy`, whose boot seed writes these rules into its `SOUL.md` on every start. The other
agents go on people's own laptops, configured by hand from `utils/agent-invite.md`: a key, an
address, and whatever the store tells them. So a rule that lives only in a deployment repository
reaches exactly one agent out of nine.

That makes the store's own two channels the authoritative ones, because they reach every client
whoever set it up: `skillhub_overview`'s `read_this_first`, which is the first thing an agent
calls, and the tool descriptions, which are what an agent is holding when it hits the problem.
Both now carry the rules above -- `read_this_first` at three lines, and deliberately staying
three, and `skillhub_write_note` saying in its own description that long text goes as a file.

The consequence is that the pasted block in the invite got **shorter**, not longer. It had
duplicated the reading rules, and a copy in a pasted prompt is frozen where it was pasted: eight
devices drift into eight rulebooks within a month. What remains is only what an agent needs
before it has called anything -- who it is, to run `skillhub_overview` first and follow what it
says, to check the rules before writing, and that there is no raw SQL door. That file argued for
this arrangement from the start; it is now also true of the block it hands out.

**And the caretaker can hand it out -- for everything but the key.** Asked the same day: could
the caretaker produce the invite itself and send it to a colleague? The store knows which slot is
free and what its own address is; it does not know the key and must not -- no key material is
ever in the database, and giving the caretaker's container all ten keys would make one hijacked
session a leak of every agent. So `inviting-an-agent` is a house standard: pick the free slot,
fill the address, send the text with `<KEY>` left exactly as it is, and say that the person who
holds the panel supplies it separately -- a key beside an address is the pair that makes a leak
immediately usable. The paste text lives in `utils/agent-invite.md`, which stays the source; the
skill carries a copy, and the empty-database test refuses a build where the two SOUL blocks
differ. Two copies of an onboarding block would otherwise become two rulebooks.

---

## 34. Three callers, no lock: what the client's caretaker found

**2026-09-22.** On the client's instance the caretaker reported six failed indexing runs, all on
the same slide deck, each with a duplicate-key error -- and, having read `caretaker-operations`,
correctly deleted the stranded chunk (the one delete the standard permits) and set out to extract
the deck's text itself. What it had found was ours.

**The race.** Three things call `/embed`: the cron every five minutes, the index-on-write
trigger on *every* public write, and `platform.reindex()`. Nothing stopped them overlapping. The
caretaker had run a reindex on a slow embedder while writing notes; each note fired a pass of
its own; two passes took the same document -- neither saw a current embedding -- and embedded it
twice. The save is delete-then-insert, so the second insert waited on the first's uncommitted
key and failed the moment it committed. Always the same object, because candidates come in a
stable order and every overlapping pass starts at the head of the same list. Tokens paid twice,
an object reported as failed that was in fact indexed, and a caretaker sent on an errand.

**The fix is a row, not a session.** `public.index_run_begin()` claims `platform.embedder` for
one pass and refuses a second within ten minutes; `index_run_end()` releases it, in a `finally`.
Not an advisory lock, because the indexer reaches the database through PostgREST on a pooled
connection and nothing session-scoped survives from one call to the next. Ten minutes is the
stale bound: a pass is capped at four minutes of budget, and a runtime that dies holding the
index must not hold it forever. A refused pass answers `skipped` and records nothing -- it is
not a failure, the pass that holds the lock is doing the work. And `embed_save_chunks` now
upserts on the key, so the race that remains is harmless rather than fatal: a second writer
carries the same text at the same hash.

**Two more things the same errand showed.** An agent had no way to get a file *back out* of the
store -- the caretaker guessed at `/storage/` and got 401 -- so `skillhub_download_url` is the
mirror of the upload: a signed URL for ten minutes, for a document the caller may read, plus
one for the text sidecar when it exists. And `skillhub_upload_url` had offered the `pdftotext`
line beside a `.pptx`, which cannot read one, so the deck sat catalogued and unsearchable. The
text line is now per file type: `pdftotext` for a PDF, a `python3` one-liner over `zipfile` for `.pptx` and `.docx` -- office
files are zip archives of XML; the first version used `unzip` and `sed`, and `unzip` turned out
not to exist in the agent's own container, which is the one machine the line is for -- and
for `.xlsx` the honest answer, which is that a spreadsheet is rows and belongs in a table.

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
