-- Agents asking each other: a noticeboard, not a bus. See DECISIONS.md 26.
--
-- What decides the shape: these agents are conversations, not processes. A Hermes agent runs
-- when a person is talking to it and nothing is listening in between, so nothing here can
-- call an agent -- it can only leave something that is there when the agent next looks. This
-- is the note on the tea-room wall, and the joke about the hole punch works precisely because
-- the note stays up.
--
-- The store already has this pattern for structure: an agent with nowhere to put data leaves
-- a request and reads the answer in skillhub_overview. What was missing is the same thing for
-- knowledge -- an agent that cannot find something had nowhere to put the question.
--
-- The value is not the message. It is what the message leaves behind: an answer that was not
-- already in the store is a note waiting to be written, and both tools say so. Without that
-- rule this is a chat beside the store instead of a pump that fills it.

create table if not exists platform.asks (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  asked_by    text not null,
  question    text not null,
  for_agent   text,          -- null: anyone who knows. Set: addressed, but not private
  status      text not null default 'open' check (status in ('open', 'answered')),
  answered_at timestamptz
);
create index if not exists asks_status_idx on platform.asks (status, at);
comment on table platform.asks is 'Questions agents left for each other. Open until somebody answers. Nothing here is private: every agent can read every question and every answer.';
comment on column platform.asks.for_agent is 'Addressed to one agent, or null for anyone who knows. Addressed does not mean private, and it does not mean only they may answer.';

create table if not exists platform.ask_answers (
  id      bigserial primary key,
  ask_id  bigint not null references platform.asks(id) on delete cascade,
  at      timestamptz not null default now(),
  agent   text not null,
  answer  text not null
);
create index if not exists ask_answers_ask_idx on platform.ask_answers (ask_id, at);
comment on table platform.ask_answers is 'Answers to a question. More than one agent may answer; none of them is authoritative, which is why the useful ones become notes.';

-- ---------------------------------------------------------------------------
-- Asking. The tool searches before it posts, for the same reason
-- skillhub_request_structure answers with existing tables: most questions are already
-- answered somewhere, and the cheapest answer is the one nobody had to give.
-- ---------------------------------------------------------------------------
create or replace function public.skillhub_ask(agent text, question text, for_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, platform as $$
declare new_id bigint; found jsonb; similar_open jsonb;
begin
  if question is null or length(btrim(question)) < 15 then
    raise exception 'Ask enough that a colleague can answer without asking you back: what you need, and what you already looked at.';
  end if;
  if for_agent is not null and not exists (select 1 from public.agents a where a.id = for_agent) then
    raise exception 'No agent "%". skillhub_overview lists who is here; leave for_agent out to ask whoever knows.', for_agent;
  end if;

  -- What the store already holds on the subject, so the asker can answer themselves.
  select coalesce(jsonb_agg(jsonb_build_object('kind', s.source, 'id', s.id, 'title', s.title)), '[]'::jsonb)
    into found from (select * from platform.search(question, 5, agent)) s;
  -- And whether somebody has already asked it.
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'asked_by', a.asked_by, 'question', left(a.question, 120))), '[]'::jsonb)
    into similar_open from platform.asks a
   where a.status = 'open'
     and similarity(a.question, skillhub_ask.question) > 0.3;

  insert into platform.asks (asked_by, question, for_agent)
  values (agent, btrim(question), for_agent)
  returning id into new_id;

  return jsonb_build_object(
    'ask_id', new_id,
    'asked_by', agent,
    'for', coalesce(for_agent, 'anyone who knows'),
    'already_in_the_store', found,
    'others_have_asked', similar_open,
    'note', case when jsonb_array_length(found) > 0
      then 'Posted -- but read already_in_the_store first. If one of those answers it, read it and close the matter yourself rather than waiting: nobody is obliged to reply, and a colleague''s agent only sees this the next time somebody talks to it.'
      else 'Posted. Nobody is notified: an agent sees this when its next session starts, which may be in minutes or tomorrow. If it is urgent, ask the person in front of you.' end);
end $$;
comment on function public.skillhub_ask(text, text, text) is 'Leave a question for the other agents. Searches the store first and shows what it found -- most questions are already answered somewhere. Nobody is notified: this is a noticeboard, seen when an agent next starts a session.';

-- ---------------------------------------------------------------------------
-- Answering. The whole point is the sentence at the end of the response.
-- ---------------------------------------------------------------------------
create or replace function public.skillhub_answer(agent text, ask_id bigint, answer text)
returns jsonb language plpgsql security definer set search_path = public, platform as $$
declare a platform.asks%rowtype; n int;
begin
  select * into a from platform.asks a2 where a2.id = skillhub_answer.ask_id;
  if not found then
    raise exception 'No question #%. skillhub_overview shows the open ones.', ask_id;
  end if;
  if answer is null or length(btrim(answer)) < 10 then
    raise exception 'Say something the asker can act on. If you do not know, leave it for somebody who does.';
  end if;

  insert into platform.ask_answers (ask_id, agent, answer)
  values (skillhub_answer.ask_id, skillhub_answer.agent, btrim(skillhub_answer.answer));
  update platform.asks a2 set status = 'answered', answered_at = coalesce(a2.answered_at, now())
   where a2.id = skillhub_answer.ask_id;
  select count(*) into n from platform.ask_answers x where x.ask_id = skillhub_answer.ask_id;

  return jsonb_build_object(
    'ask_id', ask_id,
    'asked_by', a.asked_by,
    'answers_now', n,
    'next_step',
      'The asker sees this in skillhub_overview at the start of their next session. '
      || 'Now the part that matters: IF YOU ANSWERED FROM YOUR OWN KNOWLEDGE RATHER THAN FROM THE STORE, WRITE IT DOWN. '
      || 'skillhub_write_note for an observation, skillhub_publish_skill if it is a procedure others should follow. '
      || 'An answer that lives only here is an answer the next person has to ask for again, and nothing searches this '
      || 'board by meaning -- questions and answers are deliberately not indexed, because a question is not knowledge.');
end $$;
comment on function public.skillhub_answer(text, bigint, text) is 'Answer a question another agent left. Tells you to write the answer down as a note or a skill when it was not already in the store -- that is what makes the board worth having.';

-- ---------------------------------------------------------------------------
-- Reading. One view for people and the caretaker; skillhub_overview carries the
-- agent-scoped slice, because that is the tool an agent already runs first.
-- ---------------------------------------------------------------------------
create or replace view platform.v_asks as
select a.id, a.at::timestamp(0) as asked, a.asked_by, coalesce(a.for_agent, '(anyone)') as for_agent,
       a.status, a.answered_at::timestamp(0) as answered,
       (select count(*) from platform.ask_answers x where x.ask_id = a.id) as answers,
       left(a.question, 160) as question,
       (select left(x.answer, 160) from platform.ask_answers x where x.ask_id = a.id order by x.at limit 1) as first_answer
from platform.asks a
order by (a.status = 'open') desc, a.at desc;
comment on view platform.v_asks is 'The noticeboard: who asked what, who answered, what is still open.';

-- What an agent should see about the board, scoped to it. Read by skillhub_overview.
create or replace function public.asks_for(agent text) returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select jsonb_build_object(
    -- Addressed to you and still open. These are the ones to look at.
    'asked_of_you', (select coalesce(jsonb_agg(jsonb_build_object('ask_id', a.id, 'from', a.asked_by,
                        'asked', a.at::timestamp(0), 'question', a.question) order by a.at), '[]'::jsonb)
                     from platform.asks a where a.status = 'open' and a.for_agent = asks_for.agent),
    -- Open to anyone. Five, oldest first: a longer list is a way to manufacture bad answers.
    'open_to_anyone', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                        select jsonb_build_object('ask_id', a.id, 'from', a.asked_by,
                          'asked', a.at::timestamp(0), 'question', a.question) as x
                        from platform.asks a
                        where a.status = 'open' and a.for_agent is null and a.asked_by <> asks_for.agent
                        order by a.at limit 5) y),
    -- Yours, and what came back. Thirty days, answered or not.
    'your_questions', (select coalesce(jsonb_agg(jsonb_build_object('ask_id', a.id, 'question', left(a.question, 120),
                          'status', a.status,
                          'answers', (select coalesce(jsonb_agg(jsonb_build_object('from', x.agent, 'answer', x.answer) order by x.at), '[]'::jsonb)
                                      from platform.ask_answers x where x.ask_id = a.id)) order by a.at desc), '[]'::jsonb)
                       from platform.asks a
                       where a.asked_by = asks_for.agent
                         and (a.status = 'open' or a.answered_at > now() - interval '30 days')));
$$;
comment on function public.asks_for(text) is 'The noticeboard as one agent sees it: addressed to them, open to anyone, and their own questions with the answers. Inside skillhub_overview, not a tool of its own.';

grant select on all tables in schema platform to anon, authenticated, service_role;
grant execute on all functions in schema platform to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Into the conventions skill, or no agent knows the board exists. Its own section, replaced
-- in place like every other, so a boot over an up-to-date store writes nothing.
-- ---------------------------------------------------------------------------
select platform.put_conventions_section(40, 'asking each other',
  E'\n## Asking each other\n\n'
  || E'When the store does not hold something you need, leave the question on the board:\n'
  || E'  skillhub_ask(''what you need, and what you already looked at'', for_agent optional)\n'
  || E'It searches first and shows what it found. NOBODY IS NOTIFIED. A colleague''s agent\n'
  || E'sees your question the next time somebody talks to it -- minutes, or tomorrow. If it\n'
  || E'is urgent, ask the person in front of you.\n\n'
  || E'You see questions left for you, and answers to yours, in skillhub_overview.\n'
  || E'Answer one with skillhub_answer(ask_id, answer). Then the rule that makes the board\n'
  || E'worth having: IF YOU ANSWERED FROM YOUR OWN KNOWLEDGE RATHER THAN FROM THE STORE,\n'
  || E'WRITE IT DOWN -- a note, or a skill if it is a procedure others should follow. The\n'
  || E'board is not searched by meaning and never will be: a question is not knowledge, and\n'
  || E'an answer that lives only there is one the next person has to ask for again.\n');

