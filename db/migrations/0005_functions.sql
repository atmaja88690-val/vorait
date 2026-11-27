-- 0005 — Function & procedure ds_monitoring (Design §3.4, T-007). Dijalankan runner sebagai mon_schema.
-- Zona waktu bisnis: Asia/Makassar (WITA), ditulis eksplisit — tidak bergantung setelan sesi.
-- Kode galat: VR004 aturan tutup sprint (FR-18); 22023 rentang tanggal tidak sah (> 366 hari / terbalik).
-- Semua fungsi memasang search_path sendiri (mon_app/mon_report memakai search_path bawaan).

SET LOCAL search_path = ds_monitoring, public;  -- hanya untuk transaksi berkas ini

CREATE FUNCTION fn_today() RETURNS date
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog
AS $$ SELECT (now() AT TIME ZONE 'Asia/Makassar')::date $$;

CREATE FUNCTION fn_cek_rentang(p_from date, p_to date) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 366 THEN
    RAISE EXCEPTION 'rentang tanggal tidak sah: % s.d. % (maks. 366 hari)', p_from, p_to USING ERRCODE = '22023';
  END IF;
END $$;

-- Hari kerja: work_calendar.is_workday dan bukan hari libur (FR-42)
CREATE FUNCTION fn_workdays(p_from date, p_to date) RETURNS TABLE (d date)
LANGUAGE plpgsql STABLE SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  PERFORM fn_cek_rentang(p_from, p_to);
  RETURN QUERY
    SELECT g::date FROM generate_series(p_from, p_to, interval '1 day') g
      JOIN work_calendar w ON w.weekday = extract(isodow FROM g)::int AND w.is_workday AND w.deleted_at IS NULL
     WHERE NOT EXISTS (SELECT 1 FROM holidays h WHERE h.holiday_date = g::date AND h.deleted_at IS NULL)
     ORDER BY 1;
END $$;

-- Status hari per karyawan (FR-42, FR-20). Urutan CASE = prioritas.
CREATE FUNCTION fn_day_status(p_emp uuid, p_d date) RETURNS text
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog AS $$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM work_calendar w
                      WHERE w.weekday = extract(isodow FROM p_d)::int AND w.is_workday AND w.deleted_at IS NULL)
      THEN 'non_workday'
    WHEN EXISTS (SELECT 1 FROM holidays h WHERE h.holiday_date = p_d AND h.deleted_at IS NULL)
      THEN 'holiday'
    WHEN EXISTS (SELECT 1 FROM calendar_events e JOIN calendar_categories c ON c.id = e.category_id
                  WHERE e.employee_id = p_emp AND e.event_date = p_d AND e.all_day
                    AND e.deleted_at IS NULL AND e.status <> 'cancelled' AND c.kind IN ('leave', 'duty'))
      THEN 'excluded'
    WHEN p_d > fn_today()
      THEN 'future'
    WHEN EXISTS (SELECT 1 FROM daily_logs l WHERE l.employee_id = p_emp AND l.log_date = p_d AND l.deleted_at IS NULL)
      THEN 'filled'
    ELSE 'missing'
  END
$$;

-- Kepatuhan standup per karyawan aktif: wajib = filled + missing (FR-42)
CREATE FUNCTION fn_log_compliance(p_from date, p_to date)
RETURNS TABLE (employee_id uuid, full_name text, wajib int, terisi int, persen numeric)
LANGUAGE plpgsql STABLE SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  PERFORM fn_cek_rentang(p_from, p_to);
  RETURN QUERY
    SELECT e.id, e.full_name::text,
           count(*) FILTER (WHERE x.s IN ('filled', 'missing'))::int,
           count(*) FILTER (WHERE x.s = 'filled')::int,
           CASE WHEN count(*) FILTER (WHERE x.s IN ('filled', 'missing')) = 0 THEN NULL
                ELSE round(100.0 * count(*) FILTER (WHERE x.s = 'filled')
                           / count(*) FILTER (WHERE x.s IN ('filled', 'missing')), 1) END
      FROM employees e
      CROSS JOIN LATERAL (SELECT fn_day_status(e.id, g::date) AS s
                            FROM generate_series(p_from, p_to, interval '1 day') g) x
     WHERE e.is_active AND e.deleted_at IS NULL
     GROUP BY e.id, e.full_name
     ORDER BY e.full_name;
END $$;

-- Karyawan aktif yang belum mengisi standup pada hari wajib d (FR-51; dipakai pengingat Telegram)
CREATE FUNCTION fn_missing_logs(p_d date)
RETURNS TABLE (employee_id uuid, full_name text, telegram_chat_id bigint)
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog AS $$
  SELECT e.id, e.full_name::text, e.telegram_chat_id
    FROM employees e
   WHERE e.is_active AND e.deleted_at IS NULL AND fn_day_status(e.id, p_d) = 'missing'
   ORDER BY e.full_name
$$;

-- Jam kerja dari kegiatan kalender (FR-45): hanya timed + done + kind <> leave
CREATE FUNCTION fn_work_hours(p_from date, p_to date)
RETURNS TABLE (employee_id uuid, project_id uuid, category_id uuid, menit bigint, jam numeric)
LANGUAGE plpgsql STABLE SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  PERFORM fn_cek_rentang(p_from, p_to);
  RETURN QUERY
    SELECT e.employee_id, e.project_id, e.category_id, sum(e.duration_min)::bigint, round(sum(e.duration_min) / 60.0, 2)
      FROM calendar_events e JOIN calendar_categories c ON c.id = e.category_id
     WHERE e.event_date BETWEEN p_from AND p_to
       AND e.deleted_at IS NULL AND e.status = 'done' AND NOT e.all_day AND c.kind <> 'leave'
     GROUP BY e.employee_id, e.project_id, e.category_id;
END $$;

-- Burndown (FR-33): sisa poin per hari sprint, status per akhir hari WITA dari riwayat status.
-- Batasan: keanggotaan sprint memakai sprint_id SAAT INI (perpindahan sprint tidak berriwayat) dan
-- poin memakai story_points saat ini. Status tanpa kategori (alur belum diisi) dihitung belum selesai.
CREATE FUNCTION fn_sprint_burndown(p_sprint uuid) RETURNS TABLE (hari date, sisa_poin int)
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog AS $$
  WITH s AS (
    SELECT sp.id, sp.start_date, sp.end_date, p.method
      FROM sprints sp JOIN projects p ON p.id = sp.project_id
     WHERE sp.id = p_sprint AND sp.deleted_at IS NULL
  ), h AS (
    SELECT g::date AS d, ((g::date + 1)::timestamp AT TIME ZONE 'Asia/Makassar') AS batas
      FROM s, generate_series(s.start_date, s.end_date, interval '1 day') g
  ), it AS (
    SELECT w.id, w.created_at, coalesce(w.story_points, 0) AS pts, w.status_code AS kini
      FROM work_items w JOIN s ON w.sprint_id = s.id
     WHERE w.deleted_at IS NULL
  )
  SELECT h.d,
         coalesce(sum(it.pts) FILTER (WHERE coalesce(ws.category, 'todo') NOT IN ('done', 'cancel')), 0)::int
    FROM h CROSS JOIN s
    LEFT JOIN it ON it.created_at < h.batas
    LEFT JOIN LATERAL (
      SELECT coalesce(
        (SELECT x.to_code FROM work_item_status_history x
          WHERE x.item_id = it.id AND x.changed_at < h.batas ORDER BY x.changed_at DESC, x.created_at DESC LIMIT 1),
        (SELECT x.from_code FROM work_item_status_history x
          WHERE x.item_id = it.id ORDER BY x.changed_at, x.created_at LIMIT 1),
        it.kini) AS kode
    ) st ON it.id IS NOT NULL
    LEFT JOIN workflow_statuses ws ON ws.method = s.method AND ws.code = st.kode AND ws.deleted_at IS NULL
   GROUP BY h.d
   ORDER BY h.d
$$;

-- Tutup sprint (FR-18). Dipanggil CALL di dalam transaksi Node; tanpa COMMIT internal.
-- Item yang belum selesai (kategori bukan done/cancel) dipindah ke sprint tujuan (atau backlog bila NULL).
-- Audit tercatat otomatis lewat trg_90_audit; pelaku dari p_actor (atau app.user_id yang sudah dipasang).
CREATE PROCEDURE sp_close_sprint(p_sprint uuid, p_target uuid, p_actor uuid, INOUT p_dipindah int DEFAULT NULL)
LANGUAGE plpgsql SET search_path = ds_monitoring, pg_catalog AS $$
DECLARE s record; t record;
BEGIN
  IF p_actor IS NOT NULL THEN
    PERFORM set_config('app.user_id', p_actor::text, true);
  END IF;
  SELECT sp.id, sp.project_id, sp.status, p.method INTO s
    FROM sprints sp JOIN projects p ON p.id = sp.project_id
   WHERE sp.id = p_sprint AND sp.deleted_at IS NULL
     FOR UPDATE OF sp;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sprint % tidak ditemukan', p_sprint USING ERRCODE = 'VR004';
  END IF;
  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'hanya sprint aktif yang bisa ditutup (status: %)', s.status USING ERRCODE = 'VR004';
  END IF;
  IF p_target IS NOT NULL THEN
    SELECT id, project_id, status INTO t FROM sprints WHERE id = p_target AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND OR t.project_id <> s.project_id OR t.id = s.id OR t.status <> 'planned' THEN
      RAISE EXCEPTION 'sprint tujuan harus sprint terencana di proyek yang sama' USING ERRCODE = 'VR004';
    END IF;
  END IF;
  UPDATE work_items w SET sprint_id = p_target
   WHERE w.sprint_id = p_sprint AND w.deleted_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM workflow_statuses ws
                      WHERE ws.method = s.method AND ws.code = w.status_code
                        AND ws.category IN ('done', 'cancel') AND ws.deleted_at IS NULL);
  GET DIAGNOSTICS p_dipindah = ROW_COUNT;
  UPDATE sprints SET status = 'closed' WHERE id = p_sprint;
END $$;
