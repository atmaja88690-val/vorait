# db/

Migrasi SQL untuk skema `ds_monitoring` + peran DB (DCL). Runner `db/migrate.ts` dibuat di **T-003**.
Prisma (apps/api/prisma) hanya mengelola skema `auth`, `studio`, `audit` (D-3, terbukti di T-001).
