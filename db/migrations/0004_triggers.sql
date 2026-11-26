-- 0004 — Trigger ds_monitoring (Design §3.4, T-006). Dijalankan runner sebagai mon_schema.
-- Kode galat khusus (SQLSTATE kelas VR, dipetakan API ke pesan pengguna):
--   VR001 penulisan aplikasi tanpa app.user_id (audit wajib punya pelaku) — keputusan pengguna 26 Nov (A)
--   VR002 metode proyek tidak boleh diubah (sudah ada sprint / item di luar backlog)        — FR-14
--   VR003 cuti bentrok dengan kegiatan lain di hari yang sama (atau sebaliknya)              — FR-24a
-- Tabel baru buatan Builder WAJIB dipasangi trg_10_touch + trg_90_audit oleh pipa DDL (T-041+).

SET LOCAL search_path = ds_monitoring, public;  -- hanya untuk transaksi berkas ini
-- Setiap fungsi memasang search_path sendiri: mon_app memakai search_path bawaan ("$user", public).

-- Pelaku dari SET LOCAL app.user_id (NULL bila tidak dipasang). Uuid tidak sah -> galat (bukan diam-diam NULL).
CREATE FUNCTION fn_actor() RETURNS uuid
LANGUAGE sql STABLE SET search_path = ds_monitoring, pg_catalog AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

-- ───────────── fn_touch: stempel & versi baris (FR-7) ─────────────
CREATE FUNCTION fn_touch() RETURNS trigger
LANGUAGE plpgsql SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at  := now();
    NEW.updated_at  := NEW.created_at;
    NEW.created_by  := coalesce(fn_actor(), NEW.created_by);
    NEW.updated_by  := NEW.created_by;
    NEW.row_version := 1;
  ELSE
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'id tidak boleh diubah (%.%)', TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = 'check_violation';
    END IF;
    NEW.created_at  := OLD.created_at;
    NEW.created_by  := OLD.created_by;
    NEW.updated_at  := now();
    NEW.updated_by  := coalesce(fn_actor(), NEW.updated_by);
    NEW.row_version := OLD.row_version + 1;
  END IF;
  RETURN NEW;
END $$;

-- ───────────── fn_audit: jejak perubahan ke audit.data_changes (FR-6) ─────────────
-- UPDATE: hanya kolom yang berubah (di luar kolom stempel); UPDATE tanpa perubahan nyata tidak dicatat.
CREATE FUNCTION fn_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = ds_monitoring, pg_catalog AS $$
DECLARE
  pelaku uuid := fn_actor();
  o jsonb; n jsonb; k text; ubah text[] := '{}'; o2 jsonb := '{}'; n2 jsonb := '{}';
BEGIN
  IF pelaku IS NULL AND current_user = 'mon_app' THEN
    RAISE EXCEPTION 'penulisan % ditolak: app.user_id belum dipasang (SET LOCAL app.user_id)', TG_TABLE_NAME
      USING ERRCODE = 'VR001';
  END IF;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit.data_changes (actor_id, table_name, row_id, op, new_data)
    VALUES (pelaku, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, NEW.id, 'I', to_jsonb(NEW));
    RETURN NULL;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO audit.data_changes (actor_id, table_name, row_id, op, old_data)
    VALUES (pelaku, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, OLD.id, 'D', to_jsonb(OLD));
    RETURN NULL;
  END IF;
  o := to_jsonb(OLD); n := to_jsonb(NEW);
  FOR k IN SELECT jsonb_object_keys(n) LOOP
    CONTINUE WHEN k IN ('updated_at', 'updated_by', 'row_version');
    IF (o -> k) IS DISTINCT FROM (n -> k) THEN
      ubah := ubah || k; o2 := o2 || jsonb_build_object(k, o -> k); n2 := n2 || jsonb_build_object(k, n -> k);
    END IF;
  END LOOP;
  IF cardinality(ubah) > 0 THEN
    INSERT INTO audit.data_changes (actor_id, table_name, row_id, op, old_data, new_data, changed)
    VALUES (pelaku, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, NEW.id, 'U', o2, n2, ubah);
  END IF;
  RETURN NULL;
END $$;

-- ───────────── fn_item_status_history (FR-33) ─────────────
CREATE FUNCTION fn_item_status_history() RETURNS trigger
LANGUAGE plpgsql SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  INSERT INTO work_item_status_history (item_id, from_code, to_code, points, changed_by)
  VALUES (NEW.id, OLD.status_code, NEW.status_code, NEW.story_points, fn_actor());
  RETURN NULL;
END $$;

-- ───────────── fn_guard_project_method — lapis kedua FR-14 ─────────────
CREATE FUNCTION fn_guard_project_method() RETURNS trigger
LANGUAGE plpgsql SET search_path = ds_monitoring, pg_catalog AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM sprints WHERE project_id = NEW.id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'metode proyek % tidak bisa diubah: proyek sudah punya sprint', NEW.code USING ERRCODE = 'VR002';
  END IF;
  IF EXISTS (
    SELECT 1 FROM work_items w
      LEFT JOIN workflow_statuses s ON s.method = OLD.method AND s.code = w.status_code
     WHERE w.project_id = NEW.id AND w.deleted_at IS NULL AND coalesce(s.category, '?') <> 'todo'
  ) THEN
    RAISE EXCEPTION 'metode proyek % tidak bisa diubah: ada item di luar backlog', NEW.code USING ERRCODE = 'VR002';
  END IF;
  RETURN NEW;
END $$;

-- ───────────── fn_guard_leave — lapis kedua FR-24a ─────────────
-- Kunci per (karyawan, tanggal) agar dua transaksi paralel tidak sama-sama lolos.
-- Fungsi VOLATILE: pada READ COMMITTED tiap kueri di dalamnya memakai snapshot baru, jadi setelah
-- kunci didapat, baris yang baru di-commit transaksi lain ikut terlihat.
CREATE FUNCTION fn_guard_leave() RETURNS trigger
LANGUAGE plpgsql SET search_path = ds_monitoring, pg_catalog AS $$
DECLARE jenis text;
BEGIN
  IF NEW.deleted_at IS NOT NULL OR NEW.status = 'cancelled' THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(NEW.employee_id::text), NEW.event_date - DATE '2000-01-01');
  SELECT kind INTO jenis FROM calendar_categories WHERE id = NEW.category_id;
  IF jenis = 'leave' THEN
    IF EXISTS (
      SELECT 1 FROM calendar_events e JOIN calendar_categories c ON c.id = e.category_id
       WHERE e.employee_id = NEW.employee_id AND e.event_date = NEW.event_date AND e.id <> NEW.id
         AND e.deleted_at IS NULL AND e.status <> 'cancelled' AND c.kind <> 'leave'
    ) THEN
      RAISE EXCEPTION 'cuti pada % bentrok dengan kegiatan lain di hari itu', NEW.event_date USING ERRCODE = 'VR003';
    END IF;
  ELSIF EXISTS (
      SELECT 1 FROM calendar_events e JOIN calendar_categories c ON c.id = e.category_id
       WHERE e.employee_id = NEW.employee_id AND e.event_date = NEW.event_date AND e.id <> NEW.id
         AND e.deleted_at IS NULL AND e.status <> 'cancelled' AND c.kind = 'leave'
  ) THEN
    RAISE EXCEPTION 'kegiatan pada % bentrok dengan cuti di hari itu', NEW.event_date USING ERRCODE = 'VR003';
  END IF;
  RETURN NEW;
END $$;

-- ───────────── pemasangan ─────────────
-- Urutan nama = urutan eksekusi BEFORE: trg_10_touch dulu, lalu penjaga trg_20_*.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'ds_monitoring' AND tablename <> '_migrations' ORDER BY 1 LOOP
    EXECUTE format('CREATE TRIGGER trg_10_touch BEFORE INSERT OR UPDATE ON ds_monitoring.%I FOR EACH ROW EXECUTE FUNCTION ds_monitoring.fn_touch()', t);
    EXECUTE format('CREATE TRIGGER trg_90_audit AFTER INSERT OR UPDATE OR DELETE ON ds_monitoring.%I FOR EACH ROW EXECUTE FUNCTION ds_monitoring.fn_audit()', t);
  END LOOP;
END $$;

CREATE TRIGGER trg_20_guard_project_method BEFORE UPDATE OF method ON projects
  FOR EACH ROW WHEN (OLD.method IS DISTINCT FROM NEW.method) EXECUTE FUNCTION fn_guard_project_method();

CREATE TRIGGER trg_20_guard_leave BEFORE INSERT OR UPDATE OF category_id, event_date, employee_id, status, deleted_at
  ON calendar_events FOR EACH ROW EXECUTE FUNCTION fn_guard_leave();

CREATE TRIGGER trg_50_item_status_history AFTER UPDATE OF status_code ON work_items
  FOR EACH ROW WHEN (OLD.status_code IS DISTINCT FROM NEW.status_code) EXECUTE FUNCTION fn_item_status_history();
