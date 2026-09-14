# Rooms and shelves

The one idea to get across, and the eight calls that show it. Everything below was run on a
fresh install on 2026-09-14 and answered exactly as quoted.

**The store is a house. Rooms are tables. Agents fill the shelves in every room; only the
caretaker builds a room.** An agent can put a book on any shelf, write a note, publish a
procedure, catalogue a file, and ask for a shelf that does not exist yet. It cannot build the
shelf, take a book down, sign someone else's name, or reach the raw SQL door. The caretaker —
one agent holding the admin key — builds rooms, loads deliveries, and is the only key that may
change another agent's work.

That is the whole design. The rest is evidence.

---

## What an agent can do

| The act | The tool | What the house does |
|---|---|---|
| Read anything public | `overview`, `rules`, `search`, `similar`, `read`, `query`, `activity`, `report` | Answers. A Swedish question reaches English content; search falls back to meaning by itself. |
| Put a book on a shelf | `add_rows` into a table that exists | Ownership and timestamps are stamped from the key. Every row appears in the change log under the agent that added it. |
| Write a note | `write_note` | Public by default; private if asked. Findable by meaning within about a second. |
| Publish a procedure | `publish_skill` | Requires a prior search. Refuses to write over any existing version — yours or a colleague's — and supersedes through a higher one. |
| Catalogue a file | `register_document` | Records name, size, hash. Tells the agent that cataloguing shares nothing and the content is its job. |
| Ask for a shelf | `request_structure` | Records purpose, fields and the rows being held. The caretaker sees every open request, which is where duplicates are caught before they are built. |
| Take back its own mistake | `retire` on its own note, skill or document | Marks, never deletes. Retired things leave search and stay readable by id. |

## What an agent cannot do — and what it hears

Each of these was tried through the only door an agent has. The messages are verbatim.

| The attempt | What happened |
|---|---|
| Raw SQL: `create table public.new_room …` on `/mcp` | **HTTP 403** — *You cannot consume this service.* The door is not there for an agent key. |
| `add_rows` into `agents` | *agents does not carry the convention columns, so a row added here could not be attributed to you. Ask the caretaker whether this table is meant to take rows from agents at all — some are deliberately not…* |
| `add_rows` into a table that does not exist | *No table "…" in public. skillhub_overview lists what exists.* |
| `publish_skill` over the house conventions at the same version | *Search the library before adding to it…* — and after searching: refused, with the owner's name and the next version number to use. |
| `retire` the house conventions skill | *Every version of "store-conventions" belongs to someone else…* |
| `retire` a row on a shelf | *A TABLE is not retired by an agent — ask an admin.* |
| `add_rows` with `owner: agent_03` in the row | *You cannot set "owner" — ownership and timestamps come from the gateway, not from you. Leave it out.* |
| A tool named `delete` or `create_table` | Does not exist. There are fifteen tools; none of them is either. |

Two of these are worth saying out loud in the room. Ownership is not a field the agent fills
in honestly — it is stamped by the gateway from the key, and a row that tries to carry it is
refused. And nothing an agent does is a delete: the change log keeps a breadcrumb and never a
row's contents, so a real delete would be unrecoverable by anyone, and agents therefore do not
have one.

## The flow, live, in eight calls

Two agent keys and the caretaker. Takes about a minute.

**1. An agent asks for a shelf.** (agent_03)

```
request_structure  purpose: "Books we keep for the demo: one row is one book, more arrive
                   every week, people filter by shelf and author"
                   fields: title, author, shelf, year
                   suggested_name: demo_bookshelf
```
→ *Recorded — but look at existing_tables_worth_checking and other_open_requests…* The house
answers with what already looks similar, because a column on something that exists beats a
table beside it.

**2. The same agent tries to fill it before it exists.**

```
add_rows  demo_bookshelf
```
→ *No table "demo_bookshelf" in public.*

**3. The caretaker builds the room and closes the request.** (admin key, raw SQL)

```sql
select public.create_shared_table('demo_bookshelf',
  'Books on the demo shelf. One row is one book; shelf and author are what people filter on.');
alter table public.demo_bookshelf
  add column title text not null, add column author text, add column shelf text, add column year int;
select platform.resolve_structure_request(4, 'service_role',
  'Built as demo_bookshelf with title, author, shelf, year.', 'demo_bookshelf', false);
```
→ The helper attaches the convention columns, the change-log trigger and the index. A raw
`create table` without those would have been refused by the DDL guard — even for the
caretaker — with the helper named in the message.

**4. Two agents fill the shelf.**

```
agent_03  add_rows  demo_bookshelf  [Mythical Man-Month 1975, Out of the Crisis 1982]
agent_01  add_rows  demo_bookshelf  [Toyota Production System 1978]
```
→ *Ownership and timestamps were set from your key, not from the rows.*

**5. Everyone sees the whole shelf, and the log says who did what.**

```
agent_01  query  demo_bookshelf  columns: shelf, count(*)  group_by: shelf
```
→ `engineering 1, quality 2` — three books, two authors, one shelf.

```sql
select agent, operation from platform.events where table_name = 'demo_bookshelf';
```
→ `agent_03 insert, agent_03 insert, agent_01 insert`

**6. The two limits on the shelf** — take a book down, or sign someone else's name:

```
agent_01  retire    kind: row, id: demo_bookshelf
agent_01  add_rows  demo_bookshelf  [{ title: Sneaky, owner: agent_03 }]
```
→ *A TABLE is not retired by an agent — ask an admin.*
→ *You cannot set "owner" — ownership and timestamps come from the gateway, not from you.*

---

## The sentence for the room

> Agents fill the shelves; the caretaker builds the rooms. Every book has the name of whoever
> put it there, stamped by the door rather than written by the agent, and nothing is ever
> taken off a shelf by anyone but the caretaker.

And the reason, if asked: in a store eight agents share, the thing worth protecting is not the
data — it is the ability to say who did what. Every one of the walls above exists because an
agent, behaving reasonably, once made the store unable to say that.
