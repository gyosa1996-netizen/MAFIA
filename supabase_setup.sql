-- ================================================================
-- 실시간 마피아 게임 - Supabase SQL
-- Supabase Dashboard → SQL Editor → New query → 전체 붙여넣기 → Run
-- ================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

-- ---------- tables ----------
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{5}$'),
  status text not null default 'lobby' check (status in ('lobby','playing','finished')),
  phase text not null default 'lobby' check (phase in ('lobby','night','mafia','police','doctor','morning','discussion','vote','result')),
  round integer not null default 0,
  mafia_count integer not null check (mafia_count >= 1),
  police_count integer not null check (police_count >= 0),
  doctor_count integer not null check (doctor_count >= 0),
  citizen_count integer not null check (citizen_count >= 0),
  announcement text not null default '',
  winner text,
  created_at timestamptz not null default now()
);

create table if not exists private.room_secrets (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  host_token_hash text not null
);

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 20),
  alive boolean not null default true,
  joined_at timestamptz not null default now()
);

create unique index if not exists players_room_name_uq
  on public.players(room_id, lower(name));

create table if not exists private.player_secrets (
  player_id uuid primary key references public.players(id) on delete cascade,
  player_token_hash text not null,
  role text check (role in ('마피아','경찰','의사','시민'))
);

create table if not exists private.actions (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  phase text not null check (phase in ('mafia','police','doctor','vote')),
  actor_player_id uuid not null references public.players(id) on delete cascade,
  target_player_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(room_id, round, phase, actor_player_id)
);

create table if not exists private.investigations (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  police_player_id uuid not null references public.players(id) on delete cascade,
  target_player_id uuid not null references public.players(id) on delete cascade,
  is_mafia boolean not null,
  primary key(room_id, round, police_player_id)
);

create table if not exists public.room_events (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  event_kind text not null default 'refresh',
  created_at timestamptz not null default now()
);

create index if not exists room_events_room_id_idx on public.room_events(room_id,id);
create index if not exists players_room_id_idx on public.players(room_id);
create index if not exists actions_room_round_phase_idx on private.actions(room_id,round,phase);

-- ---------- lock down tables ----------
alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.room_events enable row level security;
alter table private.room_secrets enable row level security;
alter table private.player_secrets enable row level security;
alter table private.actions enable row level security;
alter table private.investigations enable row level security;

revoke all on public.rooms from anon, authenticated;
revoke all on public.players from anon, authenticated;
revoke all on private.room_secrets from anon, authenticated;
revoke all on private.player_secrets from anon, authenticated;
revoke all on private.actions from anon, authenticated;
revoke all on private.investigations from anon, authenticated;

grant select on public.room_events to anon, authenticated;

drop policy if exists "room events are readable" on public.room_events;
create policy "room events are readable"
on public.room_events for select
to anon, authenticated
using (true);

-- Realtime publication: only non-secret refresh events are exposed.
do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime')
     and not exists (
       select 1
       from pg_publication_tables
       where pubname='supabase_realtime'
         and schemaname='public'
         and tablename='room_events'
     ) then
    alter publication supabase_realtime add table public.room_events;
  end if;
end $$;

-- ---------- helpers ----------
create or replace function private.hash_token(p_token text)
returns text
language sql
immutable
set search_path=''
as $$
  select encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
$$;

create or replace function private.host_ok(p_room_id uuid, p_token text)
returns boolean
language sql
security definer
set search_path=''
as $$
  select exists(
    select 1 from private.room_secrets s
    where s.room_id=p_room_id
      and s.host_token_hash=private.hash_token(p_token)
  )
$$;

create or replace function private.player_ok(p_player_id uuid, p_token text)
returns boolean
language sql
security definer
set search_path=''
as $$
  select exists(
    select 1 from private.player_secrets s
    where s.player_id=p_player_id
      and s.player_token_hash=private.hash_token(p_token)
  )
$$;

create or replace function private.emit_refresh(p_room_id uuid, p_kind text default 'refresh')
returns void
language plpgsql
security definer
set search_path=''
as $$
begin
  insert into public.room_events(room_id,event_kind) values(p_room_id,coalesce(p_kind,'refresh'));
end $$;

create or replace function private.assign_roles(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  r record;
  cfg record;
begin
  select mafia_count,police_count,doctor_count,citizen_count
  into cfg
  from public.rooms where id=p_room_id;

  for r in
    select p.id, row_number() over(order by random()) as rn
    from public.players p
    where p.room_id=p_room_id
  loop
    update private.player_secrets
    set role = case
      when r.rn <= cfg.mafia_count then '마피아'
      when r.rn <= cfg.mafia_count + cfg.police_count then '경찰'
      when r.rn <= cfg.mafia_count + cfg.police_count + cfg.doctor_count then '의사'
      else '시민'
    end
    where player_id=r.id;
  end loop;
end $$;

create or replace function private.check_winner(p_room_id uuid)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  mafia_alive integer;
  others_alive integer;
begin
  select
    count(*) filter (where s.role='마피아'),
    count(*) filter (where s.role<>'마피아')
  into mafia_alive, others_alive
  from public.players p
  join private.player_secrets s on s.player_id=p.id
  where p.room_id=p_room_id and p.alive=true;

  if mafia_alive=0 then return '시민 팀 승리'; end if;
  if mafia_alive>=others_alive then return '마피아 팀 승리'; end if;
  return null;
end $$;

create or replace function private.resolve_night(p_room_id uuid, p_round integer)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  top_target uuid;
  top_votes integer;
  tie_count integer;
  protected boolean := false;
  victim_name text;
begin
  with counts as (
    select a.target_player_id, count(*)::int votes
    from private.actions a
    join public.players actor on actor.id=a.actor_player_id and actor.alive=true
    join private.player_secrets sec on sec.player_id=actor.id and sec.role='마피아'
    where a.room_id=p_room_id and a.round=p_round and a.phase='mafia'
    group by a.target_player_id
  )
  select target_player_id,votes into top_target,top_votes
  from counts order by votes desc limit 1;

  if top_target is null then
    return '밤사이 아무도 죽지 않았습니다.';
  end if;

  with counts as (
    select a.target_player_id, count(*)::int votes
    from private.actions a
    join public.players actor on actor.id=a.actor_player_id and actor.alive=true
    join private.player_secrets sec on sec.player_id=actor.id and sec.role='마피아'
    where a.room_id=p_room_id and a.round=p_round and a.phase='mafia'
    group by a.target_player_id
  )
  select count(*) into tie_count from counts where votes=top_votes;

  if tie_count>1 then
    return '밤사이 아무도 죽지 않았습니다.';
  end if;

  select exists(
    select 1
    from private.actions a
    join public.players d on d.id=a.actor_player_id and d.alive=true
    join private.player_secrets s on s.player_id=d.id and s.role='의사'
    where a.room_id=p_room_id and a.round=p_round and a.phase='doctor'
      and a.target_player_id=top_target
  ) into protected;

  if protected then
    return '밤사이 아무도 죽지 않았습니다.';
  end if;

  update public.players
  set alive=false
  where id=top_target and room_id=p_room_id and alive=true
  returning name into victim_name;

  if victim_name is null then
    return '밤사이 아무도 죽지 않았습니다.';
  end if;
  return victim_name || ' 님이 밤사이 사망했습니다.';
end $$;

create or replace function private.resolve_vote(p_room_id uuid, p_round integer)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  top_target uuid;
  top_votes integer;
  tie_count integer;
  victim_name text;
begin
  with counts as (
    select a.target_player_id, count(*)::int votes
    from private.actions a
    join public.players actor on actor.id=a.actor_player_id and actor.alive=true
    where a.room_id=p_room_id and a.round=p_round and a.phase='vote'
    group by a.target_player_id
  )
  select target_player_id,votes into top_target,top_votes
  from counts order by votes desc limit 1;

  if top_target is null then return '투표가 없어 처형된 사람이 없습니다.'; end if;

  with counts as (
    select a.target_player_id, count(*)::int votes
    from private.actions a
    join public.players actor on actor.id=a.actor_player_id and actor.alive=true
    where a.room_id=p_room_id and a.round=p_round and a.phase='vote'
    group by a.target_player_id
  )
  select count(*) into tie_count from counts where votes=top_votes;

  if tie_count>1 then return '최다 득표가 동률이라 처형된 사람이 없습니다.'; end if;

  update public.players
  set alive=false
  where id=top_target and room_id=p_room_id and alive=true
  returning name into victim_name;

  if victim_name is null then return '처형된 사람이 없습니다.'; end if;
  return victim_name || ' 님이 투표로 처형되었습니다.';
end $$;

-- ---------- RPC implementations ----------
create or replace function private.create_room_impl(
  p_mafia integer, p_police integer, p_doctor integer, p_citizen integer
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_room_id uuid;
  v_code text;
  v_host_token text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  tries integer := 0;
  total integer := p_mafia+p_police+p_doctor+p_citizen;
begin
  if p_mafia<1 or p_police<0 or p_doctor<0 or p_citizen<0 or total<4 or total>40 then
    raise exception '역할 수 설정을 확인하세요. 총 4~40명, 마피아 1명 이상이어야 합니다.';
  end if;

  loop
    tries := tries+1;
    v_code := lpad((floor(random()*100000)::int)::text,5,'0');
    begin
      insert into public.rooms(code,mafia_count,police_count,doctor_count,citizen_count)
      values(v_code,p_mafia,p_police,p_doctor,p_citizen)
      returning id into v_room_id;
      exit;
    exception when unique_violation then
      if tries>=20 then raise exception '방 코드 생성에 실패했습니다. 다시 시도하세요.'; end if;
    end;
  end loop;

  insert into private.room_secrets(room_id,host_token_hash)
  values(v_room_id,private.hash_token(v_host_token));
  perform private.emit_refresh(v_room_id,'room_created');

  return jsonb_build_object('room_id',v_room_id,'room_code',v_code,'host_token',v_host_token);
end $$;

create or replace function private.join_room_impl(p_code text,p_name text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_room public.rooms%rowtype;
  v_player_id uuid;
  v_player_token text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  current_count integer;
  capacity integer;
  clean_name text := btrim(p_name);
begin
  if clean_name is null or char_length(clean_name)<1 or char_length(clean_name)>20 then
    raise exception '이름은 1~20자로 입력하세요.';
  end if;

  select * into v_room from public.rooms where code=p_code for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if v_room.status<>'lobby' then raise exception '이미 게임이 시작된 방입니다.'; end if;

  capacity := v_room.mafia_count+v_room.police_count+v_room.doctor_count+v_room.citizen_count;
  select count(*) into current_count from public.players where room_id=v_room.id;
  if current_count>=capacity then raise exception '방이 가득 찼습니다.'; end if;

  begin
    insert into public.players(room_id,name) values(v_room.id,clean_name)
    returning id into v_player_id;
  exception when unique_violation then
    raise exception '같은 이름의 참가자가 이미 있습니다.';
  end;

  insert into private.player_secrets(player_id,player_token_hash)
  values(v_player_id,private.hash_token(v_player_token));

  perform private.emit_refresh(v_room.id,'player_joined');
  return jsonb_build_object('room_id',v_room.id,'player_id',v_player_id,'player_token',v_player_token);
end $$;

create or replace function private.get_public_state_impl(p_room_id uuid)
returns jsonb
language sql
security definer
set search_path=''
as $$
  select jsonb_build_object(
    'room', jsonb_build_object(
      'id',r.id,'code',r.code,'status',r.status,'phase',r.phase,'round',r.round,
      'mafia_count',r.mafia_count,'police_count',r.police_count,'doctor_count',r.doctor_count,'citizen_count',r.citizen_count,
      'capacity',r.mafia_count+r.police_count+r.doctor_count+r.citizen_count,
      'announcement',r.announcement,'winner',r.winner
    ),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'alive',p.alive) order by p.joined_at)
      from public.players p where p.room_id=r.id
    ), '[]'::jsonb)
  )
  from public.rooms r where r.id=p_room_id
$$;

create or replace function private.get_host_state_impl(p_room_id uuid,p_host_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  rr public.rooms%rowtype;
  mafia_expected int; police_expected int; doctor_expected int; vote_expected int;
  mafia_sub int; police_sub int; doctor_sub int; vote_sub int;
begin
  if not private.host_ok(p_room_id,p_host_token) then raise exception '진행자 token 오류'; end if;
  select * into rr from public.rooms where id=p_room_id;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;

  select count(*) filter(where s.role='마피아'),
         count(*) filter(where s.role='경찰'),
         count(*) filter(where s.role='의사'),
         count(*)
  into mafia_expected,police_expected,doctor_expected,vote_expected
  from public.players p join private.player_secrets s on s.player_id=p.id
  where p.room_id=p_room_id and p.alive=true;

  select count(*) filter(where a.phase='mafia'),
         count(*) filter(where a.phase='police'),
         count(*) filter(where a.phase='doctor'),
         count(*) filter(where a.phase='vote')
  into mafia_sub,police_sub,doctor_sub,vote_sub
  from private.actions a
  where a.room_id=p_room_id and a.round=rr.round;

  return jsonb_build_object('submissions',jsonb_build_object(
    'mafia_expected',coalesce(mafia_expected,0),'mafia_submitted',coalesce(mafia_sub,0),
    'police_expected',coalesce(police_expected,0),'police_submitted',coalesce(police_sub,0),
    'doctor_expected',coalesce(doctor_expected,0),'doctor_submitted',coalesce(doctor_sub,0),
    'vote_expected',coalesce(vote_expected,0),'vote_submitted',coalesce(vote_sub,0)
  ));
end $$;

create or replace function private.get_my_state_impl(p_player_id uuid,p_player_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  p public.players%rowtype;
  sec private.player_secrets%rowtype;
  rr public.rooms%rowtype;
  inv jsonb;
  submitted text;
  team jsonb := '[]'::jsonb;
begin
  if not private.player_ok(p_player_id,p_player_token) then raise exception '참가자 token 오류'; end if;
  select * into p from public.players where id=p_player_id;
  select * into sec from private.player_secrets where player_id=p_player_id;
  select * into rr from public.rooms where id=p.room_id;

  if sec.role='마피아' then
    select coalesce(jsonb_agg(jsonb_build_object('id',p2.id,'name',p2.name) order by p2.joined_at),'[]'::jsonb)
    into team
    from public.players p2 join private.player_secrets s2 on s2.player_id=p2.id
    where p2.room_id=p.room_id and s2.role='마피아';
  end if;

  select jsonb_build_object('target_name',tp.name,'is_mafia',i.is_mafia)
  into inv
  from private.investigations i join public.players tp on tp.id=i.target_player_id
  where i.room_id=p.room_id and i.round=rr.round and i.police_player_id=p_player_id;

  select a.phase into submitted
  from private.actions a
  where a.room_id=p.room_id and a.round=rr.round and a.actor_player_id=p_player_id and a.phase=rr.phase
  limit 1;

  return jsonb_build_object(
    'id',p.id,'name',p.name,'alive',p.alive,'role',sec.role,
    'mafia_team',team,'investigation',inv,'submitted_phase',submitted
  );
end $$;

create or replace function private.host_start_game_impl(p_room_id uuid,p_host_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  rr public.rooms%rowtype;
  cnt integer;
  capacity integer;
begin
  if not private.host_ok(p_room_id,p_host_token) then raise exception '진행자 token 오류'; end if;
  select * into rr from public.rooms where id=p_room_id for update;
  if rr.status<>'lobby' then raise exception '이미 시작된 게임입니다.'; end if;

  capacity:=rr.mafia_count+rr.police_count+rr.doctor_count+rr.citizen_count;
  select count(*) into cnt from public.players where room_id=p_room_id;
  if cnt<>capacity then raise exception '참가자 수가 역할 수와 일치하지 않습니다.'; end if;

  update public.players set alive=true where room_id=p_room_id;
  delete from private.actions where room_id=p_room_id;
  delete from private.investigations where room_id=p_room_id;
  perform private.assign_roles(p_room_id);
  update public.rooms set status='playing',phase='night',round=1,announcement='',winner=null where id=p_room_id;
  perform private.emit_refresh(p_room_id,'game_started');
  return jsonb_build_object('ok',true);
end $$;

create or replace function private.submit_action_impl(p_player_id uuid,p_player_token text,p_target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor public.players%rowtype;
  target public.players%rowtype;
  rr public.rooms%rowtype;
  actor_role text;
  target_role text;
  result jsonb := jsonb_build_object('ok',true);
begin
  if not private.player_ok(p_player_id,p_player_token) then raise exception '참가자 token 오류'; end if;
  select * into actor from public.players where id=p_player_id;
  if not actor.alive then raise exception '사망한 참가자는 행동할 수 없습니다.'; end if;
  select * into rr from public.rooms where id=actor.room_id;
  if rr.status<>'playing' then raise exception '현재 행동할 수 없습니다.'; end if;
  select role into actor_role from private.player_secrets where player_id=p_player_id;

  select * into target from public.players where id=p_target_id and room_id=actor.room_id and alive=true;
  if not found then raise exception '선택할 수 없는 대상입니다.'; end if;

  if rr.phase='mafia' then
    if actor_role<>'마피아' then raise exception '현재 행동 대상이 아닙니다.'; end if;
    if p_target_id=p_player_id then raise exception '자기 자신은 선택할 수 없습니다.'; end if;
    select role into target_role from private.player_secrets where player_id=p_target_id;
    if target_role='마피아' then raise exception '선택할 수 없는 대상입니다.'; end if;
  elsif rr.phase='police' then
    if actor_role<>'경찰' then raise exception '현재 행동 대상이 아닙니다.'; end if;
    if p_target_id=p_player_id then raise exception '자기 자신은 선택할 수 없습니다.'; end if;
  elsif rr.phase='doctor' then
    if actor_role<>'의사' then raise exception '현재 행동 대상이 아닙니다.'; end if;
  elsif rr.phase='vote' then
    if p_target_id=p_player_id then raise exception '자기 자신에게 투표할 수 없습니다.'; end if;
  else
    raise exception '현재는 제출 단계가 아닙니다.';
  end if;

  insert into private.actions(room_id,round,phase,actor_player_id,target_player_id)
  values(actor.room_id,rr.round,rr.phase,p_player_id,p_target_id)
  on conflict(room_id,round,phase,actor_player_id)
  do update set target_player_id=excluded.target_player_id,created_at=now();

  if rr.phase='police' then
    select role into target_role from private.player_secrets where player_id=p_target_id;
    insert into private.investigations(room_id,round,police_player_id,target_player_id,is_mafia)
    values(actor.room_id,rr.round,p_player_id,p_target_id,target_role='마피아')
    on conflict(room_id,round,police_player_id)
    do update set target_player_id=excluded.target_player_id,is_mafia=excluded.is_mafia;

    result := result || jsonb_build_object(
      'investigation',jsonb_build_object('target_name',target.name,'is_mafia',target_role='마피아')
    );
  end if;

  perform private.emit_refresh(actor.room_id,'action_submitted');
  return result;
end $$;

create or replace function private.host_advance_phase_impl(p_room_id uuid,p_host_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  rr public.rooms%rowtype;
  next_phase text;
  announce text;
  win text;
  alive_police integer := 0;
  alive_doctor integer := 0;
begin
  if not private.host_ok(p_room_id,p_host_token) then raise exception '진행자 token 오류'; end if;
  select * into rr from public.rooms where id=p_room_id for update;
  if rr.status<>'playing' then raise exception '진행 중인 게임이 아닙니다.'; end if;

  select
    count(*) filter (where s.role='경찰'),
    count(*) filter (where s.role='의사')
  into alive_police, alive_doctor
  from public.players p
  join private.player_secrets s on s.player_id=p.id
  where p.room_id=p_room_id and p.alive=true;

  if rr.phase='night' then
    next_phase:='mafia';

  elsif rr.phase='mafia' then
    if alive_police>0 then
      next_phase:='police';
    elsif alive_doctor>0 then
      next_phase:='doctor';
    else
      announce:=private.resolve_night(p_room_id,rr.round);
      next_phase:='morning';
    end if;

  elsif rr.phase='police' then
    if alive_doctor>0 then
      next_phase:='doctor';
    else
      announce:=private.resolve_night(p_room_id,rr.round);
      next_phase:='morning';
    end if;

  elsif rr.phase='doctor' then
    announce:=private.resolve_night(p_room_id,rr.round);
    next_phase:='morning';

  elsif rr.phase='morning' then
    next_phase:='discussion';

  elsif rr.phase='discussion' then
    next_phase:='vote';

  elsif rr.phase='vote' then
    announce:=private.resolve_vote(p_room_id,rr.round);
    next_phase:='result';

  elsif rr.phase='result' then
    update public.rooms set round=round+1,phase='night',announcement='' where id=p_room_id;
    perform private.emit_refresh(p_room_id,'phase_changed');
    return jsonb_build_object('ok',true,'phase','night');

  else
    raise exception '단계 상태가 올바르지 않습니다.';
  end if;

  if announce is not null then
    update public.rooms set announcement=announce where id=p_room_id;
  end if;
  update public.rooms set phase=next_phase where id=p_room_id;

  if next_phase in ('morning','result') then
    win:=private.check_winner(p_room_id);
    if win is not null then
      update public.rooms set status='finished',winner=win where id=p_room_id;
    end if;
  end if;

  perform private.emit_refresh(p_room_id,'phase_changed');
  return jsonb_build_object('ok',true,'phase',next_phase,'winner',win);
end $$;

create or replace function private.host_rematch_impl(p_room_id uuid,p_host_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.host_ok(p_room_id,p_host_token) then raise exception '진행자 token 오류'; end if;
  update public.players set alive=true where room_id=p_room_id;
  delete from private.actions where room_id=p_room_id;
  delete from private.investigations where room_id=p_room_id;
  perform private.assign_roles(p_room_id);
  update public.rooms set status='playing',phase='night',round=1,announcement='',winner=null where id=p_room_id;
  perform private.emit_refresh(p_room_id,'rematch');
  return jsonb_build_object('ok',true);
end $$;

-- ---------- exposed wrappers ----------
-- 실제 보안 로직은 노출되지 않은 private schema에 두고,
-- public RPC는 security invoker wrapper로만 제공합니다.

create or replace function public.create_room(p_mafia integer,p_police integer,p_doctor integer,p_citizen integer)
returns jsonb language sql security invoker set search_path=''
as $$ select private.create_room_impl(p_mafia,p_police,p_doctor,p_citizen) $$;

create or replace function public.join_room(p_code text,p_name text)
returns jsonb language sql security invoker set search_path=''
as $$ select private.join_room_impl(p_code,p_name) $$;

create or replace function public.get_public_state(p_room_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.get_public_state_impl(p_room_id) $$;

create or replace function public.get_host_state(p_room_id uuid,p_host_token text)
returns jsonb language sql security invoker set search_path=''
as $$ select private.get_host_state_impl(p_room_id,p_host_token) $$;

create or replace function public.get_my_state(p_player_id uuid,p_player_token text)
returns jsonb language sql security invoker set search_path=''
as $$ select private.get_my_state_impl(p_player_id,p_player_token) $$;

create or replace function public.host_start_game(p_room_id uuid,p_host_token text)
returns jsonb language sql security invoker set search_path=''
as $$ select private.host_start_game_impl(p_room_id,p_host_token) $$;

create or replace function public.submit_action(p_player_id uuid,p_player_token text,p_target_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.submit_action_impl(p_player_id,p_player_token,p_target_id) $$;

create or replace function public.host_advance_phase(p_room_id uuid,p_host_token text)
returns jsonb language sql security invoker set search_path=''
as $$ select private.host_advance_phase_impl(p_room_id,p_host_token) $$;

create or replace function public.host_rematch(p_room_id uuid,p_host_token text)
returns jsonb language sql security invoker set search_path=''
as $$ select private.host_rematch_impl(p_room_id,p_host_token) $$;

grant usage on schema private to anon, authenticated;


create or replace function public.mafia_ping()
returns boolean
language sql
stable
security invoker
set search_path=''
as $$ select true $$;

revoke execute on function private.create_room_impl(integer,integer,integer,integer) from public;
revoke execute on function private.join_room_impl(text,text) from public;
revoke execute on function private.get_public_state_impl(uuid) from public;
revoke execute on function private.get_host_state_impl(uuid,text) from public;
revoke execute on function private.get_my_state_impl(uuid,text) from public;
revoke execute on function private.host_start_game_impl(uuid,text) from public;
revoke execute on function private.submit_action_impl(uuid,text,uuid) from public;
revoke execute on function private.host_advance_phase_impl(uuid,text) from public;
revoke execute on function private.host_rematch_impl(uuid,text) from public;

revoke execute on function public.create_room(integer,integer,integer,integer) from public;
revoke execute on function public.join_room(text,text) from public;
revoke execute on function public.get_public_state(uuid) from public;
revoke execute on function public.get_host_state(uuid,text) from public;
revoke execute on function public.get_my_state(uuid,text) from public;
revoke execute on function public.host_start_game(uuid,text) from public;
revoke execute on function public.submit_action(uuid,text,uuid) from public;
revoke execute on function public.host_advance_phase(uuid,text) from public;
revoke execute on function public.host_rematch(uuid,text) from public;
revoke execute on function public.mafia_ping() from public;

grant execute on function private.create_room_impl(integer,integer,integer,integer) to anon, authenticated;
grant execute on function private.join_room_impl(text,text) to anon, authenticated;
grant execute on function private.get_public_state_impl(uuid) to anon, authenticated;
grant execute on function private.get_host_state_impl(uuid,text) to anon, authenticated;
grant execute on function private.get_my_state_impl(uuid,text) to anon, authenticated;
grant execute on function private.host_start_game_impl(uuid,text) to anon, authenticated;
grant execute on function private.submit_action_impl(uuid,text,uuid) to anon, authenticated;
grant execute on function private.host_advance_phase_impl(uuid,text) to anon, authenticated;
grant execute on function private.host_rematch_impl(uuid,text) to anon, authenticated;

grant execute on function public.create_room(integer,integer,integer,integer) to anon, authenticated;
grant execute on function public.join_room(text,text) to anon, authenticated;
grant execute on function public.get_public_state(uuid) to anon, authenticated;
grant execute on function public.get_host_state(uuid,text) to anon, authenticated;
grant execute on function public.get_my_state(uuid,text) to anon, authenticated;
grant execute on function public.host_start_game(uuid,text) to anon, authenticated;
grant execute on function public.submit_action(uuid,text,uuid) to anon, authenticated;
grant execute on function public.host_advance_phase(uuid,text) to anon, authenticated;
grant execute on function public.host_rematch(uuid,text) to anon, authenticated;
grant execute on function public.mafia_ping() to anon, authenticated;

-- 완료.
