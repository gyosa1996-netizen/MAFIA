-- Supabase 연결 확인 함수 보완용
-- 기존 supabase_setup.sql을 정상 실행했다면 다시 실행해도 안전합니다.

create or replace function public.mafia_ping()
returns boolean
language sql
stable
security invoker
set search_path=''
as $$ select true $$;

revoke execute on function public.mafia_ping() from public;
grant execute on function public.mafia_ping() to anon, authenticated;
