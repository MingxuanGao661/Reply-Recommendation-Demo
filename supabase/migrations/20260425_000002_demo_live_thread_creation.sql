begin;

drop policy if exists demo_chat_threads_insert_public_live on public.demo_chat_threads;
create policy demo_chat_threads_insert_public_live
  on public.demo_chat_threads
  for insert
  to anon, authenticated
  with check (
    scenario_key like 'live-%'
    and char_length(btrim(title)) > 0
    and char_length(title) <= 120
    and char_length(subtitle) <= 160
    and char_length(btrim(default_composer_participant_id)) > 0
    and (initial_draft is null or char_length(initial_draft) <= 4000)
  );

drop policy if exists demo_chat_participants_insert_public_live on public.demo_chat_thread_participants;
create policy demo_chat_participants_insert_public_live
  on public.demo_chat_thread_participants
  for insert
  to anon, authenticated
  with check (
    char_length(btrim(participant_id)) > 0
    and char_length(participant_id) <= 64
    and char_length(btrim(display_name)) > 0
    and char_length(display_name) <= 120
    and (relationship is null or char_length(relationship) <= 120)
    and exists (
      select 1
      from public.demo_chat_threads t
      where t.id = demo_chat_thread_participants.thread_id
        and t.scenario_key like 'live-%'
    )
  );

grant insert on public.demo_chat_threads to anon, authenticated;
grant insert on public.demo_chat_thread_participants to anon, authenticated;

commit;
