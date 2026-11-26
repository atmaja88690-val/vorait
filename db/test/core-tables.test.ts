import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { jalankanMigrasi } from '../src/migrate.js';

const AKAR = join(dirname(fileURLToPath(import.meta.url)), '..');
const ADMIN = process.env['UJI_PG_ADMIN_URL'] ?? '';
const PW = (r: string) => process.env[`UJI_PW_${r.toUpperCase()}`] ?? `uji_${r}`;

/** T-005: tabel inti ds_monitoring — bentuk, batasan, seed, hak mon_app. Semua tulis uji di-ROLLBACK. */
describe('T-005 tabel inti ds_monitoring', { skip: !ADMIN && 'UJI_PG_ADMIN_URL tidak diisi' }, () => {
  const db = `uji_inti_${process.pid}`;
  const host = process.env['UJI_PG_HOST'] ?? '/tmp';
  const port = Number(process.env['UJI_PG_PORT'] ?? 55432);
  const sambung = (user: string) => new pg.Client({ host, port, database: db, user, password: PW(user) });
  let admin: pg.Client;
  let app: pg.Client;

  before(async () => {
    admin = new pg.Client({ connectionString: ADMIN });
    await admin.connect();
    await admin.query(`CREATE DATABASE ${db} OWNER mon_owner TEMPLATE template0`);
    const a2 = new pg.Client({ connectionString: ADMIN.replace(/\/[^/?]*(\?|$)/, `/${db}$1`) });
    await a2.connect();
    await a2.query(await readFile(join(AKAR, 'bootstrap', '00_superuser.sql'), 'utf8'));
    await a2.end();
    const o = sambung('mon_owner');
    await o.connect();
    await jalankanMigrasi(o, join(AKAR, 'migrations'), 'terapkan');
    await o.end();
    app = sambung('mon_app');
    await app.connect();
  });
  after(async () => {
    await app.end();
    await admin.query(`DROP DATABASE IF EXISTS ${db} WITH (FORCE)`);
    await admin.end();
  });

  /** Jalankan fn di transaksi mon_app yang selalu di-ROLLBACK. */
  async function uji(fn: (q: (sql: string, p?: unknown[]) => Promise<pg.QueryResult>) => Promise<void>) {
    await app.query('BEGIN');
    try {
      await fn((sql, p) => app.query(sql, p));
    } finally {
      await app.query('ROLLBACK');
    }
  }
  /** Pernyataan harus ditolak; transaksi tetap hidup lewat SAVEPOINT. */
  async function ditolak(
    q: (s: string, p?: unknown[]) => Promise<pg.QueryResult>,
    sql: string,
    pola: RegExp,
    p?: unknown[],
  ) {
    await q('SAVEPOINT s');
    await assert.rejects(q(sql, p), pola);
    await q('ROLLBACK TO SAVEPOINT s');
  }
  /** Data induk minimal: tim, karyawan, kategori kerja, proyek, tipe item. */
  async function induk(q: (s: string, p?: unknown[]) => Promise<pg.QueryResult>) {
    const tim = (await q(`INSERT INTO ds_monitoring.teams(code,name) VALUES ('WEB','Web Dev') RETURNING id`))
      .rows[0].id;
    const emp = (await q(`INSERT INTO ds_monitoring.employees(full_name) VALUES ('Uji Satu') RETURNING id`))
      .rows[0].id;
    const kat = (await q(`SELECT id FROM ds_monitoring.calendar_categories WHERE code='kerja_proyek'`))
      .rows[0].id;
    const prj = (
      await q(
        `INSERT INTO ds_monitoring.projects(code,name,team_id,method) VALUES ('WEB','Portal',$1,'scrum') RETURNING id`,
        [tim],
      )
    ).rows[0].id;
    const tip = (
      await q(
        `INSERT INTO ds_monitoring.item_types(team_id,code,name) VALUES ($1,'task','Tugas') RETURNING id`,
        [tim],
      )
    ).rows[0].id;
    return { tim, emp, kat, prj, tip };
  }

  test('25 tabel, semua milik mon_schema, semua punya kolom standar', async () => {
    const r = await app.query(
      `SELECT count(*)::int AS n, count(*) FILTER (WHERE tableowner <> 'mon_schema')::int AS bukan
         FROM pg_tables WHERE schemaname='ds_monitoring' AND tablename <> '_migrations'`,
    );
    assert.deepEqual(r.rows[0], { n: 25, bukan: 0 });
    const kurang = await app.query(
      `SELECT t.tablename FROM pg_tables t WHERE t.schemaname='ds_monitoring' AND t.tablename <> '_migrations'
         AND (SELECT count(*) FROM information_schema.columns c WHERE c.table_schema='ds_monitoring' AND c.table_name=t.tablename
              AND c.column_name IN ('id','created_at','created_by','updated_at','updated_by','deleted_at','row_version')) <> 7`,
    );
    assert.deepEqual(kurang.rows, []);
  });

  test('semua FK ON DELETE RESTRICT', async () => {
    const r = await app.query(
      `SELECT count(*)::int AS n, count(*) FILTER (WHERE confdeltype <> 'r')::int AS bukan
         FROM pg_constraint WHERE contype='f' AND connamespace='ds_monitoring'::regnamespace`,
    );
    assert.ok(r.rows[0].n >= 25);
    assert.equal(r.rows[0].bukan, 0);
  });

  test('seed: hari kerja Senin–Sabtu, Minggu libur; 7 kategori', async () => {
    const h = await app.query(
      `SELECT string_agg(weekday||':'||is_workday, ',' ORDER BY weekday) AS s FROM ds_monitoring.work_calendar`,
    );
    assert.equal(h.rows[0].s, '1:true,2:true,3:true,4:true,5:true,6:true,7:false');
    const k = await app.query(
      `SELECT string_agg(code||'='||kind, ',' ORDER BY sort) AS s FROM ds_monitoring.calendar_categories`,
    );
    assert.equal(
      k.rows[0].s,
      'kerja_proyek=work,rapat=meeting,insiden=incident,piket=duty,dukungan=work,pelatihan=work,cuti=leave',
    );
  });

  test('bentuk waktu kegiatan: timed 23:30+60 ditolak, all_day dengan jam ditolak, yang sah diterima', async () => {
    await uji(async (q) => {
      const { emp, kat } = await induk(q);
      const sisip = `INSERT INTO ds_monitoring.calendar_events(employee_id,category_id,event_date,all_day,start_min,duration_min,title)
                     VALUES ($1,$2,'2026-11-26',$3,$4,$5,'uji')`;
      const pola = /calendar_events_bentuk_waktu/;
      await ditolak(q, sisip, pola, [emp, kat, false, 1410, 60]); // 23:30 + 60 menit melewati tengah malam
      await ditolak(q, sisip, pola, [emp, kat, true, 540, null]); // all_day dengan start_min
      await ditolak(q, sisip, pola, [emp, kat, false, 545, 60]); // bukan kelipatan 15
      await ditolak(q, sisip, pola, [emp, kat, false, 540, 0]); // durasi < 15
      await ditolak(q, sisip, pola, [emp, kat, false, null, null]); // timed tanpa jam
      await q(sisip, [emp, kat, false, 1380, 60]); // 23:00–24:00 sah
      await q(sisip, [emp, kat, true, null, null]); // sepanjang hari sah
    });
  });

  test('satu sprint aktif per proyek; story points & progres dibatasi; standup unik per hari', async () => {
    await uji(async (q) => {
      const { emp, prj, tip } = await induk(q);
      const sp = `INSERT INTO ds_monitoring.sprints(project_id,name,start_date,end_date,status) VALUES ($1,$2,'2026-11-23','2026-12-04',$3)`;
      await q(sp, [prj, 'S1', 'active']);
      await ditolak(q, sp, /sprints_satu_aktif_per_proyek/, [prj, 'S2', 'active']);
      await q(sp, [prj, 'S3', 'planned']);
      const wi = `INSERT INTO ds_monitoring.work_items(project_id,item_key,type_id,title,status_code,story_points,progress) VALUES ($1,$2,$3,'uji','todo',$4,$5)`;
      await ditolak(q, wi, /story_points/, [prj, 'WEB-1', tip, 4, 0]);
      await ditolak(q, wi, /progress/, [prj, 'WEB-1', tip, 3, 101]);
      await q(wi, [prj, 'WEB-1', tip, 3, 50]);
      await ditolak(q, wi, /work_items_item_key_key/, [prj, 'WEB-1', tip, 3, 50]);
      const dl = `INSERT INTO ds_monitoring.daily_logs(employee_id,log_date,blockers) VALUES ($1,'2026-11-26',$2) RETURNING has_blocker`;
      assert.equal((await q(dl, [emp, '   '])).rows[0].has_blocker, false);
      await ditolak(q, dl, /daily_logs_employee_id_log_date_key/, [emp, 'server mati']);
    });
  });

  test('catatan wajib tepat satu induk; FK ditegakkan; mon_app tidak bisa DELETE atau DDL', async () => {
    await uji(async (q) => {
      const { prj } = await induk(q);
      await ditolak(q, `INSERT INTO ds_monitoring.notes(title) VALUES ('yatim')`, /notes_check/);
      await q(`INSERT INTO ds_monitoring.notes(project_id,title) VALUES ($1,'ok')`, [prj]);
      await ditolak(
        q,
        `INSERT INTO ds_monitoring.team_members(team_id,employee_id) VALUES (gen_random_uuid(), gen_random_uuid())`,
        /foreign key/,
      );
      await ditolak(q, `DELETE FROM ds_monitoring.projects`, /permission denied/);
      await ditolak(q, `ALTER TABLE ds_monitoring.projects ADD COLUMN x_liar text`, /must be owner/);
    });
  });
});
