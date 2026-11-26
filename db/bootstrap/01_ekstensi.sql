-- Bootstrap 01 — dijalankan SEKALI sebagai superuser postgres di DB vora_kegiatan (idempoten).
-- citext untuk auth.users.email (perbandingan tanpa beda huruf besar/kecil). Dipasang di public;
-- Prisma TIDAK mengelola ekstensi (tanpa preview postgresqlExtensions).
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
