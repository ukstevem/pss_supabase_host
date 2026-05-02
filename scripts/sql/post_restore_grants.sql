-- post_restore_grants.sql
--
-- Re-apply the standard Supabase role grants on the public schema.
--
-- Why: pg_dump with --no-privileges (which we use to avoid bringing in
-- cloud-specific role references) strips ALL grant statements, including
-- the GRANT TO anon/authenticated/service_role lines that supabase's init
-- normally applies on a fresh install. Without these grants, PostgREST
-- returns 403 on everything — the API roles can't even SELECT from public
-- tables. Studio still works because it connects via supabase_admin.
--
-- This script restores the canonical Supabase grant pattern on the public
-- schema. Run after every restore (resync.sh applies it automatically as
-- the final step of section 2/3).
--
-- Run as supabase_admin (superuser):
--   docker exec -i supabase-db psql -U supabase_admin -d postgres < post_restore_grants.sql

-- Schema-level USAGE so the roles can reference public.* at all
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- All-existing-objects grants
GRANT ALL ON ALL TABLES    IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;

-- Default privileges so future tables/seqs/funcs created in public get the
-- same grants automatically (e.g. via SQL run from Studio after restore).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
