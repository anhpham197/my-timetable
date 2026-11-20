-- Show all 24 hours and require useful contact details on visitor requests.
-- Existing requests are retained; phone stays nullable only for legacy rows.

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

do $$
begin
  if to_regprocedure('public.request_booking(uuid,text,text,text)') is not null then
    execute 'revoke all on function public.request_booking(uuid, text, text, text) from public, anon, authenticated';
  end if;
  if to_regprocedure('public.request_time(date,time,time,text,text,text)') is not null then
    execute 'revoke all on function public.request_time(date, time, time, text, text, text) from public, anon, authenticated';
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

notify pgrst, 'reload schema';
