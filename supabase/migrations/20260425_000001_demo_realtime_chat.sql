begin;

create extension if not exists pgcrypto;

create table if not exists public.demo_chat_threads (
  id uuid primary key default gen_random_uuid(),
  scenario_key text not null unique,
  display_order integer not null,
  title text not null,
  subtitle text not null,
  default_composer_participant_id text not null default 'me',
  reply_to_participant_id text,
  initial_draft text,
  profile_tone text,
  profile_length text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.demo_chat_thread_participants (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.demo_chat_threads(id) on delete cascade,
  participant_id text not null,
  display_name text not null,
  relationship text,
  is_self boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (thread_id, participant_id)
);

create table if not exists public.demo_chat_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.demo_chat_threads(id) on delete cascade,
  speaker_id text not null,
  speaker_name text not null,
  content text not null check (char_length(btrim(content)) > 0 and char_length(content) <= 4000),
  sender_device_id text,
  client_message_id uuid,
  is_seeded boolean not null default false,
  seed_message_order integer,
  created_at timestamptz not null default now(),
  unique (thread_id, seed_message_order),
  unique (client_message_id)
);

create index if not exists demo_chat_threads_display_order_idx
  on public.demo_chat_threads(display_order);

create index if not exists demo_chat_participants_thread_order_idx
  on public.demo_chat_thread_participants(thread_id, sort_order);

create index if not exists demo_chat_messages_thread_created_idx
  on public.demo_chat_messages(thread_id, created_at);

alter table public.demo_chat_threads enable row level security;
alter table public.demo_chat_thread_participants enable row level security;
alter table public.demo_chat_messages enable row level security;

drop policy if exists demo_chat_threads_select_public on public.demo_chat_threads;
create policy demo_chat_threads_select_public
  on public.demo_chat_threads
  for select
  to anon, authenticated
  using (true);

drop policy if exists demo_chat_participants_select_public on public.demo_chat_thread_participants;
create policy demo_chat_participants_select_public
  on public.demo_chat_thread_participants
  for select
  to anon, authenticated
  using (true);

drop policy if exists demo_chat_messages_select_public on public.demo_chat_messages;
create policy demo_chat_messages_select_public
  on public.demo_chat_messages
  for select
  to anon, authenticated
  using (true);

drop policy if exists demo_chat_messages_insert_public on public.demo_chat_messages;
create policy demo_chat_messages_insert_public
  on public.demo_chat_messages
  for insert
  to anon, authenticated
  with check (
    is_seeded = false
    and seed_message_order is null
    and sender_device_id is not null
    and char_length(btrim(sender_device_id)) > 0
    and exists (
      select 1
      from public.demo_chat_thread_participants p
      where p.thread_id = demo_chat_messages.thread_id
        and p.participant_id = demo_chat_messages.speaker_id
    )
  );

grant usage on schema public to anon, authenticated;
grant select on public.demo_chat_threads to anon, authenticated;
grant select on public.demo_chat_thread_participants to anon, authenticated;
grant select, insert on public.demo_chat_messages to anon, authenticated;

insert into public.demo_chat_threads (
  scenario_key,
  display_order,
  title,
  subtitle,
  default_composer_participant_id,
  reply_to_participant_id,
  initial_draft,
  profile_tone,
  profile_length
)
values
  ('weekendPlans', 0, 'Alice', 'Coffee catch-up', 'me', 'alice', null, 'friendly', 'short'),
  ('hackathonTeam', 1, 'Demo Squad', 'Hackathon group', 'me', 'maya', null, 'neutral', 'medium'),
  ('socialReplyDinner', 2, 'Dinner Plan', 'Imported social sample', 'me', 'other', 'maybe 20 mins late traffic bad', 'warm', 'short'),
  ('socialReplyLunch', 3, 'Lunch Tomorrow', 'Imported social sample', 'me', 'other', 'kind of tired dont really want go', 'polite', 'short'),
  ('socialReplySupport', 4, 'Checking In', 'Imported social sample', 'me', 'other', 'its okay not all your fault', 'gentle', 'medium'),
  ('socialReplySlides', 5, 'Work Follow-up', 'Imported social sample', 'me', 'other', 'yes i can send before 9', 'professional', 'short'),
  ('socialReplyInternship', 6, 'Big News', 'Imported social sample', 'me', 'other', 'thats amazing proud of you', 'enthusiastic', 'short'),
  ('roadTrip', 7, 'Ryan', 'Road trip planning', 'me', 'ryan', null, 'friendly', 'medium'),
  ('movieNight', 8, 'Sarah', 'Movie night invite', 'me', 'sarah', 'probably yeah give me like 20 mins', 'warm', 'short'),
  ('groupHike', 9, 'Hiking Crew', 'Weekend hike group', 'me', 'mia', null, 'friendly', 'short'),
  ('projectDeadline', 10, 'CS 189 Project', 'Final project group', 'me', 'priya', 'i can do the intro and lit review', 'neutral', 'short')
on conflict (scenario_key) do update set
  display_order = excluded.display_order,
  title = excluded.title,
  subtitle = excluded.subtitle,
  default_composer_participant_id = excluded.default_composer_participant_id,
  reply_to_participant_id = excluded.reply_to_participant_id,
  initial_draft = excluded.initial_draft,
  profile_tone = excluded.profile_tone,
  profile_length = excluded.profile_length,
  updated_at = now();

with rows(scenario_key, participant_id, display_name, relationship, is_self, sort_order) as (
  values
    ('weekendPlans', 'alice', 'Alice', 'friend', false, 0),
    ('weekendPlans', 'me', 'Me', 'self', true, 1),
    ('hackathonTeam', 'maya', 'Maya', 'teammate', false, 0),
    ('hackathonTeam', 'leo', 'Leo', 'teammate', false, 1),
    ('hackathonTeam', 'me', 'Me', 'self', true, 2),
    ('socialReplyDinner', 'other', 'Other', 'friend', false, 0),
    ('socialReplyDinner', 'me', 'Me', 'self', true, 1),
    ('socialReplyLunch', 'other', 'Other', 'friend', false, 0),
    ('socialReplyLunch', 'me', 'Me', 'self', true, 1),
    ('socialReplySupport', 'other', 'Other', 'friend', false, 0),
    ('socialReplySupport', 'me', 'Me', 'self', true, 1),
    ('socialReplySlides', 'other', 'Other', 'coworker', false, 0),
    ('socialReplySlides', 'me', 'Me', 'self', true, 1),
    ('socialReplyInternship', 'other', 'Other', 'friend', false, 0),
    ('socialReplyInternship', 'me', 'Me', 'self', true, 1),
    ('roadTrip', 'ryan', 'Ryan', 'friend', false, 0),
    ('roadTrip', 'me', 'Me', 'self', true, 1),
    ('movieNight', 'sarah', 'Sarah', 'friend', false, 0),
    ('movieNight', 'me', 'Me', 'self', true, 1),
    ('groupHike', 'mia', 'Mia', 'friend', false, 0),
    ('groupHike', 'jake', 'Jake', 'friend', false, 1),
    ('groupHike', 'me', 'Me', 'self', true, 2),
    ('projectDeadline', 'priya', 'Priya', 'teammate', false, 0),
    ('projectDeadline', 'daniel', 'Daniel', 'teammate', false, 1),
    ('projectDeadline', 'me', 'Me', 'self', true, 2)
)
insert into public.demo_chat_thread_participants (
  thread_id,
  participant_id,
  display_name,
  relationship,
  is_self,
  sort_order
)
select t.id, r.participant_id, r.display_name, r.relationship, r.is_self, r.sort_order
from rows r
join public.demo_chat_threads t on t.scenario_key = r.scenario_key
on conflict (thread_id, participant_id) do update set
  display_name = excluded.display_name,
  relationship = excluded.relationship,
  is_self = excluded.is_self,
  sort_order = excluded.sort_order;

with rows(scenario_key, seed_message_order, speaker_id, speaker_name, content) as (
  values
    ('weekendPlans', 0, 'alice', 'Alice', $$hey! still down to grab coffee this weekend?$$),
    ('weekendPlans', 1, 'me', 'Me', $$yeah definitely, saturday is probably easiest$$),
    ('weekendPlans', 2, 'alice', 'Alice', $$perfect, want to do verve around 11 or somewhere closer to you?$$),
    ('hackathonTeam', 0, 'leo', 'Leo', $$i pushed the Swift backend conversion and the parser looks okay on my smoke tests$$),
    ('hackathonTeam', 1, 'maya', 'Maya', $$nice. can we get the frontend demo flow wired before standup so we can record a backup clip?$$),
    ('hackathonTeam', 2, 'me', 'Me', $$i'm on the chat UI now$$),
    ('hackathonTeam', 3, 'maya', 'Maya', $$awesome, if local llama is flaky let's keep a mock fallback so the demo doesn't stall$$),
    ('socialReplyDinner', 0, 'other', 'Other', $$hey are you still coming to dinner tonight?$$),
    ('socialReplyDinner', 1, 'me', 'Me', $$yeah i think so$$),
    ('socialReplyDinner', 2, 'other', 'Other', $$cool, what time should i expect you?$$),
    ('socialReplyLunch', 0, 'other', 'Other', $$want to grab lunch tomorrow?$$),
    ('socialReplyLunch', 1, 'me', 'Me', $$maybe, depends on work$$),
    ('socialReplyLunch', 2, 'other', 'Other', $$no worries, just let me know later tonight$$),
    ('socialReplySupport', 0, 'other', 'Other', $$i honestly think i messed everything up$$),
    ('socialReplySupport', 1, 'me', 'Me', $$what happened?$$),
    ('socialReplySupport', 2, 'other', 'Other', $$i said the wrong thing and now everyone is upset with me$$),
    ('socialReplySlides', 0, 'other', 'Other', $$could you send me the revised slides by tonight?$$),
    ('socialReplySlides', 1, 'me', 'Me', $$yes, i'm still working on them$$),
    ('socialReplySlides', 2, 'other', 'Other', $$thank you, that would really help$$),
    ('socialReplyInternship', 0, 'other', 'Other', $$i got the internship!$$),
    ('socialReplyInternship', 1, 'me', 'Me', $$no way$$),
    ('socialReplyInternship', 2, 'other', 'Other', $$yes!! i literally screamed when i saw the email$$),
    ('roadTrip', 0, 'ryan', 'Ryan', $$yo you still down for that road trip this weekend?$$),
    ('roadTrip', 1, 'me', 'Me', $$yeah 100%, been looking forward to it$$),
    ('roadTrip', 2, 'ryan', 'Ryan', $$nice. i was thinking big sur, you up for that?$$),
    ('roadTrip', 3, 'me', 'Me', $$big sur is perfect, when were you thinking to leave?$$),
    ('roadTrip', 4, 'ryan', 'Ryan', $$saturday morning? like 8 or 9 to beat traffic$$),
    ('roadTrip', 5, 'me', 'Me', $$9:30 is probably better, traffic usually clears by then$$),
    ('roadTrip', 6, 'ryan', 'Ryan', $$makes sense. you good to drive? my car's been acting up$$),
    ('roadTrip', 7, 'me', 'Me', $$yeah i can drive, i'll fill up the night before$$),
    ('roadTrip', 8, 'ryan', 'Ryan', $$legend. i'll handle snacks and the aux then$$),
    ('roadTrip', 9, 'me', 'Me', $$deal. want to book a campsite or just figure it out when we get there?$$),
    ('roadTrip', 10, 'ryan', 'Ryan', $$let's book, the good spots fill up fast. i'll look tonight$$),
    ('roadTrip', 11, 'ryan', 'Ryan', $$oh and should we bring the cooler or just grab stuff down there?$$),
    ('movieNight', 0, 'sarah', 'Sarah', $$hey are you free tonight?$$),
    ('movieNight', 1, 'me', 'Me', $$yeah pretty much, what's up?$$),
    ('movieNight', 2, 'sarah', 'Sarah', $$i'm doing a movie night, you should come$$),
    ('movieNight', 3, 'me', 'Me', $$what are you watching?$$),
    ('movieNight', 4, 'sarah', 'Sarah', $$hereditary lol, maya and ben are coming too$$),
    ('movieNight', 5, 'me', 'Me', $$ooh scary movie night nice. where?$$),
    ('movieNight', 6, 'sarah', 'Sarah', $$my place, i'm making popcorn and getting snacks$$),
    ('movieNight', 7, 'me', 'Me', $$that sounds fun, what time?$$),
    ('movieNight', 8, 'sarah', 'Sarah', $$8pm, come a bit earlier to hang before$$),
    ('movieNight', 9, 'me', 'Me', $$cool i'll try to make it, still finishing up some stuff$$),
    ('movieNight', 10, 'sarah', 'Sarah', $$you coming right? we're starting at 8 and i already made the popcorn$$),
    ('groupHike', 0, 'mia', 'Mia', $$ok who's down for a hike this weekend$$),
    ('groupHike', 1, 'jake', 'Jake', $$i'm in, what trail are we thinking$$),
    ('groupHike', 2, 'me', 'Me', $$same, i've been meaning to do one for a while$$),
    ('groupHike', 3, 'mia', 'Mia', $$i was thinking mt tam, the coastal trail is supposed to be incredible$$),
    ('groupHike', 4, 'jake', 'Jake', $$yes good call. how long is that trail?$$),
    ('groupHike', 5, 'me', 'Me', $$looked it up, the main loop is like 8 miles, not too bad$$),
    ('groupHike', 6, 'mia', 'Mia', $$perfect, not too intense. saturday or sunday?$$),
    ('groupHike', 7, 'jake', 'Jake', $$saturday is better for me, sunday i have stuff in the evening$$),
    ('groupHike', 8, 'me', 'Me', $$saturday works for me too$$),
    ('groupHike', 9, 'mia', 'Mia', $$sweet. should we start early before it gets hot, like 8am at the trailhead?$$),
    ('groupHike', 10, 'jake', 'Jake', $$8am is early but yeah let's do it lol$$),
    ('groupHike', 11, 'me', 'Me', $$agreed, i'll set like three alarms$$),
    ('groupHike', 12, 'mia', 'Mia', $$haha same. jake how long is the drive from your place?$$),
    ('projectDeadline', 0, 'priya', 'Priya', $$hey team, we need to divide up the project sections this week$$),
    ('projectDeadline', 1, 'daniel', 'Daniel', $$agreed, deadline is next friday right?$$),
    ('projectDeadline', 2, 'me', 'Me', $$yep friday 11:59pm, we should split it up now$$),
    ('projectDeadline', 3, 'priya', 'Priya', $$ok so sections are: data analysis, model writeup, intro/lit review, and conclusion$$),
    ('projectDeadline', 4, 'daniel', 'Daniel', $$i'll take model writeup and results, that's my strongest area$$),
    ('projectDeadline', 5, 'me', 'Me', $$nice, that's the biggest chunk too, appreciate it$$),
    ('projectDeadline', 6, 'priya', 'Priya', $$thank you daniel seriously. i'll take data analysis since i cleaned the dataset$$),
    ('projectDeadline', 7, 'daniel', 'Daniel', $$makes sense, you know where all the edge cases are$$),
    ('projectDeadline', 8, 'me', 'Me', $$solid, so intro/lit review and conclusion are left$$),
    ('projectDeadline', 9, 'daniel', 'Daniel', $$one of those should be pretty light if we outline it first$$),
    ('projectDeadline', 10, 'priya', 'Priya', $$true. conclusion can build off the results section so whoever does that has a head start$$),
    ('projectDeadline', 11, 'priya', 'Priya', $$who wants to take point on each of those two sections?$$)
)
insert into public.demo_chat_messages (
  thread_id,
  speaker_id,
  speaker_name,
  content,
  is_seeded,
  seed_message_order,
  created_at
)
select
  t.id,
  r.speaker_id,
  r.speaker_name,
  r.content,
  true,
  r.seed_message_order,
  '2026-04-25 00:00:00+00'::timestamptz
    + (t.display_order * interval '2 hours')
    + (r.seed_message_order * interval '3 minutes')
from rows r
join public.demo_chat_threads t on t.scenario_key = r.scenario_key
on conflict (thread_id, seed_message_order) do update set
  speaker_id = excluded.speaker_id,
  speaker_name = excluded.speaker_name,
  content = excluded.content,
  is_seeded = true,
  created_at = excluded.created_at;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'demo_chat_messages'
  ) then
    execute 'alter publication supabase_realtime add table public.demo_chat_messages';
  end if;
end $$;

commit;
