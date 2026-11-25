#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import pg from 'pg';
import { GalatMigrasi, jalankanMigrasi, type Mode } from './migrate.js';

/**
 * Pemakaian:  MIGRATE_DATABASE_URL=postgresql://mon_owner:...@10.102.0.10:5432/vora_kegiatan \
 *             node db/dist/cli.js --cek | --terapkan
 * Keluar 0 = sukses, 1 = galat (pesan berawalan "MIGRASI GAGAL").
 */
async function utama(): Promise<number> {
  const arg = process.argv[2];
  const mode: Mode | undefined = arg === '--cek' ? 'cek' : arg === '--terapkan' ? 'terapkan' : undefined;
  if (!mode) {
    console.error('Pemakaian: node db/dist/cli.js --cek|--terapkan');
    return 2;
  }
  const url = process.env['MIGRATE_DATABASE_URL'];
  if (!url) {
    console.error('MIGRASI GAGAL: MIGRATE_DATABASE_URL tidak diisi');
    return 1;
  }
  const dir = process.env['MIGRATE_DIR'] ?? join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
  const c = new pg.Client({ connectionString: url, application_name: 'vora-migrate' });
  await c.connect();
  try {
    const r = await c.query<{ u: string; db: string }>('SELECT current_user AS u, current_database() AS db');
    console.info(
      `MIGRASI terhubung sebagai ${r.rows[0]?.u} ke ${r.rows[0]?.db}; mode ${mode}; folder ${dir}`,
    );
    const hasil = await jalankanMigrasi(c, dir, mode, (b) => console.info(b));
    console.info(
      `MIGRASI SELESAI diterapkan=${hasil.diterapkan.length} tertunda_awal=${hasil.tertunda.length}`,
    );
    return 0;
  } catch (e) {
    const pesan = e instanceof GalatMigrasi ? e.message : `TAK_TERDUGA: ${(e as Error).message}`;
    console.error(`MIGRASI GAGAL ${pesan}`);
    return 1;
  } finally {
    await c.end();
  }
}

utama().then(
  (kode) => process.exit(kode),
  (e: unknown) => {
    console.error(`MIGRASI GAGAL koneksi: ${(e as Error).message}`);
    process.exit(1);
  },
);
