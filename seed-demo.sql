-- Seeds a "Goa Trip 2026" demo group for the fixed demo account (service_role only — bypasses RLS).
do $$
declare
  v_group_id uuid;
  v_demo_id uuid := 'd4d40ce6-439e-4340-bc92-600a5c0891bb';
  v_rahul_id uuid;
  v_simran_id uuid;
  v_exp1 uuid;
  v_exp2 uuid;
  v_exp3 uuid;
begin
  insert into ms_groups (name, invite_code, created_by)
  values ('Goa Trip 2026', 'GOADEMO1', v_demo_id)
  returning id into v_group_id;

  insert into ms_group_members (group_id, user_id, display_name) values (v_group_id, v_demo_id, 'Demo User');
  insert into ms_group_members (group_id, invited_email, display_name) values (v_group_id, 'demo-rahul@merashare.in', 'Rahul') returning id into v_rahul_id;
  insert into ms_group_members (group_id, invited_email, display_name) values (v_group_id, 'demo-simran@merashare.in', 'Simran') returning id into v_simran_id;

  insert into ms_expenses (group_id, description, amount, paid_by_member, created_by, category)
  values (v_group_id, 'Hotel booking (2 nights)', 9000, (select id from ms_group_members where group_id = v_group_id and display_name = 'Demo User'), v_demo_id, 'accommodation')
  returning id into v_exp1;
  insert into ms_expense_splits (expense_id, group_id, member_id, share_amount)
  select v_exp1, v_group_id, id, 3000 from ms_group_members where group_id = v_group_id;

  insert into ms_expenses (group_id, description, amount, paid_by_member, created_by, category)
  values (v_group_id, 'Dinner at beach shack', 2400, v_rahul_id, v_demo_id, 'food')
  returning id into v_exp2;
  insert into ms_expense_splits (expense_id, group_id, member_id, share_amount)
  select v_exp2, v_group_id, id, 800 from ms_group_members where group_id = v_group_id;

  insert into ms_expenses (group_id, description, amount, paid_by_member, created_by, category)
  values (v_group_id, 'Cab from airport', 900, v_simran_id, v_demo_id, 'transport')
  returning id into v_exp3;
  insert into ms_expense_splits (expense_id, group_id, member_id, share_amount) values
    (v_exp3, v_group_id, (select id from ms_group_members where group_id = v_group_id and display_name = 'Demo User'), 360),
    (v_exp3, v_group_id, v_rahul_id, 540),
    (v_exp3, v_group_id, v_simran_id, 0);

  insert into ms_settlements (group_id, from_member, to_member, amount, note, created_by)
  values (v_group_id, v_rahul_id, (select id from ms_group_members where group_id = v_group_id and display_name = 'Demo User'), 1000, 'Partial payback via UPI', v_demo_id);
end $$;
