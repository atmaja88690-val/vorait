import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, cp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { GalatMigrasi, jalankanMigrasi, rencanakan, sha256 } from '../src/migrate.js';

const AKAR = join(dirname(fileURLToPath(import.meta.url)), '..');

describe('rencanakan (tanpa DB)', () => {
  const b = (nama: string, isi = nama) => ({ nama, sha256: sha256(isi), sql: isi });

  test('semua berkas baru = tertunda', () => {
    assert.deepEqual(
      rencanakan([b('0001_a.sql'), b('0002_b.sql')], []).tertunda.map((t) => t.nama),
      ['0001_a.sql', '0002_b.sql'],
    );
  });
  test('checksum berubah ditolak', () => {
    assert.throws(
      () => rencanakan([b('0001_a.sql', 'baru')], [{ nama: '0001_a.sql', sha256: sha256('lama') }]),
      (e: unknown) => e instanceof GalatMigrasi && e.kode === 'CHECKSUM_BERUBAH',
    );
  });
  test('berkas yang sudah diterapkan hilang ditolak', () => {
    assert.throws(
      () => rencanakan([], [{ nama: '0001_a.sql', sha256: 'x' }]),
      (e: unknown) => e instanceof GalatMigrasi && e.kode === 'BERKAS_HILANG',
    );
  });
  test('berkas baru bernomor lebih kecil dari terakhir ditolak', () => {
    const s = b('0002_b.sql');
    assert.throws(
      () => rencanakan([b('0001_a.sql'), s], [{ nama: s.nama, sha256: s.sha256 }]),
      (e: unknown) => e instanceof GalatMigrasi && e.kode === 'URUTAN',
    );
  });
});

/** Uji integrasi butuh PostgreSQL 16 + bootstrap (UJI_PG_ADMIN_URL = superuser, UJI_PG_HOST/PORT). */
const ADMIN = process.env['UJI_PG_ADMIN_URL'] ?? '';
const PW = (r: string) => process.env[`UJI_PW_${r.toUpperCase()}`] ?? `uji_${r}`;

describe('runner + DCL di PostgreSQL nyata', { skip: !ADMIN && 'UJI_PG_ADMIN_URL tidak diisi' }, () => {
  const db = `uji_vora_${process.pid}`;
  const host = process.env['UJI_PG_HOST'] ?? '/tmp';
  const port = Number(process.env['UJI_PG_PORT'] ?? 55432);
  const sambung = (user: string) => new pg.Client({ host, port, database: db, user, password: PW(user) });
  let admin: pg.Client;

  before(async () => {
    admin = new pg.Client({ connectionString: ADMIN });
    await admin.connect();
    await admin.query(`CREATE DATABASE ${db} OWNER mon_owner TEMPLATE template0`);
    const a2 = new pg.Client({ connectionString: ADMIN.replace(/\/[^/?]*(\?|$)/, `/${db}$1`) });
    await a2.connect();
    await a2.query(`REVOKE CREATE ON SCHEMA public FROM PUBLIC`);
    await a2.query(await readFile(join(AKAR, 'bootstrap', '00_superuser.sql'), 'utf8'));
    await a2.query(await readFile(join(AKAR, 'bootstrap', '00_superuser.sql'), 'utf8')); // idempoten
    await a2.end();
  });
  after(async () => {
    await admin.query(`DROP DATABASE IF EXISTS ${db} WITH (FORCE)`);
    await admin.end();
  });

  test('cek tidak membuat apa pun; terapkan sekali; ulang = 0 tertunda', async () => {
    const c = sambung('mon_owner');
    await c.connect();
    const h1 = await jalankanMigrasi(c, join(AKAR, 'migrations'), 'cek');
    assert.deepEqual(h1.tertunda, ['0001_hak_akses.sql']);
    const ada = await c.query(`SELECT to_regclass('ds_monitoring._migrations') AS t`);
    assert.equal(ada.rows[0].t, null);
    const h2 = await jalankanMigrasi(c, join(AKAR, 'migrations'), 'terapkan');
    assert.deepEqual(h2.diterapkan, ['0001_hak_akses.sql']);
    const h3 = await jalankanMigrasi(c, join(AKAR, 'migrations'), 'terapkan');
    assert.deepEqual(h3.diterapkan, []);
    await c.end();
  });

  test('berkas diubah setelah diterapkan ditolak', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'mig-'));
    await cp(join(AKAR, 'migrations'), dir, { recursive: true });
    await writeFile(join(dir, '0001_hak_akses.sql'), '-- diubah\n', { flag: 'a' });
    const c = sambung('mon_owner');
    await c.connect();
    await assert.rejects(
      jalankanMigrasi(c, dir, 'cek'),
      (e: unknown) => (e as GalatMigrasi).kode === 'CHECKSUM_BERUBAH',
    );
    await c.end();
  });

  test('migrasi gagal di tengah di-rollback penuh dan tidak tercatat', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'mig-'));
    await cp(join(AKAR, 'migrations'), dir, { recursive: true });
    await writeFile(
      join(dir, '0002_rusak.sql'),
      'CREATE TABLE ds_monitoring.uji_rusak(id int);\nSELECT 1/0;\n',
    );
    const c = sambung('mon_owner');
    await c.connect();
    await assert.rejects(
      jalankanMigrasi(c, dir, 'terapkan'),
      (e: unknown) => (e as GalatMigrasi).kode === 'GAGAL_SQL',
    );
    const t = await c.query(`SELECT to_regclass('ds_monitoring.uji_rusak') AS t`);
    assert.equal(t.rows[0].t, null);
    await c.query('BEGIN; SET LOCAL ROLE mon_schema;');
    const n = await c.query(
      `SELECT count(*)::int AS n FROM ds_monitoring._migrations WHERE nama = '0002_rusak.sql'`,
    );
    await c.query('COMMIT');
    assert.equal(n.rows[0].n, 0);
    await c.end();
  });

  test('DCL: objek milik mon_schema; mon_app baca/tambah/ubah tapi tidak hapus & tidak buat objek', async () => {
    const o = sambung('mon_owner');
    await o.connect();
    await o.query(
      'BEGIN; SET LOCAL ROLE mon_schema; CREATE TABLE ds_monitoring.uji_hak(id int PRIMARY KEY, v text); COMMIT;',
    );
    const pemilik = await o.query(
      `SELECT tableowner FROM pg_tables WHERE schemaname='ds_monitoring' AND tablename='uji_hak'`,
    );
    assert.equal(pemilik.rows[0].tableowner, 'mon_schema');
    // mon_owner TIDAK mewarisi hak mon_schema tanpa SET ROLE (INHERIT FALSE)
    await assert.rejects(o.query('DELETE FROM ds_monitoring.uji_hak'));
    await o.end();

    const a = sambung('mon_app');
    await a.connect();
    await a.query(`INSERT INTO ds_monitoring.uji_hak VALUES (1, 'a')`);
    await a.query(`UPDATE ds_monitoring.uji_hak SET v = 'b' WHERE id = 1`);
    assert.equal((await a.query('SELECT v FROM ds_monitoring.uji_hak')).rows[0].v, 'b');
    await assert.rejects(a.query('DELETE FROM ds_monitoring.uji_hak'), /permission denied/);
    await assert.rejects(a.query('CREATE TABLE ds_monitoring.liar(id int)'), /permission denied/);
    await assert.rejects(a.query('CREATE TABLE public.liar(id int)'), /permission denied/);
    await assert.rejects(a.query('SELECT * FROM ds_monitoring._migrations'), /permission denied/);
    const to = await a.query(`SHOW statement_timeout`);
    assert.equal(to.rows[0].statement_timeout, '15s');
    await a.end();
  });
});
