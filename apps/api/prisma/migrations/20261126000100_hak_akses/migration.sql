-- T-004 migrasi kustom (ditulis tangan): hak akses skema Prisma — Design §3.6, FR-6, FR-89.
-- Dijalankan `prisma migrate deploy` sebagai mon_owner (pemilik skema auth/studio/audit).
-- Prisma tidak membandingkan GRANT, jadi berkas ini tidak menimbulkan drift.

REVOKE ALL ON SCHEMA auth, studio, audit FROM PUBLIC;

-- ── mon_app (aplikasi): baca/tulis tanpa DELETE; audit hanya-tambah ──
GRANT USAGE ON SCHEMA auth, studio, audit TO mon_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA auth, studio TO mon_app;
-- Pengecualian: sesi bukan tabel dokumen — logout & pembersihan sesi kedaluwarsa butuh DELETE.
GRANT DELETE ON auth.sessions TO mon_app;
GRANT INSERT ON ALL TABLES IN SCHEMA audit TO mon_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA audit TO mon_app;
REVOKE SELECT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA audit FROM mon_app;

-- Tabel/sequence yang dibuat migrasi Prisma berikutnya otomatis mendapat hak yang sama.
ALTER DEFAULT PRIVILEGES FOR ROLE mon_owner IN SCHEMA auth, studio GRANT SELECT, INSERT, UPDATE ON TABLES TO mon_app;
ALTER DEFAULT PRIVILEGES FOR ROLE mon_owner IN SCHEMA audit GRANT INSERT ON TABLES TO mon_app;
ALTER DEFAULT PRIVILEGES FOR ROLE mon_owner IN SCHEMA audit GRANT USAGE ON SEQUENCES TO mon_app;

-- ── mon_ddl (worker DDL, D-4): status rencana DDL + catatan eksekusi ──
GRANT USAGE ON SCHEMA studio, audit TO mon_ddl;
GRANT SELECT, UPDATE ON studio.ddl_plans TO mon_ddl;
GRANT INSERT ON audit.ddl_runs TO mon_ddl;
GRANT USAGE ON SEQUENCE audit.ddl_runs_id_seq TO mon_ddl;

-- ── mon_schema (runner SQL db/migrations): mengisi definisi awal studio (0100_seed_defs.sql) ──
GRANT USAGE ON SCHEMA studio TO mon_schema;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA studio TO mon_schema;
