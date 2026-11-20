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
  slot_id uuid,
  availability_title text not null default 'Open for booking',
  name text not null check (char_length(name) between 1 and 60),
  phone text,
  email text,
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

-- A null slot_id represents a guest-requested time that was not pre-opened.
alter table public.booking_requests alter column slot_id drop not null;
alter table public.booking_requests add column if not exists phone text;
alter table public.booking_requests alter column email drop not null;
alter table public.booking_requests drop constraint if exists booking_requests_email_check;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.booking_requests'::regclass and conname = 'booking_requests_email_valid') then
    alter table public.booking_requests add constraint booking_requests_email_valid
      check (email is null or (char_length(email) between 3 and 120 and email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.booking_requests'::regclass and conname = 'booking_requests_phone_valid') then
    alter table public.booking_requests add constraint booking_requests_phone_valid
      check (phone is null or (char_length(btrim(phone)) between 7 and 32 and btrim(phone) ~ '^[+]?[0-9][0-9[:space:]().-]{6,30}$'));
  end if;
end;
$$;

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
  select schedule.id, schedule.slot_date, schedule.start_time, schedule.end_time,
         schedule.title, schedule.kind, schedule.visibility
  from (
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

    union all

    select
      requests.id,
      requests.slot_date,
      requests.start_time,
      requests.end_time,
      case when requests.status = 'accepted' then 'Booked' else 'Unavailable' end,
      case when requests.status = 'accepted' then 'booking' else 'pending' end,
      'private'::text
    from public.booking_requests as requests
    where requests.slot_id is null
      and requests.status in ('pending', 'accepted')
      and requests.slot_date between p_from and p_to
  ) as schedule
  order by schedule.slot_date, schedule.start_time;
$$;

revoke all on function public.get_public_schedule(date, date) from public;
grant execute on function public.get_public_schedule(date, date) to anon, authenticated;

do $$
begin
  if to_regprocedure('public.request_booking(uuid,text,text,text)') is not null then
    execute 'revoke all on function public.request_booking(uuid, text, text, text) from public, anon, authenticated';
  end if;
end;
$$;

create or replace function public.request_booking(
  p_slot_id uuid,
  p_name text,
  p_phone text,
  p_email text,
  p_note text
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
  if char_length(btrim(coalesce(p_phone, ''))) not between 7 and 32
     or btrim(p_phone) !~ '^[+]?[0-9][0-9[:space:]().-]{6,30}$' then
    raise exception 'Enter a valid phone number.';
  end if;
  if nullif(btrim(coalesce(p_email, '')), '') is not null
     and (char_length(btrim(p_email)) not between 3 and 120
       or btrim(p_email) !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then
    raise exception 'Enter a valid email address or leave it blank.';
  end if;
  if char_length(btrim(coalesce(p_note, ''))) not between 1 and 300 then
    raise exception 'Add a short message of up to 300 characters.';
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
    slot_id, availability_title, name, phone, email, note,
    slot_date, start_time, end_time, status
  ) values (
    requested_slot.id, requested_slot.title, btrim(p_name), btrim(p_phone), nullif(btrim(coalesce(p_email, '')), ''), btrim(p_note),
    requested_slot.slot_date, requested_slot.start_time, requested_slot.end_time, 'pending'
  ) returning id into request_id;

  return request_id;
end;
$$;

revoke all on function public.request_booking(uuid, text, text, text, text) from public;
grant execute on function public.request_booking(uuid, text, text, text, text) to anon, authenticated;

do $$
begin
  if to_regprocedure('public.request_time(date,time,time,text,text,text)') is not null then
    execute 'revoke all on function public.request_time(date, time, time, text, text, text) from public, anon, authenticated';
  end if;
end;
$$;

create or replace function public.request_time(
  p_slot_date date,
  p_start_time time,
  p_end_time time,
  p_name text,
  p_phone text,
  p_email text,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_id uuid;
begin
  if p_slot_date is null or p_start_time is null or p_end_time is null or p_end_time <= p_start_time then
    raise exception 'Choose a valid date and time range.';
  end if;
  if p_start_time < time '00:00' or p_start_time >= time '24:00' or p_end_time > time '24:00' then
    raise exception 'Requests must fit within one calendar day.';
  end if;
  if (p_slot_date + p_start_time) <= (now() at time zone 'Asia/Ho_Chi_Minh') then
    raise exception 'Choose a future time.';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 60 then
    raise exception 'Enter a name between 1 and 60 characters.';
  end if;
  if char_length(btrim(coalesce(p_phone, ''))) not between 7 and 32
     or btrim(p_phone) !~ '^[+]?[0-9][0-9[:space:]().-]{6,30}$' then
    raise exception 'Enter a valid phone number.';
  end if;
  if nullif(btrim(coalesce(p_email, '')), '') is not null
     and (char_length(btrim(p_email)) not between 3 and 120
       or btrim(p_email) !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then
    raise exception 'Enter a valid email address or leave it blank.';
  end if;
  if char_length(btrim(coalesce(p_note, ''))) not between 1 and 300 then
    raise exception 'Add a short message of up to 300 characters.';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_slot_date::text)::bigint);

  if exists (
    select 1 from public.timetable_slots as slots
    where slots.slot_date = p_slot_date
      and slots.start_time < p_end_time
      and slots.end_time > p_start_time
  ) or exists (
    select 1 from public.booking_requests as requests
    where requests.slot_date = p_slot_date
      and requests.status in ('pending', 'accepted')
      and requests.start_time < p_end_time
      and requests.end_time > p_start_time
  ) then
    raise exception 'That time is no longer available.';
  end if;

  insert into public.booking_requests (
    slot_id, availability_title, name, phone, email, note,
    slot_date, start_time, end_time, status
  ) values (
    null, 'Visitor request', btrim(p_name), btrim(p_phone), nullif(btrim(coalesce(p_email, '')), ''), btrim(p_note),
    p_slot_date, p_start_time, p_end_time, 'pending'
  ) returning id into request_id;

  return request_id;
end;
$$;

revoke all on function public.request_time(date, time, time, text, text, text, text) from public;
grant execute on function public.request_time(date, time, time, text, text, text, text) to anon, authenticated;
