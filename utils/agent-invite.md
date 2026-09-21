# SkillHub invite — paste this to the agent once

Three blanks, filled in on the device in front of you:

| Placeholder | Replace with |
|---|---|
| `<agent_NN>` | that person's identifier, agent_01 .. agent_10 |
| `<KEY>` | the MCP_KEY_NN carrying that same number |
| `<STORE URL>` | the store's address, no trailing slash |

**Keep the filled-in version out of every repository, chat and ticket.** A key next to
the address is the pair that makes a leak immediately usable, and a scanner caught
exactly that combination in this repository once already. The template is harmless —
that is the point of leaving the blanks in. `utils/make-agent-invite.sh` fills it for
you and refuses to write inside a git working tree.

## Why it is written as prose and not as commands

Hermes adds an MCP server itself from a plain description, writes it to its own
`config.yaml`, and it survives a restart — the same result as clicking "add MCP
server" in the UI. Verified 2026-09-11 against a fresh install with no configuration
at all: both servers landed, reconnected after a restart, 11 tools each. It did not
need `enabled` or `timeout` either, so nothing here spells out shell commands.

**The key is stored in clear text in `config.yaml` on that device.** Whoever holds the
Chromebook holds the key. That is the accepted trade today; rotate the slot in the
Supabase panel if a machine goes missing.

## What it is for

An installer, not a rulebook. It connects the agent and writes its identity to disk,
then hands the teaching to the server: the first bullet points at
`skillhub_overview`, so the rules can be changed centrally afterwards. A rule that
lives only in a pasted prompt is frozen where it was pasted, and eight devices drift
into eight different rulebooks within a month.

That is why the block below got **shorter** on 2026-09-21 rather than longer. Watching the
first agent on a client install showed two rules missing -- search the store before
researching something from scratch, and what you find out belongs in the store rather than in
a file on the machine you are running on. Both went into `skillhub_overview`'s
`read_this_first`, which every agent reads whoever configured it, and the reading rules that
were duplicated here went with them. What stays below is only what an agent needs *before* it
has called anything: who it is, where to look first, and to check the rules before it writes.

Verified end to end on a fresh install: after this invite, asked "how many individual
defects were reported in total" with no further hints, the agent searched the store,
read a colleague's skill and answered **28,638**. Two agents without the invite
answered **1,091,957** — the same question, thirty-eight times too high.

---

Connect yourself to our shared data store. Do these three things, then report back.

**1. Add this MCP server permanently, so it is still there next time you start.**
It uses streamable HTTP.

- Name `skillhub` — URL `<STORE URL>/skillhub`
- Header: `apikey: <KEY>`

One server, not two. Earlier versions of this invite also listed a `supabase` server at
`<STORE URL>/mcp`. That is the raw SQL door and it now belongs to the caretaker alone, so
an agent key gets **403** on it — the key is valid, it is simply not in the admin group.
If you added that server from an older invite, remove it: the 403s are harmless but your
agent will report a failing server on every start, and everything it needs is in the
tools on `skillhub`.

**2. Put this block in your SOUL.md**, so it applies in every future session and not
only this one. If a block with the same markers is already there, replace it.

```
<!-- skillhub:identity start -->
Shared data store: your identifier is <agent_NN>.

- Run skillhub_overview at the start of a session. It tells you what is in the store,
  and its read_this_first says how this organisation expects it to be used. Follow
  what it says -- those rules are kept in the store so they can be corrected for
  everyone at once, and this block is deliberately not a copy of them.
- Run skillhub_rules before you write anything: the rules decide whether something
  becomes a table, a note or a skill.
- Every write goes through a tool. You have no raw SQL against this store, and you do
  not need any: the tools attach the change log and take your identity from the
  gateway, which is what makes the store worth trusting.
<!-- skillhub:identity end -->
```

**3. Reload your MCP servers, then run `skillhub_whoami` and `skillhub_overview`**, and
tell me exactly what came back.

`skillhub_whoami` reports the identity the gateway reads from your key, not anything
you claim. If it says something other than `<agent_NN>`, stop and say so — the wrong
key reached this machine.
