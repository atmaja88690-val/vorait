# vorait — Kegiatan Tim IT Vora

Monorepo (npm workspaces): `packages/shared`, `apps/api` (Express 4), `apps/ddl-worker`, `apps/web` (React 18 + Rsbuild + Tailwind 3.4), `db/` (migrasi SQL).

Spesifikasi: PRD v1.2, Design v1.1, Tasks v1.0 + Amandemen 01–02 (Project VR345).

```bash
npm ci
npm run typecheck && npm run lint && npm test
```

Rahasia tidak pernah masuk repo. Di server, sandi DB ada di `/etc/vora-kegiatan/` di dalam container `vora-kegiatan-app`.
