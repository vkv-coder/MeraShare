-- Seeds a "Goa Trip 2026" demo group for the fixed demo account (service_role only — bypasses RLS).
-- Deliberately members-only, zero expenses — the orientation flow (how-it-works.html) has
-- the visitor add every expense themselves, so balances only ever reflect what they just did.
do $$
declare
  v_group_id uuid;
  v_demo_id uuid := 'd4d40ce6-439e-4340-bc92-600a5c0891bb';
begin
  insert into ms_groups (name, invite_code, created_by)
  values ('Goa Trip 2026', 'GOADEMO1', v_demo_id)
  returning id into v_group_id;

  insert into ms_group_members (group_id, user_id, display_name) values (v_group_id, v_demo_id, 'Demo User');
  insert into ms_group_members (group_id, invited_email, display_name) values (v_group_id, 'demo-rahul@merashare.in', 'Rahul');
  insert into ms_group_members (group_id, invited_email, display_name) values (v_group_id, 'demo-simran@merashare.in', 'Simran');
end $$;
