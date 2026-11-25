# ADR 0001 — Stack terkunci (hasil T-001, 25 Nov 2026)

| Komponen | Versi | Bukti |
|---|---|---|
| Node.js | 22.23.5 (container `vora-kegiatan-app`, NodeSource) | `node -v` di container |
| PostgreSQL | 16.15 (Ubuntu 24.04, container `vora-kegiatan-db`) | `pg_lsclusters` |
| Prisma / @prisma/client | 6.19.3, `multiSchema` = auth, studio, audit | vora-step02: deploy OK, drift exit 0 dua kali, Client OK |
| Rsbuild + plugin-react | 1.7.6 + 1.4.6 | build lolos di workspace |
| React | 18.3.1 | build lolos |
| Tailwind CSS | 3.4.19 via PostCSS | kelas kustom ter-build |
| TypeScript | 5.6.3 | `npm run typecheck` |

Catatan:
- Engine Prisma hanya bisa diunduh dari container app → `prisma migrate diff` / `prisma generate` dijalankan di container.
- Infrastruktur: bsiint03, Incus, pool `vora` di HDD `/dev/sda2`, jaringan `vorabr0` 10.102.0.0/24. Disk root TIDAK dipakai.
