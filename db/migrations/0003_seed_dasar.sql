-- 0003 — Data awal ds_monitoring (T-005). Dijalankan runner sebagai mon_schema.
-- Data karyawan/tim TIDAK di-seed: diisi Administrator lewat aplikasi (repo publik — nama orang tidak masuk repo).

-- Hari kerja Senin–Sabtu, Minggu libur (A6, D-5). ISO weekday: 1 = Senin … 7 = Minggu.
INSERT INTO ds_monitoring.work_calendar (weekday, is_workday) VALUES
  (1, true), (2, true), (3, true), (4, true), (5, true), (6, true), (7, false);

-- 7 kategori kalender (disetujui pengguna 26 Nov 2026). Bisa diubah Administrator lewat aplikasi.
INSERT INTO ds_monitoring.calendar_categories (code, name, kind, color_token, sort) VALUES
  ('kerja_proyek', 'Kerja proyek',        'work',     'navy',   1),
  ('rapat',        'Rapat',               'meeting',  'cyan',   2),
  ('insiden',      'Insiden/gangguan',    'incident', 'maroon', 3),
  ('piket',        'Piket/tugas rutin',   'duty',     'purple', 4),
  ('dukungan',     'Dukungan pengguna',   'work',     'lime',   5),
  ('pelatihan',    'Pelatihan',           'work',     'amber',  6),
  ('cuti',         'Cuti/izin',           'leave',    'slate',  7);
