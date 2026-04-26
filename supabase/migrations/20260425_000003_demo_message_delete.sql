begin;

drop policy if exists demo_chat_messages_delete_public_live on public.demo_chat_messages;
create policy demo_chat_messages_delete_public_live
  on public.demo_chat_messages
  for delete
  to anon, authenticated
  using (
    is_seeded = false
  );

grant delete on public.demo_chat_messages to anon, authenticated;

commit;
