import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Client } from 'pg';

/**
 * Runner migrasi SQL untuk skema ds_monitoring (T-003, FR-84, D-3).
 *
 * Aturan (gagal tertutup):
 *  - Nama berkas wajib `NNNN_nama.sql` (huruf kecil, angka, garis bawah). Berkas lain di folder = galat.
 *  - Berkas yang sudah diterapkan tidak boleh berubah (sha256) dan tidak boleh hilang.
 *  - Berkas baru tidak boleh bernomor lebih kecil dari migrasi terakhir yang sudah diterapkan.
 *  - Setiap berkas berjalan dalam SATU transaksi dengan SET LOCAL ROLE mon_schema; gagal = rollback penuh.
 *  - Hanya satu runner berjalan pada satu waktu (advisory lock).
 */

export const SKEMA = 'ds_monitoring';
export const PERAN_PEMILIK = 'mon_schema';
export const TABEL = `${SKEMA}._migrations`;
const POLA = /^(\d{4})_[a-z0-9_]+\.sql$/;
const KUNCI = 727_011; // advisory lock id khusus runner ini

export type Mode = 'cek' | 'terapkan';

export interface BerkasMigrasi {
  nama: string;
  sha256: string;
  sql: string;
}

export interface HasilMigrasi {
  sudah: string[];
  tertunda: string[];
  diterapkan: string[];
}

export class GalatMigrasi extends Error {
  constructor(
    readonly kode:
      | 'NAMA_TIDAK_SAH'
      | 'CHECKSUM_BERUBAH'
      | 'BERKAS_HILANG'
      | 'URUTAN'
      | 'TERKUNCI'
      | 'GAGAL_SQL',
    pesan: string,
  ) {
    super(`${kode}: ${pesan}`);
    this.name = 'GalatMigrasi';
  }
}

export function sha256(teks: string): string {
  return createHash('sha256').update(teks, 'utf8').digest('hex');
}

export async function bacaBerkas(dir: string): Promise<BerkasMigrasi[]> {
  const nama = (await readdir(dir)).filter((n) => !n.startsWith('.')).sort();
  const hasil: BerkasMigrasi[] = [];
  for (const n of nama) {
    if (!POLA.test(n))
      throw new GalatMigrasi('NAMA_TIDAK_SAH', `berkas "${n}" tidak sesuai pola NNNN_nama.sql`);
    const sql = await readFile(join(dir, n), 'utf8');
    hasil.push({ nama: n, sha256: sha256(sql), sql });
  }
  return hasil;
}

/** Bandingkan catatan DB dengan berkas. Murni (tanpa I/O) agar mudah diuji. */
export function rencanakan(
  berkas: BerkasMigrasi[],
  sudah: { nama: string; sha256: string }[],
): { tertunda: BerkasMigrasi[] } {
  const peta = new Map(berkas.map((b) => [b.nama, b]));
  for (const s of sudah) {
    const b = peta.get(s.nama);
    if (!b) throw new GalatMigrasi('BERKAS_HILANG', `${s.nama} sudah diterapkan tetapi berkasnya tidak ada`);
    if (b.sha256 !== s.sha256) {
      throw new GalatMigrasi('CHECKSUM_BERUBAH', `${s.nama} berubah setelah diterapkan (buat migrasi baru)`);
    }
  }
  const terakhir = sudah
    .map((s) => s.nama)
    .sort()
    .at(-1);
  const namaSudah = new Set(sudah.map((s) => s.nama));
  const tertunda = berkas.filter((b) => !namaSudah.has(b.nama));
  if (terakhir !== undefined) {
    const mundur = tertunda.find((b) => b.nama < terakhir);
    if (mundur) {
      throw new GalatMigrasi('URUTAN', `${mundur.nama} lebih kecil dari migrasi terakhir ${terakhir}`);
    }
  }
  return { tertunda };
}

async function tabelAda(c: Client): Promise<boolean> {
  const r = await c.query<{ ada: boolean }>('SELECT to_regclass($1) IS NOT NULL AS ada', [TABEL]);
  return r.rows[0]?.ada === true;
}

export async function jalankanMigrasi(
  c: Client,
  dir: string,
  mode: Mode,
  log: (baris: string) => void = () => undefined,
): Promise<HasilMigrasi> {
  const berkas = await bacaBerkas(dir);
  const kunci = await c.query<{ ok: boolean }>('SELECT pg_try_advisory_lock($1) AS ok', [KUNCI]);
  if (kunci.rows[0]?.ok !== true) throw new GalatMigrasi('TERKUNCI', 'runner migrasi lain sedang berjalan');
  try {
    if (mode === 'terapkan' && !(await tabelAda(c))) {
      await c.query('BEGIN');
      await c.query(`SET LOCAL ROLE ${PERAN_PEMILIK}`);
      await c.query(`CREATE TABLE ${TABEL} (
        nama            text PRIMARY KEY,
        sha256          char(64) NOT NULL,
        diterapkan_pada timestamptz NOT NULL DEFAULT now(),
        oleh            text NOT NULL DEFAULT session_user,
        durasi_ms       integer NOT NULL
      )`);
      await c.query(`REVOKE ALL ON ${TABEL} FROM mon_app`);
      await c.query('COMMIT');
      log(`MIGRASI tabel ${TABEL} dibuat`);
    }
    let sudah: { nama: string; sha256: string }[] = [];
    if (await tabelAda(c)) {
      // Tabel milik mon_schema; mon_owner tidak mewarisi hak (INHERIT FALSE) → baca lewat SET LOCAL ROLE.
      await c.query('BEGIN');
      try {
        await c.query(`SET LOCAL ROLE ${PERAN_PEMILIK}`);
        sudah = (
          await c.query<{ nama: string; sha256: string }>(`SELECT nama, sha256 FROM ${TABEL} ORDER BY nama`)
        ).rows;
        await c.query('COMMIT');
      } catch (e) {
        await c.query('ROLLBACK').catch(() => undefined);
        throw e;
      }
    }
    const { tertunda } = rencanakan(berkas, sudah);
    log(
      `MIGRASI sudah=${sudah.length} tertunda=${tertunda.length}${tertunda.length ? ' (' + tertunda.map((t) => t.nama).join(', ') + ')' : ''}`,
    );
    const diterapkan: string[] = [];
    if (mode === 'terapkan') {
      for (const b of tertunda) {
        const mulai = Date.now();
        try {
          await c.query('BEGIN');
          await c.query(`SET LOCAL ROLE ${PERAN_PEMILIK}`);
          await c.query(`SET LOCAL lock_timeout = '3s'`);
          await c.query(`SET LOCAL statement_timeout = '5min'`);
          await c.query(b.sql);
          await c.query(`INSERT INTO ${TABEL} (nama, sha256, durasi_ms) VALUES ($1, $2, $3)`, [
            b.nama,
            b.sha256,
            Date.now() - mulai,
          ]);
          await c.query('COMMIT');
        } catch (e) {
          await c.query('ROLLBACK').catch(() => undefined);
          throw new GalatMigrasi('GAGAL_SQL', `${b.nama}: ${(e as Error).message}`);
        }
        diterapkan.push(b.nama);
        log(`MIGRASI diterapkan ${b.nama} (${Date.now() - mulai} ms)`);
      }
    }
    return { sudah: sudah.map((s) => s.nama), tertunda: tertunda.map((t) => t.nama), diterapkan };
  } finally {
    await c.query('SELECT pg_advisory_unlock($1)', [KUNCI]).catch(() => undefined);
  }
}
