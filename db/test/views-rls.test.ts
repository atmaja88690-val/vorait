import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { ADMIN, PELAKU, siapkanDb, type DbUji } from './bantu.js';

/** T-008: view laporan + RLS standup. Data uji di-COMMIT (DB uji khusus) agar bisa dibaca dari sesi lain. */
describe('T-008 view & RLS', { skip: !ADMIN && 'UJI_PG_ADMIN_URL tidak diisi' }, () => {
  let d: DbUji;
  let app: pg.Client;
  let rep: pg.Client;
  const id: Record<string, string> = {};
  const I = (k: string): string => {
    const v = id[k];
    if (!v) throw new Error(`id uji ${k} belum ada`);
    return v;
  };

  /** Transaksi mon_app dengan konteks peran. */
  async function sebagai<T>(
    peran: 'admin' | 'staff' | null,
    emp: string | null,
    fn: (c: pg.Client) => Promise<T>,
  ) {
    await app.query('BEGIN');
    await app.query(
      `SELECT set_config('app.user_id', $1, true), set_config('app.role', $2, true), set_config('app.employee_id', $3, true)`,
      [PELAKU, peran ?? '', emp ?? ''],
    );
    try {
      const r = await fn(app);
      await app.query('COMMIT');
      return r;
    } catch (e) {
      await app.query('ROLLBACK');
      throw e;
    }
  }

  before(async () => {
    d = await siapkanDb('uji_vrls');
    app = d.sambung('mon_app');
    rep = d.sambung('mon_report');
    await app.connect();
    await rep.connect();
    await sebagai('admin', null, async (c) => {
      const s = async (sql: string, p: unknown[] = []) => (await c.query(sql, p)).rows[0].id as string;
      id['a'] = await s(`INSERT INTO ds_monitoring.employees(full_name) VALUES ('Ani') RETURNING id`);
      id['b'] = await s(`INSERT INTO ds_monitoring.employees(full_name) VALUES ('Budi') RETURNING id`);
      const hari = `ds_monitoring.fn_today() - 1`;
      id['la'] = await s(
        `INSERT INTO ds_monitoring.daily_logs(employee_id,log_date,today,blockers) VALUES ($1,${hari},'kerja A','server A mati') RETURNING id`,
        [id['a']],
      );
      id['lb'] = await s(
        `INSERT INTO ds_monitoring.daily_logs(employee_id,log_date,today,blockers) VALUES ($1,${hari},'kerja B','akses B ditolak') RETURNING id`,
        [id['b']],
      );
      const tim = await s(`INSERT INTO ds_monitoring.teams(code,name) VALUES ('WEB','Web') RETURNING id`);
      const tip = await s(
        `INSERT INTO ds_monitoring.item_types(team_id,code,name) VALUES ($1,'task','Tugas') RETURNING id`,
        [tim],
      );
      const prj = await s(
        `INSERT INTO ds_monitoring.projects(code,name,team_id,method) VALUES ('WEB','Portal',$1,'scrum') RETURNING id`,
        [tim],
      );
      id['item'] = await s(
        `INSERT INTO ds_monitoring.work_items(project_id,item_key,type_id,title,status_code,assignee_id,due_date) VALUES ($1,'WEB-1',$2,'telat','todo',$3,'2025-01-10') RETURNING id`,
        [prj, tip, id['b']],
      );
      await c.query(
        `INSERT INTO ds_monitoring.daily_log_items(log_id,item_id,progress_to,note) VALUES ($1,$2,40,'rahasia B')`,
        [id['lb'], id['item']],
      );
      await c.query(
        `INSERT INTO ds_monitoring.log_comments(log_id,author_id,body) VALUES ($1,$2,'komentar untuk B')`,
        [id['lb'], PELAKU],
      );
    });
  });
  after(async () => {
    await app.end();
    await rep.end();
    await d.hapus();
  });

  test('RLS: Staf hanya melihat standup, rincian, dan komentar miliknya; Admin semua; tanpa konteks kosong', async () => {
    const hitung = (c: pg.Client) =>
      c.query(`SELECT (SELECT count(*) FROM ds_monitoring.daily_logs)::int AS logs,
                      (SELECT count(*) FROM ds_monitoring.daily_log_items)::int AS items,
                      (SELECT count(*) FROM ds_monitoring.log_comments)::int AS kom`);
    assert.deepEqual((await sebagai('staff', I('a'), hitung)).rows[0], { logs: 1, items: 0, kom: 0 });
    assert.deepEqual((await sebagai('staff', I('b'), hitung)).rows[0], { logs: 1, items: 1, kom: 1 });
    assert.deepEqual((await sebagai('admin', null, hitung)).rows[0], { logs: 2, items: 1, kom: 1 });
    assert.deepEqual((await sebagai(null, null, hitung)).rows[0], { logs: 0, items: 0, kom: 0 });
  });

  test('RLS: Staf tidak bisa menulis standup orang lain, bahkan dengan SQL langsung', async () => {
    await assert.rejects(
      sebagai('staff', I('a'), (c) =>
        c.query(`INSERT INTO ds_monitoring.daily_logs(employee_id,log_date) VALUES ($1, '2025-01-06')`, [
          id['b'],
        ]),
      ),
      /row-level security/,
    );
    const r = await sebagai('staff', I('a'), (c) =>
      c.query(`UPDATE ds_monitoring.daily_logs SET today='diubah A' WHERE id=$1`, [id['lb']]),
    );
    assert.equal(r.rowCount, 0); // baris B tidak terlihat → tidak berubah
    await assert.rejects(
      sebagai('staff', I('a'), (c) =>
        c.query(`INSERT INTO ds_monitoring.daily_log_items(log_id,item_id) VALUES ($1,$2)`, [
          id['lb'],
          id['item'],
        ]),
      ),
      /row-level security/,
    );
  });

  test('status hari tetap benar untuk rekan (hanya keberadaan, bukan isi)', async () => {
    const r = await sebagai('staff', I('a'), (c) =>
      c.query(`SELECT ds_monitoring.fn_day_status($1, ds_monitoring.fn_today() - 1) AS s`, [id['b']]),
    );
    const kemarin = await d.admin.query(
      `SELECT extract(isodow FROM ds_monitoring.fn_today() - 1)::int AS dow`,
    );
    assert.equal(r.rows[0].s, kemarin.rows[0].dow === 7 ? 'non_workday' : 'filled');
  });

  test('v_open_blockers: Staf hanya miliknya, Admin & mon_report semua', async () => {
    const nama = (rows: { full_name: string }[]) => rows.map((x) => x.full_name).sort();
    const q = `SELECT full_name FROM ds_monitoring.v_open_blockers`;
    assert.deepEqual(nama((await sebagai('staff', I('a'), (c) => c.query(q))).rows), ['Ani']);
    assert.deepEqual(nama((await sebagai('admin', null, (c) => c.query(q))).rows), ['Ani', 'Budi']);
    assert.deepEqual(nama((await rep.query(q)).rows), ['Ani', 'Budi']);
  });

  test('mon_report: SELECT semua view, tidak bisa membaca tabel', async () => {
    const v = await d.admin.query(
      `SELECT viewname FROM pg_views WHERE schemaname='ds_monitoring' ORDER BY 1`,
    );
    assert.deepEqual(
      v.rows.map((x) => x.viewname),
      [
        'v_board_items',
        'v_hours_recap',
        'v_last_activity',
        'v_open_blockers',
        'v_overdue_items',
        'v_pending_confirmation',
        'v_recap_daily',
        'v_recap_monthly',
        'v_recap_weekly',
        'v_team_calendar',
      ],
    );
    for (const { viewname } of v.rows) await rep.query(`SELECT * FROM ds_monitoring.${viewname} LIMIT 1`);
    await assert.rejects(rep.query(`SELECT * FROM ds_monitoring.daily_logs`), /permission denied/);
    await assert.rejects(rep.query(`SELECT * FROM ds_monitoring.employees`), /permission denied/);
    await assert.rejects(
      sebagai('admin', null, (c) => c.query(`UPDATE ds_monitoring.v_board_items SET title='x'`)),
      /permission denied|cannot update view/,
    );
  });

  test('isi view: item lewat target, rekap harian, kalender tim', async () => {
    const o = await rep.query(
      `SELECT item_key, terlambat_hari > 0 AS telat FROM ds_monitoring.v_overdue_items`,
    );
    assert.deepEqual(o.rows, [{ item_key: 'WEB-1', telat: true }]);
    const r = await rep.query(
      `SELECT full_name, project_code, item_lewat_target, hambatan, standup_terisi, progres_rata::text
         FROM ds_monitoring.v_recap_daily ORDER BY full_name, project_code NULLS LAST, tanggal`,
    );
    assert.deepEqual(r.rows, [
      {
        full_name: 'Ani',
        project_code: null,
        item_lewat_target: 0,
        hambatan: 1,
        standup_terisi: 1,
        progres_rata: null,
      },
      {
        full_name: 'Budi',
        project_code: 'WEB',
        item_lewat_target: 1,
        hambatan: 0,
        standup_terisi: 0,
        progres_rata: null,
      },
      {
        full_name: 'Budi',
        project_code: 'WEB',
        item_lewat_target: 0,
        hambatan: 0,
        standup_terisi: 0,
        progres_rata: '40.0',
      },
      {
        full_name: 'Budi',
        project_code: null,
        item_lewat_target: 0,
        hambatan: 1,
        standup_terisi: 1,
        progres_rata: null,
      },
    ]);
    const k = await rep.query(
      `SELECT count(*)::int AS n FROM ds_monitoring.v_team_calendar WHERE tanggal BETWEEN ds_monitoring.fn_today() - 6 AND ds_monitoring.fn_today()`,
    );
    assert.equal(k.rows[0].n, 14); // 2 karyawan × 7 hari
  });
});
