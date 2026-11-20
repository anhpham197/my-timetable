-- One-owner timetable schema for the public GitHub Pages frontend.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table if not exists private.timetable_settings (
  singleton boolean primary key default true check (singleton),
  owner_id uuid not null references auth.users(id) on delete cascade
);

create or replace function private.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.timetable_settings as settings
    where settings.singleton
      and settings.owner_id = (select auth.uid())
  );
$$;

revoke all on function private.is_owner() from public, anon, authenticated;
grant execute on function private.is_owner() to authenticated;

create table if not exists public.timetable_slots (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('event', 'availability')),
  title text not null check (char_length(title) between 1 and 60),
  slot_date date not null,
  start_time time not null,
  end_time time not null,
  visibility text not null default 'public' check (visibility in ('public', 'private')),
  constraint timetable_slots_positive_duration check (end_time > start_time),
  constraint availability_is_public check (kind <> 'availability' or visibility = 'public')
);

create table if not exists public.booking_requests (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null,
  availability_title text not null default 'Open for booking',
  name text not null check (char_length(name) between 1 and 60),
  email text not null check (char_length(email) between 3 and 120),
  note text not null default '' check (char_length(note) <= 400),
  slot_date date not null,
  start_time time not null,
  end_time time not null,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  constraint booking_requests_positive_duration check (end_time > start_time)
);

create unique index if not exists booking_requests_one_active_per_slot
  on public.booking_requests (slot_id)
  where status in ('pending', 'accepted');

alter table public.timetable_slots enable row level security;
alter table public.booking_requests enable row level security;

revoke all on table public.timetable_slots from public, anon, authenticated;
grant select, insert, update, delete on table public.timetable_slots to authenticated;
revoke all on table public.booking_requests from public, anon, authenticated;
grant select, update, delete on table public.booking_requests to authenticated;

drop policy if exists "Owner manages timetable slots" on public.timetable_slots;
create policy "Owner manages timetable slots"
  on public.timetable_slots for all to authenticated
  using ((select private.is_owner()))
  with check ((select private.is_owner()));

drop policy if exists "Owner reads booking requests" on public.booking_requests;
create policy "Owner reads booking requests"
  on public.booking_requests for select to authenticated
  using ((select private.is_owner()));

drop policy if exists "Owner updates booking requests" on public.booking_requests;
create policy "Owner updates booking requests"
  on public.booking_requests for update to authenticated
  using ((select private.is_owner()))
  with check ((select private.is_owner()));

drop policy if exists "Owner deletes booking requests" on public.booking_requests;
create policy "Owner deletes booking requests"
  on public.booking_requests for delete to authenticated
  using ((select private.is_owner()));

create or replace function public.is_timetable_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_owner();
$$;

revoke all on function public.is_timetable_owner() from public, anon;
grant execute on function public.is_timetable_owner() to authenticated;

create or replace function public.get_public_schedule(p_from date, p_to date)
returns table (
  id uuid,
  slot_date date,
  start_time time,
  end_time time,
  title text,
  kind text,
  visibility text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    slots.id,
    slots.slot_date,
    slots.start_time,
    slots.end_time,
    case
      when slots.kind = 'availability' and requests.status = 'accepted' then 'Booked'
      when slots.kind = 'availability' and requests.status = 'pending' then 'Unavailable'
      when slots.kind = 'availability' then 'Available to book'
      when slots.visibility = 'private' then 'Unavailable'
      else slots.title
    end as title,
    case
      when slots.kind = 'availability' and requests.status = 'accepted' then 'booking'
      when slots.kind = 'availability' and requests.status = 'pending' then 'pending'
      else slots.kind
    end as kind,
    slots.visibility
  from public.timetable_slots as slots
  left join public.booking_requests as requests
    on requests.slot_id = slots.id
    and requests.status in ('pending', 'accepted')
  where slots.slot_date between p_from and p_to
  order by slots.slot_date, slots.start_time;
$$;

revoke all on function public.get_public_schedule(date, date) from public;
grant execute on function public.get_public_schedule(date, date) to anon, authenticated;

create or replace function public.request_booking(
  p_slot_id uuid,
  p_name text,
  p_email text,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_slot public.timetable_slots%rowtype;
  request_id uuid;
begin
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 60 then
    raise exception 'Enter a name between 1 and 60 characters.';
  end if;
  if char_length(btrim(coalesce(p_email, ''))) not between 3 and 120
     or btrim(p_email) !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Enter a valid email address.';
  end if;
  if char_length(coalesce(p_note, '')) > 400 then
    raise exception 'The note must be 400 characters or fewer.';
  end if;

  select * into requested_slot
  from public.timetable_slots
  where id = p_slot_id and kind = 'availability'
    and (slot_date + start_time) > (now() at time zone 'Asia/Ho_Chi_Minh')
  for update;

  if not found then
    raise exception 'This time is no longer available.';
  end if;

  insert into public.booking_requests (
    slot_id, availability_title, name, email, note,
    slot_date, start_time, end_time, status
  ) values (
    requested_slot.id, requested_slot.title, btrim(p_name), btrim(p_email), coalesce(btrim(p_note), ''),
    requested_slot.slot_date, requested_slot.start_time, requested_slot.end_time, 'pending'
  ) returning id into request_id;

  return request_id;
end;
$$;

revoke all on function public.request_booking(uuid, text, text, text) from public;
grant execute on function public.request_booking(uuid, text, text, text) to anon, authenticated;
