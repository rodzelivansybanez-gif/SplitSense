-- =====================================================================
-- SplitSense: full database setup for Supabase (PostgreSQL)
-- Run in Supabase > SQL Editor. Parts 1-3 in order.
-- =====================================================================

-- ###################### PART 1: TABLES ###############################

-- ---------------------------------------------------------------------
-- 1. USERS AND ROLE PROFILES
-- ---------------------------------------------------------------------
-- Supabase handles login/passwords in auth.users, so there is no password
-- column here. app_user.user_id is the same id as the auth account.
-- ("user" is a reserved word in PostgreSQL, so the table is app_user.)

create table app_user (
    user_id       uuid primary key references auth.users(id) on delete cascade,
    first_name    text not null,
    last_name     text not null,
    email         varchar(255) not null unique,
    user_role     text not null check (user_role in ('business', 'tenant', 'landlord')),
    date_created  timestamptz not null default now()
);

-- One profile row per user, 1:1 with app_user
create table landlord (
    landlord_id bigint generated always as identity primary key,
    user_id     uuid not null unique references app_user(user_id) on delete cascade
);

create table business (
    business_id bigint generated always as identity primary key,
    user_id     uuid not null unique references app_user(user_id) on delete cascade
);

-- ---------------------------------------------------------------------
-- 2. DORMITORY SIDE
-- ---------------------------------------------------------------------
create table room (
    room_id      bigint generated always as identity primary key,
    room_number  int not null,
    landlord_id  bigint not null references landlord(landlord_id) on delete cascade,
    invite_code  text unique,  -- landlord shares this so tenants can join (optional)
    unique (landlord_id, room_number)
);

-- room_id is nullable: a tenant can sign up before joining a room
create table tenant (
    tenant_id bigint generated always as identity primary key,
    user_id   uuid not null unique references app_user(user_id) on delete cascade,
    room_id   bigint references room(room_id) on delete set null
);

create table electricity_bill (
    electricity_bill_id bigint generated always as identity primary key,
    room_id       bigint not null references room(room_id) on delete cascade,
    period_start  date not null,
    period_end    date not null,
    bill_amount   numeric(12,2) not null check (bill_amount >= 0),
    bill_date     date not null default current_date,
    kwh_usage     numeric(10,2) check (kwh_usage >= 0),
    due_date      date,
    status        text not null default 'pending'
                  check (status in ('pending', 'partially_paid', 'paid')),
    check (period_end >= period_start),
    unique (room_id, period_start, period_end)
);

-- One row per tenant per bill: their share and payment status
create table electricity_division (
    electricity_division_id bigint generated always as identity primary key,
    electricity_bill_id bigint not null references electricity_bill(electricity_bill_id) on delete cascade,
    tenant_id      bigint not null references tenant(tenant_id) on delete cascade,
    share_percent  numeric(5,2)  not null check (share_percent between 0 and 100),
    amount_due     numeric(12,2) not null check (amount_due >= 0),
    payment_status text not null default 'pending'
                   check (payment_status in ('pending', 'paid')),
    date_paid      date,
    is_locked      boolean not null default false,
    unique (electricity_bill_id, tenant_id)
);

-- return_date stays null until the tenant taps "I'm back".
-- electricity_division_id stays null until that month's bill is created.
create table absence (
    absence_id  bigint generated always as identity primary key,
    tenant_id   bigint not null references tenant(tenant_id) on delete cascade,
    leave_date  date not null,
    return_date date,
    electricity_division_id bigint references electricity_division(electricity_division_id) on delete set null,
    check (return_date is null or return_date >= leave_date)
);

create table complaint (
    complaint_id     bigint generated always as identity primary key,
    complaint_number int,
    message          text not null,
    status           text not null default 'open' check (status in ('open', 'resolved')),
    date_created     timestamptz not null default now(),
    room_id          bigint not null references room(room_id) on delete cascade,
    tenant_id        bigint not null references tenant(tenant_id) on delete cascade,
    electricity_division_id bigint references electricity_division(electricity_division_id) on delete set null
);

-- ---------------------------------------------------------------------
-- 3. NOTIFICATIONS
-- ---------------------------------------------------------------------
-- One notification per event, shared by many users through
-- notification_recipient. Exactly one of the three links is filled.
-- Bill is 1:1 (unique). Absence and complaint are 1:many (two events each).

create table notification (
    notification_id     bigint generated always as identity primary key,
    created_at          timestamptz not null default now(),
    type                text not null check (type in (
                            'absence_leave', 'absence_return',
                            'complaint_submitted', 'complaint_resolved',
                            'bill_created')),
    message             text not null,
    absence_id          bigint references absence(absence_id) on delete cascade,
    complaint_id        bigint references complaint(complaint_id) on delete cascade,
    electricity_bill_id bigint unique references electricity_bill(electricity_bill_id) on delete cascade,
    check (num_nonnulls(absence_id, complaint_id, electricity_bill_id) = 1)
);

create table notification_recipient (
    notification_recipient_id bigint generated always as identity primary key,
    notification_id bigint not null references notification(notification_id) on delete cascade,
    user_id         uuid   not null references app_user(user_id) on delete cascade,
    is_read         boolean not null default false,
    read_at         timestamptz,
    unique (notification_id, user_id)
);

-- ---------------------------------------------------------------------
-- 4. BUSINESS SIDE (PREDICTIONS)
-- ---------------------------------------------------------------------
create table schedule (
    schedule_id  bigint generated always as identity primary key,
    business_id  bigint not null references business(business_id) on delete cascade,
    name         text not null,
    month_year   date not null check (extract(day from month_year) = 1), -- store the 1st, e.g. 2026-03-01
    rate_per_kwh numeric(10,4) not null check (rate_per_kwh >= 0)
);

create table appliance (
    appliance_id bigint generated always as identity primary key,
    schedule_id  bigint not null references schedule(schedule_id) on delete cascade,
    name         text not null,
    watts        int not null check (watts > 0),
    quantity     int not null default 1 check (quantity > 0)
);

-- One row per appliance per day (the drag-and-drop on the calendar)
create table usage (
    usage_id     bigint generated always as identity primary key,
    appliance_id bigint not null references appliance(appliance_id) on delete cascade,
    usage_date   date not null,
    hours_on     numeric(4,2) not null check (hours_on >= 0 and hours_on <= 24),
    unique (appliance_id, usage_date)
);

-- One result per usage row: kwh = watts * quantity * hours_on / 1000
create table calculation (
    calculation_id bigint generated always as identity primary key,
    usage_id       bigint not null unique references usage(usage_id) on delete cascade,
    kwh            numeric(10,3) not null,
    cost           numeric(12,2) not null,
    calculated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. INDEXES ON FOREIGN KEYS (faster dashboards and joins)
-- ---------------------------------------------------------------------
create index on room (landlord_id);
create index on tenant (room_id);
create index on electricity_bill (room_id);
create index on electricity_division (tenant_id);
create index on absence (tenant_id);
create index on absence (electricity_division_id);
create index on complaint (room_id);
create index on complaint (tenant_id);
create index on notification (absence_id);
create index on notification (complaint_id);
create index on notification_recipient (user_id);
create index on schedule (business_id);
create index on appliance (schedule_id);

-- ---------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
-- With RLS on and no policies, the public API blocks all access (safe by
-- default). The service role key bypasses RLS. Add policies per table
-- before using the anon/authenticated key from the browser.

alter table app_user              enable row level security;
alter table landlord              enable row level security;
alter table business              enable row level security;
alter table room                  enable row level security;
alter table tenant                enable row level security;
alter table electricity_bill      enable row level security;
alter table electricity_division  enable row level security;
alter table absence               enable row level security;
alter table complaint             enable row level security;
alter table notification          enable row level security;
alter table notification_recipient enable row level security;
alter table schedule              enable row level security;
alter table appliance             enable row level security;
alter table usage                 enable row level security;
alter table calculation           enable row level security;

-- ###################### PART 2: SIGN-UP TRIGGER ######################
-- Creates app_user + the role profile automatically when someone signs up.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text := new.raw_user_meta_data->>'user_role';
begin
  insert into app_user (user_id, first_name, last_name, email, user_role)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'first_name', ''),
          coalesce(new.raw_user_meta_data->>'last_name', ''),
          new.email, r);

  if r = 'tenant' then insert into tenant (user_id) values (new.id);
  elsif r = 'landlord' then insert into landlord (user_id) values (new.id);
  elsif r = 'business' then insert into business (user_id) values (new.id);
  end if;
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- ###################### PART 3: SECURITY POLICIES ####################
-- More policies will be added as each dashboard is built.

create policy "Users can read their own profile"
on app_user for select
to authenticated
using (user_id = auth.uid());
