import { readFile, readdir } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { jalankanMigrasi } from '../src/migrate.js';

export const AKAR = join(dirname(fileURLToPath(import.meta.url)), '..');
const PRISMA_MIG = join(AKAR, '..', 'apps', 'api', 'prisma', 'migrations');
export const ADMIN = process.env['UJI_PG_ADMIN_URL'] ?? '';
const PW = (r: string) => process.env[`UJI_PW_${r.toUpperCase()}`] ?? `uji_${r}`;
const HOST = process.env['UJI_PG_HOST'] ?? '/tmp';
const PORT = Number(process.env['UJI_PG_PORT'] ?? 55432);

export interface DbUji {
  nama: string;
  admin: pg.Client; // superuser, tersambung ke DB uji
  sambung: (peran: string) => pg.Client;
  hapus: () => Promise<void>;
}

/**
 * DB uji yang meniru server: bootstrap superuser → SQL migrasi Prisma (sebagai mon_owner, seperti
 * `prisma migrate deploy`) → runner ds_monitoring. Prisma sendiri tidak dijalankan (engine tidak
 * tersedia di workspace); SQL-nya identik dengan yang diterapkan di server.
 */
export async function siapkanDb(awalan: string): Promise<DbUji> {
  const nama = `${awalan}_${process.pid}`;
  const induk = new pg.Client({ connectionString: ADMIN });
  await induk.connect();
  await induk.query(`DROP DATABASE IF EXISTS ${nama} WITH (FORCE)`);
  await induk.query(`CREATE DATABASE ${nama} OWNER mon_owner TEMPLATE template0`);
  const admin = new pg.Client({ connectionString: ADMIN.replace(/\/[^/?]*(\?|$)/, `/${nama}$1`) });
  await admin.connect();
  for (const f of ['00_superuser.sql', '01_ekstensi.sql']) {
    await admin.query(await readFile(join(AKAR, 'bootstrap', f), 'utf8'));
  }
  const sambung = (peran: string) =>
    new pg.Client({ host: HOST, port: PORT, database: nama, user: peran, password: PW(peran) });
  const o = sambung('mon_owner');
  await o.connect();
  await o.query('SET search_path = public');
  const dirs = (await readdir(PRISMA_MIG, { withFileTypes: true }))
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  for (const d of dirs) {
    await o.query('BEGIN');
    await o.query(await readFile(join(PRISMA_MIG, d, 'migration.sql'), 'utf8'));
    await o.query('COMMIT');
  }
  await o.query('RESET search_path');
  await jalankanMigrasi(o, join(AKAR, 'migrations'), 'terapkan');
  await o.end();
  return {
    nama,
    admin,
    sambung,
    hapus: async () => {
      await admin.end();
      await induk.query(`DROP DATABASE IF EXISTS ${nama} WITH (FORCE)`);
      await induk.end();
    },
  };
}

export const PELAKU = '11111111-1111-4111-8111-111111111111';
