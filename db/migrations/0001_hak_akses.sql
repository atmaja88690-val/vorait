-- T-003 · Hak bawaan untuk semua objek yang nanti dibuat mon_schema di ds_monitoring (Design §3.6).
-- Runner menjalankan berkas ini dengan SET LOCAL ROLE mon_schema di dalam satu transaksi.

-- Tabel: aplikasi boleh baca/tambah/ubah. DELETE TIDAK diberikan bawaan (hapus = lunak via deleted_at);
-- tabel yang memang butuh DELETE diberi hak eksplisit di migrasinya sendiri.
ALTER DEFAULT PRIVILEGES FOR ROLE mon_schema IN SCHEMA ds_monitoring
  GRANT SELECT, INSERT, UPDATE ON TABLES TO mon_app;
ALTER DEFAULT PRIVILEGES FOR ROLE mon_schema IN SCHEMA ds_monitoring
  GRANT USAGE, SELECT ON SEQUENCES TO mon_app;

-- Fungsi/prosedur: tutup dari PUBLIC, buka hanya untuk aplikasi.
ALTER DEFAULT PRIVILEGES FOR ROLE mon_schema REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE mon_schema IN SCHEMA ds_monitoring
  GRANT EXECUTE ON ROUTINES TO mon_app;

COMMENT ON SCHEMA ds_monitoring IS
  'Data aplikasi Kegiatan Tim IT Vora. Dikelola runner SQL + Builder; Prisma TIDAK mengelola skema ini (D-3).';
