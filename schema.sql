-- v2: วางทั้งไฟล์ใน Supabase Dashboard > SQL Editor แล้วกด Run (รันซ้ำได้)
create extension if not exists pgcrypto;

create table if not exists public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null default 'staff' check (role in ('owner','staff')),
  created_at timestamptz not null default now()
);

create table if not exists public.menu_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  price numeric(10,2) not null check (price >= 0),
  active boolean not null default true,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  sale_date date not null default (now() at time zone 'Asia/Bangkok')::date,
  sold_at timestamptz not null default now(),
  payment_method text not null check (payment_method in ('cash','transfer','other')),
  note text,
  created_by uuid not null references auth.users(id)
);
alter table public.sales add column if not exists client_token uuid;
alter table public.sales add column if not exists voided boolean not null default false;
alter table public.sales add column if not exists voided_at timestamptz;
alter table public.sales add column if not exists voided_by uuid references auth.users(id);
alter table public.sales add column if not exists void_reason text;
create unique index if not exists sales_client_token_key on public.sales(client_token);
create index if not exists sales_date_idx on public.sales(sale_date);

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  menu_item_id uuid references public.menu_items(id) on delete set null,
  menu_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(10,2) not null check (unit_price >= 0)
);

alter table public.staff enable row level security;
alter table public.menu_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

-- ===== ฟังก์ชันตรวจสิทธิ์ =====
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.staff where user_id = auth.uid()) $$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from public.staff where user_id = auth.uid() $$;

create or replace function public.has_owner() returns boolean
language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.staff where role = 'owner') $$;

-- คนแรกที่กดเท่านั้นที่เป็นเจ้าของร้านได้ (ตอนยังไม่มีเจ้าของ)
create or replace function public.claim_owner() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  lock table public.staff in share row exclusive mode;
  if exists(select 1 from public.staff where role = 'owner') then
    raise exception 'มีเจ้าของร้านอยู่แล้ว';
  end if;
  insert into public.staff(user_id, email, role)
  select id, email, 'owner' from auth.users where id = auth.uid();
end $$;

create or replace function public.add_staff(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare v_u auth.users;
begin
  if coalesce(public.my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  select * into v_u from auth.users where lower(email) = lower(trim(p_email));
  if not found then raise exception 'ไม่พบอีเมลนี้ ให้พนักงานสมัครบัญชีในแอปก่อน'; end if;
  insert into public.staff(user_id, email, role) values (v_u.id, v_u.email, 'staff')
  on conflict do nothing;
end $$;

create or replace function public.remove_staff(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') <> 'owner' then raise exception 'เฉพาะเจ้าของร้านเท่านั้น'; end if;
  delete from public.staff where user_id = p_user and role <> 'owner';
end $$;

-- ===== บันทึกบิลแบบ atomic (ราคาอ่านจากเมนูฝั่งเซิร์ฟเวอร์) =====
create or replace function public.create_sale(
  p_sale_date date, p_payment text, p_note text, p_items jsonb, p_token uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_it jsonb; v_menu public.menu_items; v_qty int;
begin
  if not public.is_staff() then raise exception 'บัญชีนี้ไม่มีสิทธิ์บันทึกยอดขาย'; end if;
  if p_payment not in ('cash','transfer','other') then raise exception 'ช่องทางชำระไม่ถูกต้อง'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'ไม่มีรายการเมนู';
  end if;
  if p_token is not null then
    select id into v_id from public.sales where client_token = p_token;
    if found then return v_id; end if;  -- กดซ้ำ/ส่งซ้ำ: คืนบิลเดิม ไม่สร้างใหม่
  end if;
  insert into public.sales(sale_date, payment_method, note, created_by, client_token)
  values (coalesce(p_sale_date, (now() at time zone 'Asia/Bangkok')::date),
          p_payment, nullif(trim(p_note), ''), auth.uid(), p_token)
  returning id into v_id;
  for v_it in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_it->>'quantity')::int;
    select * into v_menu from public.menu_items
      where id = (v_it->>'menu_item_id')::uuid and active;
    if not found or v_qty is null or v_qty <= 0 then
      raise exception 'เมนูหรือจำนวนไม่ถูกต้อง';
    end if;
    insert into public.sale_items(sale_id, menu_item_id, menu_name, quantity, unit_price)
    values (v_id, v_menu.id, v_menu.name, v_qty, v_menu.price);
  end loop;
  return v_id;
end $$;

-- ===== ลบบิล (ลบถาวร ไม่เหลือประวัติ) =====
drop function if exists public.void_sale(uuid, text);
create or replace function public.delete_sale(p_sale_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'บัญชีนี้ไม่มีสิทธิ์'; end if;
  delete from public.sales where id = p_sale_id;
end $$;

-- ===== Policies (ล้างของ v1 ก่อน) =====
drop policy if exists "authenticated users read menu" on public.menu_items;
drop policy if exists "authenticated users add menu" on public.menu_items;
drop policy if exists "authenticated users update menu" on public.menu_items;
drop policy if exists "authenticated users read sales" on public.sales;
drop policy if exists "authenticated users add sales" on public.sales;
drop policy if exists "authenticated users read sale items" on public.sale_items;
drop policy if exists "authenticated users add sale items" on public.sale_items;
drop policy if exists "staff read staff" on public.staff;
drop policy if exists "staff read menu" on public.menu_items;
drop policy if exists "staff add menu" on public.menu_items;
drop policy if exists "staff update menu" on public.menu_items;
drop policy if exists "staff read sales" on public.sales;
drop policy if exists "staff read sale items" on public.sale_items;

create policy "staff read staff" on public.staff for select to authenticated using (public.is_staff());
create policy "staff read menu" on public.menu_items for select to authenticated using (public.is_staff());
create policy "staff add menu" on public.menu_items for insert to authenticated
  with check (public.is_staff() and auth.uid() = created_by);
create policy "staff update menu" on public.menu_items for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy "staff read sales" on public.sales for select to authenticated using (public.is_staff());
create policy "staff read sale items" on public.sale_items for select to authenticated using (public.is_staff());

-- ===== สิทธิ์ตาราง: เขียนบิลได้ผ่านฟังก์ชันเท่านั้น =====
grant usage on schema public to authenticated;
revoke all on public.staff, public.menu_items, public.sales, public.sale_items from authenticated, anon;
grant select on public.staff, public.sales, public.sale_items to authenticated;
grant select, insert on public.menu_items to authenticated;
grant update (name, price, active) on public.menu_items to authenticated;

revoke all on function public.is_staff(), public.my_role(), public.has_owner(), public.claim_owner(),
  public.add_staff(text), public.remove_staff(uuid),
  public.create_sale(date, text, text, jsonb, uuid), public.delete_sale(uuid) from public, anon;
grant execute on function public.is_staff(), public.my_role(), public.has_owner(), public.claim_owner(),
  public.add_staff(text), public.remove_staff(uuid),
  public.create_sale(date, text, text, jsonb, uuid), public.delete_sale(uuid) to authenticated;

-- ล้างบิลที่เคยยกเลิกไว้ในรุ่นก่อน (ถ้ามี) และฟังก์ชันที่ไม่ใช้แล้ว
delete from public.sales where voided;
drop function if exists public.purge_voided(date, date);

-- ให้ Supabase API มองเห็นฟังก์ชันใหม่ทันที
notify pgrst, 'reload schema';
