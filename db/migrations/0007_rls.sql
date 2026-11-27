-- 0007 — Row Level Security standup (Design §3.6, FR-29, SEC-04 lapis kedua). Runner sebagai mon_schema.
-- Peran aplikasi saat ini (A9): Administrator + Tim IT. Staf (Tim IT) hanya standup miliknya; Administrator semua.
-- Kegiatan kalender TIDAK dibatasi RLS (FR-29: Staf melihat kegiatan semua rekan, baca-saja — dijaga API).
-- Konteks dari API per transaksi: SET LOCAL app.role, app.employee_id. Tanpa konteks -> tidak ada baris (gagal-tertutup).
-- Pemilik tabel (mon_schema: runner/migrasi, view, fungsi SECURITY DEFINER) tidak terkena RLS (tidak FORCE).
-- Superuser (pg_dump cadangan) melewati RLS.

SET LOCAL search_path = ds_monitoring, public;  -- hanya untuk transaksi berkas ini

ALTER TABLE daily_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_log_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE log_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY standup_milik_atau_admin ON daily_logs
  USING (fn_ctx_admin() OR employee_id = fn_ctx_employee())
  WITH CHECK (fn_ctx_admin() OR employee_id = fn_ctx_employee());

-- Rincian & komentar mengikuti standup induknya (subkueri ikut terfilter RLS daily_logs)
CREATE POLICY rincian_ikut_standup ON daily_log_items
  USING (EXISTS (SELECT 1 FROM daily_logs l WHERE l.id = log_id))
  WITH CHECK (EXISTS (SELECT 1 FROM daily_logs l WHERE l.id = log_id));

CREATE POLICY komentar_ikut_standup ON log_comments
  USING (EXISTS (SELECT 1 FROM daily_logs l WHERE l.id = log_id))
  WITH CHECK (EXISTS (SELECT 1 FROM daily_logs l WHERE l.id = log_id));
