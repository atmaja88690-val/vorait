-- T-006 migrasi kustom (ditulis tangan), keputusan pengguna 26 Nov 2026 (pilihan A):
-- penulisan oleh migrasi/seed (runner, peran mon_schema) tetap diaudit dengan pelaku kosong.
-- fn_audit berjalan dengan hak pemanggil, jadi mon_schema butuh INSERT ke audit.data_changes.
-- Hanya INSERT: mon_schema tidak bisa membaca, mengubah, atau menghapus jejak audit.
GRANT USAGE ON SCHEMA audit TO mon_schema;
GRANT INSERT ON audit.data_changes TO mon_schema;
GRANT USAGE ON SEQUENCE audit.data_changes_id_seq TO mon_schema;
