-- Invite UX (onboarding and friending plan, 2026-11-07). Additive only.
--
--   preview_invite_public  lets a signed-OUT person who opened an invite see who invited them ("Dan invited you")
--                          before creating an account. Returns only the inviter's display name and whether the code
--                          can still be used. Holding the code is the only way to call it usefully (32 random hex chars).
--   cancel policy          an inviter can delete their own invite while it is still unused ("Invites waiting" → Cancel).

create or replace function public.preview_invite_public(p_code text)
returns table (inviter_name text, usable boolean)
language sql security definer set search_path = public stable as $$
  select p.display_name, (i.accepted_at is null and i.expires_at > now())
  from invites i join profiles p on p.id = i.inviter_id
  where i.code = p_code;
$$;

revoke all on function public.preview_invite_public(text) from public;
grant execute on function public.preview_invite_public(text) to anon, authenticated;

create policy "Inviters can cancel their unused invites"
  on public.invites for delete
  using (auth.uid() = inviter_id and accepted_at is null);
