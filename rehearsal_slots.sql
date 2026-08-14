-- ============================================================
-- REHEARSAL SLOT BOOKING
--
-- >>> ALREADY APPLIED. DO NOT RE-RUN CASUALLY. <<<
--
-- This file DROPS all three functions before recreating them. Once the booking
-- link is out with groups, re-running it means any request in flight fails —
-- a group mid-booking gets an error. The seed block is safe (it skips when
-- slots exist) but the drops are not free.
--
-- If you need to change a function, edit that one function and run only that
-- statement, not the whole file.
--
-- 46 slots on 9-minute cycles: 7 minutes on stage, 2 minutes changeover.
--   Friday 21 Aug, 20:00 to 22:40  -> 18 slots
--   Saturday 22 Aug, 08:00 to 12:10 -> 28 slots
-- Against 45 live entries (32 Open Stage + 13 K-Classics), so one spare.
--
-- DESIGN DECISIONS, each for a reason:
--
-- ONE BOOKING PER ENTRY, not per group. A group in both categories rehearses
-- twice because it performs twice. registration_id is unique on the table, so
-- the database enforces it rather than the page.
--
-- NO PUBLIC GROUP LIST. The availability function returns slot times and a
-- status only — never who holds a slot. Otherwise anyone could enumerate the
-- roster, and a group could see which rival booked what.
--
-- IDENTITY REQUIRES BOTH the group name and the registration code, matched
-- against the SAME registration. A code alone would let anyone who glimpsed
-- one book on that group's behalf; a name alone is public knowledge.
--
-- FIVE-MINUTE HOLD. Two groups can open the page at once, so a slot is held
-- while the second step completes. Expired holds are reclaimed lazily on
-- every read rather than by a scheduled job, so there is nothing to keep
-- running on the night.
--
-- SECURITY DEFINER on all three functions: the page is unauthenticated, so
-- anon must reach them without any policy granting it sight of the
-- registrations table. search_path is pinned.
-- ============================================================

create table if not exists public.rehearsal_slots (
  id              uuid primary key default gen_random_uuid(),
  slot_date       date not null,
  start_time      time not null,
  end_time        time not null,
  label           text not null,
  display_order   int  not null,

  -- Booking state. registration_id unique => one slot per entry, enforced here.
  registration_id uuid unique references public.registrations(id) on delete set null,
  booked_at       timestamptz,
  booked_group    text,

  -- Hold state, cleared when it expires or converts.
  held_until      timestamptz,
  held_for        uuid references public.registrations(id) on delete set null,

  created_at      timestamptz not null default now(),

  constraint rehearsal_slot_unique_time unique (slot_date, start_time),
  -- A slot cannot be booked and held at the same time.
  constraint rehearsal_slot_not_both check (
    not (registration_id is not null and held_until is not null)
  )
);

create index if not exists rehearsal_slots_order_idx
  on public.rehearsal_slots (display_order);

alter table public.rehearsal_slots enable row level security;

-- No direct table access for anon. Everything goes through the functions, so
-- reading this table returns nothing to an unauthenticated caller.
--
-- BUT DO NOT READ THAT AS A GUARANTEE ABOUT THE ROSTER. An earlier version of
-- this comment claimed the group list "can never be read", which is true of
-- rehearsal_slots and FALSE of the system: policy
-- registrations_anon_scan_select is SELECT to PUBLIC with USING (true), almost
-- certainly for scan.html's door lookup, so anon can read all 45 entries
-- including registration_code and group_name from the registrations table
-- directly.
--
-- Which means the identity check below — both the name AND the code — raises the
-- bar but is not a secret. Anyone who takes the publishable key from this page's
-- own source can enumerate the roster and book on any group's behalf.
--
-- ACCEPTED KNOWINGLY, because the damage is bounded and cheap to reverse: one
-- slot per entry is enforced by a unique constraint, any booking is visible in
-- admin, and clearing one is a single UPDATE (tested end to end). Closing it
-- properly means either a per-group PIN with SELECT revoked from anon, or moving
-- the door lookup behind auth — neither of which is a sensible change days
-- before the event.
--
-- Revisit after 22 August.
--
-- Note also that reading this table as anon returns 200 with ZERO ROWS rather
-- than 401: the grant exists and RLS is the only barrier. If a permissive policy
-- were ever added here, or RLS disabled, it would start returning rows
-- immediately.
drop policy if exists rehearsal_slots_admin_all on public.rehearsal_slots;
create policy rehearsal_slots_admin_all on public.rehearsal_slots
  for all to authenticated
  using (public.is_active_admin())
  with check (public.is_active_admin());


-- ---------- SEED THE 46 SLOTS ----------
do $seed$
declare
  v_t     time;
  v_n     int := 0;
  v_order int := 0;
begin
  if exists (select 1 from public.rehearsal_slots) then
    raise notice 'Slots already seeded (% rows). Skipping.',
      (select count(*) from public.rehearsal_slots);
    return;
  end if;

  -- Friday 21 August, 20:00 onward. Last start is 22:33 so the 7 minutes on
  -- stage finish by 22:40.
  v_t := time '20:00';
  while v_t <= time '22:33' loop
    v_order := v_order + 1;
    insert into public.rehearsal_slots
      (slot_date, start_time, end_time, label, display_order)
    values (date '2026-08-21', v_t, v_t + interval '7 minutes',
            'Fri 21 Aug ' || to_char(v_t, 'FMHH12:MI AM'), v_order);
    v_t := v_t + interval '9 minutes';
    v_n := v_n + 1;
  end loop;

  -- Saturday 22 August, 08:00 onward. Last start 12:03, finishing by 12:10.
  v_t := time '08:00';
  while v_t <= time '12:03' loop
    v_order := v_order + 1;
    insert into public.rehearsal_slots
      (slot_date, start_time, end_time, label, display_order)
    values (date '2026-08-22', v_t, v_t + interval '7 minutes',
            'Sat 22 Aug ' || to_char(v_t, 'FMHH12:MI AM'), v_order);
    v_t := v_t + interval '9 minutes';
    v_n := v_n + 1;
  end loop;

  raise notice 'Seeded % slot(s).', v_n;
end
$seed$;


-- ---------- 1. AVAILABILITY ----------
-- Returns times and status only. Never a group name, so the roster cannot be
-- enumerated from the booking page.
drop function if exists public.rehearsal_availability();

create function public.rehearsal_availability()
returns table (
  slot_id       uuid,
  slot_date     date,
  start_time    time,
  end_time      time,
  label         text,
  display_order int,
  state         text        -- 'open' | 'held' | 'booked'
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select s.id, s.slot_date, s.start_time, s.end_time, s.label, s.display_order,
         case
           when s.registration_id is not null then 'booked'
           -- A hold that has expired reads as open. Reclaimed lazily on write
           -- rather than by a scheduled job.
           when s.held_until is not null and s.held_until > now() then 'held'
           else 'open'
         end as state
  from public.rehearsal_slots s
  order by s.display_order;
$function$;

grant execute on function public.rehearsal_availability() to anon, authenticated;


-- ---------- 2. PLACE A HOLD ----------
drop function if exists public.hold_rehearsal_slot(text, text, uuid);

create function public.hold_rehearsal_slot(
  p_registration_code text,
  p_group_name        text,
  p_slot_id           uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_reg      record;
  v_slot     record;
  v_existing record;
begin
  -- Reclaim expired holds first, so a slot abandoned mid-booking becomes
  -- available to the next group without anything scheduled.
  update public.rehearsal_slots
     set held_until = null, held_for = null
   where held_until is not null and held_until <= now();

  -- BOTH the code and the group name must match the SAME live registration.
  select r.id, r.group_name, r.category, r.status
    into v_reg
  from public.registrations r
  where upper(trim(r.registration_code)) = upper(trim(p_registration_code))
    and lower(regexp_replace(trim(r.group_name), '\s+', ' ', 'g'))
      = lower(regexp_replace(trim(p_group_name), '\s+', ' ', 'g'))
    and r.status in ('pending', 'confirmed', 'paid');

  if v_reg.id is null then
    -- Deliberately vague. Saying which half was wrong would let someone probe
    -- for valid codes, or confirm a group name against a guessed code.
    return jsonb_build_object(
      'ok', false,
      'error', 'We could not match that group name and registration ID. Check both and try again, or message us.');
  end if;

  -- Already booked? Return it rather than erroring, so a group that reloads
  -- sees their slot instead of a failure.
  select s.id, s.label into v_existing
  from public.rehearsal_slots s
  where s.registration_id = v_reg.id;

  if v_existing.id is not null then
    return jsonb_build_object(
      'ok', false,
      'already_booked', true,
      'slot_id', v_existing.id,
      'slot_label', v_existing.label,
      'group_name', v_reg.group_name,
      'category', v_reg.category,
      'error', v_reg.group_name || ' (' || v_reg.category
               || ') already has ' || v_existing.label
               || '. Message us if you need to change it.');
  end if;

  select * into v_slot from public.rehearsal_slots where id = p_slot_id;
  if v_slot.id is null then
    return jsonb_build_object('ok', false, 'error', 'That slot no longer exists.');
  end if;
  if v_slot.registration_id is not null then
    return jsonb_build_object('ok', false, 'taken', true,
      'error', 'That slot was just booked by another group. Please pick another.');
  end if;
  if v_slot.held_until is not null and v_slot.held_until > now()
     and v_slot.held_for is distinct from v_reg.id then
    return jsonb_build_object('ok', false, 'taken', true,
      'error', 'Another group is booking that slot right now. Please pick another.');
  end if;

  update public.rehearsal_slots
     set held_until = now() + interval '5 minutes',
         held_for = v_reg.id
   where id = p_slot_id
     and registration_id is null
     and (held_until is null or held_until <= now() or held_for = v_reg.id);

  if not found then
    return jsonb_build_object('ok', false, 'taken', true,
      'error', 'That slot was taken a moment ago. Please pick another.');
  end if;

  return jsonb_build_object(
    'ok', true,
    'slot_id', p_slot_id,
    'slot_label', v_slot.label,
    'group_name', v_reg.group_name,
    'category', v_reg.category,
    'registration_id', v_reg.id,
    'held_until', now() + interval '5 minutes');
end
$function$;

grant execute on function public.hold_rehearsal_slot(text, text, uuid) to anon, authenticated;


-- ---------- 3. CONFIRM ----------
drop function if exists public.confirm_rehearsal_slot(text, text, uuid);

create function public.confirm_rehearsal_slot(
  p_registration_code text,
  p_group_name        text,
  p_slot_id           uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_reg  record;
  v_slot record;
begin
  -- Identity is re-checked here, not trusted from the hold step. Otherwise a
  -- crafted request could confirm a slot held by someone else.
  select r.id, r.group_name, r.category
    into v_reg
  from public.registrations r
  where upper(trim(r.registration_code)) = upper(trim(p_registration_code))
    and lower(regexp_replace(trim(r.group_name), '\s+', ' ', 'g'))
      = lower(regexp_replace(trim(p_group_name), '\s+', ' ', 'g'))
    and r.status in ('pending', 'confirmed', 'paid');

  if v_reg.id is null then
    return jsonb_build_object('ok', false,
      'error', 'We could not match that group name and registration ID.');
  end if;

  if exists (select 1 from public.rehearsal_slots where registration_id = v_reg.id) then
    return jsonb_build_object('ok', false,
      'error', 'That entry already has a slot booked.');
  end if;

  update public.rehearsal_slots
     set registration_id = v_reg.id,
         booked_group = v_reg.group_name || ' (' || v_reg.category || ')',
         booked_at = now(),
         held_until = null,
         held_for = null
   where id = p_slot_id
     and registration_id is null
     and (held_for = v_reg.id or held_until is null or held_until <= now())
  returning * into v_slot;

  if v_slot.id is null then
    return jsonb_build_object('ok', false, 'taken', true,
      'error', 'That slot is no longer available. Your hold may have expired — please pick again.');
  end if;

  return jsonb_build_object(
    'ok', true,
    'slot_label', v_slot.label,
    'slot_date', v_slot.slot_date,
    'start_time', v_slot.start_time,
    'group_name', v_reg.group_name,
    'category', v_reg.category);
end
$function$;

grant execute on function public.confirm_rehearsal_slot(text, text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';


-- ---------- VERIFY ----------
select count(*) as total_slots,
       count(*) filter (where slot_date = '2026-08-21') as friday,
       count(*) filter (where slot_date = '2026-08-22') as saturday
from public.rehearsal_slots;
-- Expect 46 / 18 / 28.

select label, start_time, end_time, display_order
from public.rehearsal_slots
order by display_order
limit 5;

select label from public.rehearsal_slots
order by display_order desc limit 1;
-- Last slot should be Sat 22 Aug 12:03 PM.

-- Slots against live entries.
select (select count(*) from public.rehearsal_slots) as slots,
       (select count(*) from public.registrations
         where status in ('pending','confirmed','paid')) as live_entries;
-- 46 slots against the live entry count. Entries exceeding slots would mean
-- some group gets nothing.
