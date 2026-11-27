-- 0006 — View laporan ds_monitoring (Design §3.5, T-008). Dijalankan runner sebagai mon_schema.
-- View dibaca lewat scopedQuery sebagai resource kind=report (baca-saja); mon_report hanya SELECT view.
-- View berjalan dengan hak pemiliknya (mon_schema, pemilik tabel) sehingga RLS 0007 tidak berlaku di dalamnya.
-- Karena itu view yang memuat ISI standup (v_open_blockers) menanam aturan FR-29 di WHERE-nya sendiri;
-- view lain hanya memuat angka/keberadaan (bukan isi standup).
-- Konteks sesi dari API (SET LOCAL): app.role = 'admin' | 'staff', app.employee_id = uuid karyawan.

SET LOCAL search_path = ds_monitoring, public;  -- hanya untuk transaksi berkas ini

-- Konteks peran (dipakai view & kebijakan RLS)
CREATE FUNCTION fn_ctx_admin() RETURNS boolean
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog
AS $$ SELECT coalesce(current_setting('app.role', true), '') = 'admin' $$;

CREATE FUNCTION fn_ctx_employee() RETURNS uuid
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog
AS $$ SELECT nullif(current_setting('app.employee_id', true), '')::uuid $$;

-- Status hari & turunannya hanya membuka KEBERADAAN standup (bukan isinya), dan harus benar untuk semua
-- karyawan (kalender bulan tim, kepatuhan). SECURITY DEFINER agar tidak terpotong RLS milik pemanggil.
ALTER FUNCTION fn_day_status(uuid, date) SECURITY DEFINER;
ALTER FUNCTION fn_log_compliance(date, date) SECURITY DEFINER;
ALTER FUNCTION fn_missing_logs(date) SECURITY DEFINER;

-- ───────────── papan & item ─────────────
CREATE VIEW v_board_items AS
SELECT w.id, w.project_id, p.code AS project_code, p.name AS project_name, p.team_id, p.method,
       w.sprint_id, w.item_key, w.title, w.status_code, ws.name AS status_name,
       coalesce(ws.category, 'todo') AS status_category, ws.sort AS status_sort, ws.color_token,
       w.priority, w.type_id, it.code AS type_code, w.assignee_id, e.full_name AS assignee_name,
       w.story_points, w.progress, w.due_date, w.labels,
       (w.due_date < fn_today() AND coalesce(ws.category, 'todo') NOT IN ('done', 'cancel')) AS lewat_target,
       (SELECT count(*) FROM daily_log_items li WHERE li.item_id = w.id AND li.deleted_at IS NULL)::int AS jumlah_pembaruan,
       w.created_at, w.updated_at, w.row_version
  FROM work_items w
  JOIN projects p ON p.id = w.project_id
  LEFT JOIN workflow_statuses ws ON ws.method = p.method AND ws.code = w.status_code AND ws.deleted_at IS NULL
  LEFT JOIN item_types it ON it.id = w.type_id
  LEFT JOIN employees e ON e.id = w.assignee_id
 WHERE w.deleted_at IS NULL AND p.deleted_at IS NULL;

CREATE VIEW v_overdue_items AS
SELECT b.*, fn_today() - b.due_date AS terlambat_hari
  FROM v_board_items b
 WHERE b.lewat_target;

-- ───────────── standup ─────────────
-- Hambatan terbuka = standup terakhir tiap karyawan (14 hari terakhir) yang masih berisi hambatan.
-- Aturan FR-29 ditanam: Staf hanya miliknya; Administrator dan mon_report (digest) semua.
CREATE VIEW v_open_blockers AS
SELECT x.log_id, x.employee_id, x.full_name, x.log_date, x.blockers, fn_today() - x.log_date AS umur_hari
  FROM (
    SELECT DISTINCT ON (l.employee_id) l.id AS log_id, l.employee_id, e.full_name, l.log_date, l.blockers, l.has_blocker
      FROM daily_logs l JOIN employees e ON e.id = l.employee_id
     WHERE l.deleted_at IS NULL AND e.deleted_at IS NULL AND l.log_date >= fn_today() - 14
     ORDER BY l.employee_id, l.log_date DESC
  ) x
 WHERE x.has_blocker
   AND (session_user = 'mon_report' OR fn_ctx_admin() OR x.employee_id = fn_ctx_employee());

-- ───────────── rekap (FR-34) ─────────────
-- Butir harian per (tanggal, karyawan, proyek). Baris hambatan/standup memakai project_id NULL.
--   item_selesai      : item masuk kategori done pada tanggal itu (riwayat status), dihitung ke assignee
--   item_lewat_target : item bertarget tanggal itu yang tidak selesai sampai akhir tanggal tersebut
--   progres_rata      : rata-rata progres yang dilaporkan di standup tanggal itu
--   hambatan / standup_terisi : dari daily_logs
CREATE VIEW v_recap_daily AS
WITH selesai AS (
  SELECT (h.changed_at AT TIME ZONE 'Asia/Makassar')::date AS tanggal, w.assignee_id AS employee_id, w.project_id,
         count(DISTINCT w.id)::int AS item_selesai
    FROM work_item_status_history h
    JOIN work_items w ON w.id = h.item_id AND w.deleted_at IS NULL
    JOIN projects p ON p.id = w.project_id
    JOIN workflow_statuses ws ON ws.method = p.method AND ws.code = h.to_code AND ws.category = 'done'
   WHERE w.assignee_id IS NOT NULL
   GROUP BY 1, 2, 3
), telat AS (
  SELECT w.due_date AS tanggal, w.assignee_id AS employee_id, w.project_id, count(*)::int AS item_lewat_target
    FROM work_items w JOIN projects p ON p.id = w.project_id
   WHERE w.deleted_at IS NULL AND w.due_date IS NOT NULL AND w.assignee_id IS NOT NULL AND w.due_date < fn_today()
     AND NOT EXISTS (
       SELECT 1 FROM work_item_status_history h
         JOIN workflow_statuses ws ON ws.method = p.method AND ws.code = h.to_code AND ws.category IN ('done', 'cancel')
        WHERE h.item_id = w.id AND h.changed_at < ((w.due_date + 1)::timestamp AT TIME ZONE 'Asia/Makassar'))
   GROUP BY 1, 2, 3
), progres AS (
  SELECT l.log_date AS tanggal, l.employee_id, w.project_id, round(avg(li.progress_to), 1) AS progres_rata
    FROM daily_log_items li
    JOIN daily_logs l ON l.id = li.log_id AND l.deleted_at IS NULL
    JOIN work_items w ON w.id = li.item_id
   WHERE li.deleted_at IS NULL AND li.progress_to IS NOT NULL
   GROUP BY 1, 2, 3
), standup AS (
  SELECT l.log_date AS tanggal, l.employee_id, NULL::uuid AS project_id,
         count(*)::int AS standup_terisi, count(*) FILTER (WHERE l.has_blocker)::int AS hambatan
    FROM daily_logs l WHERE l.deleted_at IS NULL
   GROUP BY 1, 2
), kunci AS (
  SELECT tanggal, employee_id, project_id FROM selesai
  UNION SELECT tanggal, employee_id, project_id FROM telat
  UNION SELECT tanggal, employee_id, project_id FROM progres
  UNION SELECT tanggal, employee_id, project_id FROM standup
)
SELECT k.tanggal, k.employee_id, e.full_name, k.project_id, p.code AS project_code, p.team_id,
       coalesce(s.item_selesai, 0) AS item_selesai, coalesce(t.item_lewat_target, 0) AS item_lewat_target,
       g.progres_rata, coalesce(su.hambatan, 0) AS hambatan, coalesce(su.standup_terisi, 0) AS standup_terisi
  FROM kunci k
  JOIN employees e ON e.id = k.employee_id
  LEFT JOIN projects p ON p.id = k.project_id
  LEFT JOIN selesai s ON (s.tanggal, s.employee_id, s.project_id) = (k.tanggal, k.employee_id, k.project_id)
  LEFT JOIN telat t ON (t.tanggal, t.employee_id, t.project_id) = (k.tanggal, k.employee_id, k.project_id)
  LEFT JOIN progres g ON (g.tanggal, g.employee_id, g.project_id) = (k.tanggal, k.employee_id, k.project_id)
  LEFT JOIN standup su ON su.tanggal = k.tanggal AND su.employee_id = k.employee_id AND k.project_id IS NULL;

CREATE VIEW v_recap_weekly AS
SELECT date_trunc('week', tanggal)::date AS minggu_mulai, employee_id, full_name, project_id, project_code, team_id,
       sum(item_selesai)::int AS item_selesai, sum(item_lewat_target)::int AS item_lewat_target,
       round(avg(progres_rata), 1) AS progres_rata, sum(hambatan)::int AS hambatan, sum(standup_terisi)::int AS standup_terisi
  FROM v_recap_daily
 GROUP BY 1, 2, 3, 4, 5, 6;

CREATE VIEW v_recap_monthly AS
SELECT date_trunc('month', tanggal)::date AS bulan, employee_id, full_name, project_id, project_code, team_id,
       sum(item_selesai)::int AS item_selesai, sum(item_lewat_target)::int AS item_lewat_target,
       round(avg(progres_rata), 1) AS progres_rata, sum(hambatan)::int AS hambatan, sum(standup_terisi)::int AS standup_terisi
  FROM v_recap_daily
 GROUP BY 1, 2, 3, 4, 5, 6;

-- ───────────── kalender & jam ─────────────
-- Karyawan aktif × tanggal (400 hari ke belakang s.d. 62 hari ke depan). Filter tanggal di kueri pemakai.
CREATE VIEW v_team_calendar AS
SELECT e.id AS employee_id, e.full_name, g::date AS tanggal, fn_day_status(e.id, g::date) AS status
  FROM employees e
 CROSS JOIN generate_series(fn_today() - 400, fn_today() + 62, interval '1 day') g
 WHERE e.is_active AND e.deleted_at IS NULL;

-- FR-45: jam dari kegiatan timed + done + kind <> leave, per hari
CREATE VIEW v_hours_recap AS
SELECT ev.event_date AS tanggal, ev.employee_id, e.full_name, ev.project_id, p.code AS project_code,
       ev.category_id, c.name AS category_name, c.kind,
       sum(ev.duration_min)::int AS menit, round(sum(ev.duration_min) / 60.0, 2) AS jam
  FROM calendar_events ev
  JOIN calendar_categories c ON c.id = ev.category_id
  JOIN employees e ON e.id = ev.employee_id
  LEFT JOIN projects p ON p.id = ev.project_id
 WHERE ev.deleted_at IS NULL AND ev.status = 'done' AND NOT ev.all_day AND c.kind <> 'leave'
 GROUP BY 1, 2, 3, 4, 5, 6, 7, 8;

-- FR-24d: kegiatan berstatus plan yang tanggalnya sudah lewat/hari ini
CREATE VIEW v_pending_confirmation AS
SELECT ev.id, ev.employee_id, e.full_name, ev.event_date, ev.all_day, ev.start_min, ev.duration_min,
       ev.title, ev.category_id, c.name AS category_name, ev.project_id, fn_today() - ev.event_date AS umur_hari, ev.row_version
  FROM calendar_events ev
  JOIN calendar_categories c ON c.id = ev.category_id
  JOIN employees e ON e.id = ev.employee_id
 WHERE ev.deleted_at IS NULL AND ev.status = 'plan' AND ev.event_date <= fn_today();

-- FR-60: aktivitas terakhir per karyawan aktif
CREATE VIEW v_last_activity AS
SELECT e.id AS employee_id, e.full_name,
       (SELECT max(l.log_date) FROM daily_logs l WHERE l.employee_id = e.id AND l.deleted_at IS NULL) AS standup_terakhir,
       (SELECT max(ev.event_date) FROM calendar_events ev
         WHERE ev.employee_id = e.id AND ev.deleted_at IS NULL AND ev.status = 'done') AS kegiatan_terakhir,
       (SELECT max((h.changed_at AT TIME ZONE 'Asia/Makassar')::date) FROM work_item_status_history h
         WHERE e.user_id IS NOT NULL AND h.changed_by = e.user_id) AS ubah_item_terakhir,
       fn_today() - greatest(
         (SELECT max(l.log_date) FROM daily_logs l WHERE l.employee_id = e.id AND l.deleted_at IS NULL),
         (SELECT max(ev.event_date) FROM calendar_events ev
           WHERE ev.employee_id = e.id AND ev.deleted_at IS NULL AND ev.status = 'done')) AS hari_sejak
  FROM employees e
 WHERE e.is_active AND e.deleted_at IS NULL;

-- ───────────── hak akses view ─────────────
-- Hak bawaan 0001 memberi mon_app INSERT/UPDATE pada "tabel" (termasuk view) — view laporan baca-saja.
DO $$
DECLARE v text;
BEGIN
  FOR v IN SELECT viewname FROM pg_views WHERE schemaname = 'ds_monitoring' LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ds_monitoring.%I FROM mon_app', v);
    EXECUTE format('GRANT SELECT ON ds_monitoring.%I TO mon_app, mon_report', v);
  END LOOP;
END $$;
-- Fungsi yang dipanggil di dalam view diperiksa terhadap PEMAKAI view (bukan pemilik)
GRANT EXECUTE ON FUNCTION fn_today(), fn_day_status(uuid, date), fn_ctx_admin(), fn_ctx_employee() TO mon_report;
