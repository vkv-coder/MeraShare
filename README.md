# MeraShare

Split shared expenses with friends, family or roommates — equal, exact, or percentage splits, running balances, and settle-up tracking. Live at [merashare.in](https://merashare.in).

## Stack
- Static PWA (vanilla HTML/CSS/JS), no build step.
- Supabase Auth (email + password) for identity.
- Postgres on the shared `rotry_event` project, `ms_` table prefix, RLS everywhere, all writes via `SECURITY DEFINER` RPCs (`ms_create_group`, `ms_join_group`, `ms_add_member`, `ms_add_expense`, `ms_record_settlement`, `ms_group_balances`, `ms_my_groups_summary`, `ms_claim_pending_memberships`, `ms_delete_expense`).
- `schema.sql` is the full schema/RLS/RPC definition (idempotent `create or replace` / `if not exists`), applied via `supabase db query --linked --project-ref wrzpgultvahxbrgooibn --file schema.sql`.

## Auth email tagging
`rotry_event` is shared with other apps (trust-analysis, tiecon-match). Every auth call tags the email with `+merashare` (see `js/supabase-client.js`) so `auth.users` rows never collide across apps on the same project.

## Pending invites
Adding a member by email before they have an account creates a placeholder `ms_group_members` row (`invited_email` set, `user_id` null). `ms_claim_pending_memberships()` runs after every login and claims any placeholder rows matching the signed-in user's (untagged) email.

## Demo
"Try Demo" gates on name+phone (logged to `ms_demo_visitors`, Telegram-alerted via the shared `send-telegram` Edge Function on the `dhobi_digital` project), then signs into a fixed shared demo account with a pre-seeded "Goa Trip 2026" group.
