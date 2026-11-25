-- T-003 · Bootstrap superuser (dijalankan sebagai `postgres` di container vora-kegiatan-db, idempoten).
-- Berisi HANYA hal yang butuh superuser. Semua objek data dibuat runner migrasi sebagai mon_schema.
-- Design §3.6 (DCL) + Amandemen 02.

-- Pemilik semua objek ds_monitoring: peran tanpa login. mon_owner (runner) memakainya lewat SET ROLE,
-- tidak mewarisi otomatis (INHERIT FALSE) — hak pemilik hanya aktif saat migrasi berjalan.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mon_schema') THEN
    CREATE ROLE mon_schema NOLOGIN;
  END IF;
END
$$;
GRANT mon_schema TO mon_owner WITH INHERIT FALSE, SET TRUE;

CREATE SCHEMA IF NOT EXISTS ds_monitoring AUTHORIZATION mon_schema;
REVOKE ALL ON SCHEMA ds_monitoring FROM PUBLIC;
GRANT USAGE ON SCHEMA ds_monitoring TO mon_owner, mon_app, mon_report, mon_ddl;

-- Tidak ada peran yang boleh membuat objek di skema public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Batas waktu per peran (PRD GridBuilder: query 15 dtk, tunggu kunci 5 dtk / 3 dtk saat migrasi).
ALTER ROLE mon_app    SET statement_timeout = '15s';
ALTER ROLE mon_app    SET lock_timeout = '5s';
ALTER ROLE mon_report SET statement_timeout = '15s';
ALTER ROLE mon_owner  SET lock_timeout = '3s';
