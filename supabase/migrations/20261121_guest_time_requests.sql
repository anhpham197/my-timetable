-- Allow unauthenticated guests to request any unblocked future time.
-- Request data remains private; get_public_schedule exposes only a busy marker.

alter table public.booking_requests alter column slot_id drop not null;

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

create or replace function public.request_time(
  p_slot_date date,
  p_start_time time,
  p_end_time time,
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
  request_id uuid;
begin
  if p_slot_date is null or p_start_time is null or p_end_time is null or p_end_time <= p_start_time then
    raise exception 'Choose a valid date and time range.';
  end if;
  if p_start_time < time '08:00' or p_end_time > time '20:00' then
    raise exception 'Requests must be between 8:00 AM and 8:00 PM.';
  end if;
  if (p_slot_date + p_start_time) <= (now() at time zone 'Asia/Ho_Chi_Minh') then
    raise exception 'Choose a future time.';
  end if;
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
    slot_id, availability_title, name, email, note,
    slot_date, start_time, end_time, status
  ) values (
    null, 'Visitor request', btrim(p_name), btrim(p_email), coalesce(btrim(p_note), ''),
    p_slot_date, p_start_time, p_end_time, 'pending'
  ) returning id into request_id;

  return request_id;
end;
$$;

revoke all on function public.request_time(date, time, time, text, text, text) from public;
grant execute on function public.request_time(date, time, time, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
