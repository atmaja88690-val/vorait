import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { ADMIN, PELAKU, siapkanDb, type DbUji } from './bantu.js';

type Q = (sql: string, p?: unknown[]) => Promise<pg.QueryResult>;

/** T-007: function & procedure. Setiap uji di satu transaksi mon_app yang di-ROLLBACK. */
describe('T-007 function & procedure', { skip: !ADMIN && 'UJI_PG_ADMIN_URL tidak diisi' }, () => {
  let d: DbUji;
  let app: pg.Client;

  before(async () => {
    d = await siapkanDb('uji_fn');
    app = d.sambung('mon_app');
    await app.connect();
  });
  after(async () => {
    await app.end();
    await d.hapus();
  });

  async function uji(fn: (q: Q) => Promise<void>) {
    await app.query('BEGIN');
    await app.query(`SELECT set_config('app.user_id', $1, true), set_config('app.role', 'admin', true)`, [
      PELAKU,
    ]);
    try {
      await fn((sql, p) => app.query(sql, p));
    } finally {
      await app.query('ROLLBACK');
    }
  }
  const satu = async (q: Q, sql: string, p: unknown[] = []) => (await q(sql, p)).rows[0];
  const kat = async (q: Q, code: string) =>
    (await satu(q, `SELECT id FROM ds_monitoring.calendar_categories WHERE code=$1`, [code])).id as string;
  const karyawan = async (q: Q, nama: string) =>
    (await satu(q, `INSERT INTO ds_monitoring.employees(full_name) VALUES ($1) RETURNING id`, [nama]))
      .id as string;
  const kegiatan = async (q: Q, emp: string, k: string, tgl: string, o: Record<string, unknown> = {}) =>
    q(
      `INSERT INTO ds_monitoring.calendar_events(employee_id,category_id,event_date,all_day,start_min,duration_min,status,title)
       VALUES ($1,$2,$3,$4,$5,$6,$7,'uji')`,
      [
        emp,
        await kat(q, k),
        tgl,
        o['all_day'] ?? false,
        o['start_min'] ?? null,
        o['duration_min'] ?? null,
        o['status'] ?? 'plan',
      ],
    );

  test('fn_day_status: tabel kasus sesuai urutan prioritas', async () => {
    await uji(async (q) => {
      const e = await karyawan(q, 'Kasus');
      await q(`INSERT INTO ds_monitoring.holidays(holiday_date,name) VALUES ('2025-11-18','Libur uji')`);
      await kegiatan(q, e, 'cuti', '2025-11-17', { all_day: true }); // Senin cuti sepanjang hari
      await kegiatan(q, e, 'piket', '2025-11-13', { all_day: true }); // Kamis piket sepanjang hari
      await kegiatan(q, e, 'cuti', '2025-11-12', { all_day: true, status: 'cancelled' }); // dibatalkan → tidak dihitung
      await kegiatan(q, e, 'kerja_proyek', '2025-11-11', { start_min: 540, duration_min: 60 }); // kerja biasa
      await q(
        `INSERT INTO ds_monitoring.daily_logs(employee_id,log_date,today) VALUES ($1,'2025-11-19','x')`,
        [e],
      );
      const kasus: [string, string][] = [
        ['2025-11-23', 'non_workday'], // Minggu
        ['2025-11-22', 'missing'], // Sabtu = hari kerja (Senin–Sabtu)
        ['2025-11-18', 'holiday'],
        ['2025-11-17', 'excluded'], // cuti
        ['2025-11-13', 'excluded'], // piket sepanjang hari
        ['2025-11-12', 'missing'], // cuti dibatalkan
        ['2025-11-11', 'missing'], // ada kegiatan, tanpa standup
        ['2030-01-07', 'future'], // Senin di masa depan
        ['2025-11-19', 'filled'],
      ];
      for (const [tgl, harap] of kasus) {
        const r = await satu(q, `SELECT ds_monitoring.fn_day_status($1, $2) AS s`, [e, tgl]);
        assert.equal(r.s, harap, `${tgl}`);
      }
      // Libur di hari Minggu tetap non_workday (prioritas pertama)
      await q(`INSERT INTO ds_monitoring.holidays(holiday_date,name) VALUES ('2025-11-30','Libur Minggu')`);
      assert.equal(
        (await satu(q, `SELECT ds_monitoring.fn_day_status($1,'2025-11-30') AS s`, [e])).s,
        'non_workday',
      );
    });
  });

  test('fn_workdays, fn_log_compliance, fn_missing_logs', async () => {
    await uji(async (q) => {
      await q(`INSERT INTO ds_monitoring.holidays(holiday_date,name) VALUES ('2025-11-18','Libur uji')`);
      const hari = await q(`SELECT d::text FROM ds_monitoring.fn_workdays('2025-11-16','2025-11-23')`);
      assert.deepEqual(
        hari.rows.map((r) => r.d),
        ['2025-11-17', '2025-11-19', '2025-11-20', '2025-11-21', '2025-11-22'],
      );
      const a = await karyawan(q, 'Ani');
      const b = await karyawan(q, 'Budi');
      await q(`UPDATE ds_monitoring.employees SET is_active=false WHERE full_name='Budi'`);
      await kegiatan(q, a, 'cuti', '2025-11-17', { all_day: true });
      await q(
        `INSERT INTO ds_monitoring.daily_logs(employee_id,log_date) VALUES ($1,'2025-11-19'),($1,'2025-11-20')`,
        [a],
      );
      // Senin 23 cuti (excluded), Selasa 24 libur, Rabu–Kamis terisi, Jumat–Sabtu kosong, Minggu bukan hari kerja
      const k = await q(
        `SELECT full_name, wajib, terisi, persen::text FROM ds_monitoring.fn_log_compliance('2025-11-16','2025-11-22')`,
      );
      assert.deepEqual(k.rows, [{ full_name: 'Ani', wajib: 4, terisi: 2, persen: '50.0' }]);
      const m = await q(`SELECT employee_id FROM ds_monitoring.fn_missing_logs('2025-11-21')`);
      assert.deepEqual(
        m.rows.map((r) => r.employee_id),
        [a],
      );
      assert.equal(
        (await q(`SELECT count(*)::int AS n FROM ds_monitoring.fn_missing_logs('2025-11-23')`)).rows[0].n,
        0,
      );
      assert.ok(b);
      await assert.rejects(
        q(`SELECT * FROM ds_monitoring.fn_workdays('2026-01-01','2027-06-01')`),
        /rentang tanggal/,
      );
    });
  });

  test('fn_work_hours: hanya timed + done + kind ≠ leave', async () => {
    await uji(async (q) => {
      const e = await karyawan(q, 'Jam');
      await kegiatan(q, e, 'kerja_proyek', '2026-11-25', {
        start_min: 540,
        duration_min: 90,
        status: 'done',
      }); // dihitung
      await kegiatan(q, e, 'rapat', '2026-11-25', { start_min: 660, duration_min: 30, status: 'done' }); // dihitung
      await kegiatan(q, e, 'kerja_proyek', '2026-11-25', {
        start_min: 780,
        duration_min: 60,
        status: 'plan',
      }); // belum done
      await kegiatan(q, e, 'kerja_proyek', '2026-11-25', {
        start_min: 900,
        duration_min: 60,
        status: 'cancelled',
      });
      await kegiatan(q, e, 'pelatihan', '2026-11-26', { all_day: true, status: 'done' }); // sepanjang hari
      await kegiatan(q, e, 'cuti', '2026-11-27', { start_min: 480, duration_min: 120, status: 'done' }); // cuti berjam
      const r = await satu(
        q,
        `SELECT sum(menit)::int AS menit, sum(jam)::text AS jam FROM ds_monitoring.fn_work_hours('2026-11-01','2026-11-30') WHERE employee_id=$1`,
        [e],
      );
      assert.deepEqual(r, { menit: 120, jam: '2.00' });
    });
  });

  /** Proyek scrum dengan alur todo/doing/done/cancel, sprint aktif S1 & terencana S2, empat item. */
  async function sprintUji(q: Q) {
    await q(`INSERT INTO ds_monitoring.workflow_statuses(method,code,name,category,sort) VALUES
      ('scrum','todo','To Do','todo',1),('scrum','doing','Doing','doing',2),('scrum','done','Done','done',3),('scrum','batal','Batal','cancel',4)`);
    const tim = (
      await satu(q, `INSERT INTO ds_monitoring.teams(code,name) VALUES ('WEB','Web') RETURNING id`)
    ).id;
    const tip = (
      await satu(
        q,
        `INSERT INTO ds_monitoring.item_types(team_id,code,name) VALUES ($1,'task','Tugas') RETURNING id`,
        [tim],
      )
    ).id;
    const prj = (
      await satu(
        q,
        `INSERT INTO ds_monitoring.projects(code,name,team_id,method) VALUES ('WEB','Portal',$1,'scrum') RETURNING id`,
        [tim],
      )
    ).id;
    const s1 = (
      await satu(
        q,
        `INSERT INTO ds_monitoring.sprints(project_id,name,start_date,end_date,status) VALUES ($1,'S1',ds_monitoring.fn_today(),ds_monitoring.fn_today()+2,'active') RETURNING id`,
        [prj],
      )
    ).id;
    const s2 = (
      await satu(
        q,
        `INSERT INTO ds_monitoring.sprints(project_id,name,start_date,end_date) VALUES ($1,'S2',ds_monitoring.fn_today()+3,ds_monitoring.fn_today()+9) RETURNING id`,
        [prj],
      )
    ).id;
    const item = async (key: string, st: string, pts: number) =>
      (
        await satu(
          q,
          `INSERT INTO ds_monitoring.work_items(project_id,sprint_id,item_key,type_id,title,status_code,story_points) VALUES ($1,$2,$3,$4,'uji',$5,$6) RETURNING id`,
          [prj, s1, key, tip, st, pts],
        )
      ).id as string;
    return {
      prj,
      s1,
      s2,
      a: await item('WEB-1', 'done', 2),
      b: await item('WEB-2', 'doing', 3),
      c: await item('WEB-3', 'todo', 5),
      x: await item('WEB-4', 'batal', 8),
    };
  }

  test('fn_sprint_burndown: sisa poin per hari dari riwayat status', async () => {
    await uji(async (q) => {
      const s = await sprintUji(q);
      await q(`UPDATE ds_monitoring.work_items SET status_code='done' WHERE id=$1`, [s.b]); // riwayat hari ini
      const r = await q(`SELECT hari::text, sisa_poin FROM ds_monitoring.fn_sprint_burndown($1)`, [s.s1]);
      assert.equal(r.rows.length, 3);
      // Hanya WEB-3 (todo, 5 poin) yang tersisa; done & batal tidak dihitung
      assert.deepEqual(
        r.rows.map((x) => x.sisa_poin),
        [5, 5, 5],
      );
    });
  });

  test('sp_close_sprint: pindahkan item belum selesai, tutup sprint; rollback = tanpa sisa', async () => {
    let ids: Awaited<ReturnType<typeof sprintUji>> | undefined;
    await uji(async (q) => {
      ids = await sprintUji(q);
      const s = ids;
      await q('SAVEPOINT s');
      await assert.rejects(
        q(`CALL ds_monitoring.sp_close_sprint($1, $1, $2)`, [s.s1, PELAKU]),
        (e: { code?: string }) => e.code === 'VR004',
      );
      await q('ROLLBACK TO SAVEPOINT s');
      const r = await satu(q, `CALL ds_monitoring.sp_close_sprint($1, $2, $3)`, [s.s1, s.s2, PELAKU]);
      assert.equal(r.p_dipindah, 2);
      const it = await q(
        `SELECT item_key, sprint_id = $1 AS di_s2 FROM ds_monitoring.work_items ORDER BY item_key`,
        [s.s2],
      );
      assert.deepEqual(it.rows, [
        { item_key: 'WEB-1', di_s2: false },
        { item_key: 'WEB-2', di_s2: true },
        { item_key: 'WEB-3', di_s2: true },
        { item_key: 'WEB-4', di_s2: false },
      ]);
      assert.equal(
        (await satu(q, `SELECT status FROM ds_monitoring.sprints WHERE id=$1`, [s.s1])).status,
        'closed',
      );
      await q('SAVEPOINT t');
      await assert.rejects(
        q(`CALL ds_monitoring.sp_close_sprint($1, NULL, $2)`, [s.s1, PELAKU]),
        /hanya sprint aktif/,
      );
      await q('ROLLBACK TO SAVEPOINT t');
    });
    // Setelah ROLLBACK: tidak ada sprint, item, maupun audit tersisa
    const sisa = await d.admin.query(
      `SELECT (SELECT count(*) FROM ds_monitoring.sprints)::int AS sp, (SELECT count(*) FROM ds_monitoring.work_items)::int AS wi,
              (SELECT count(*) FROM audit.data_changes WHERE row_id = $1)::int AS au`,
      [ids?.s1],
    );
    assert.deepEqual(sisa.rows[0], { sp: 0, wi: 0, au: 0 });
  });

  test('mon_app bisa EXECUTE semua function/procedure; PUBLIC tidak', async () => {
    const r = await d.admin.query(
      `SELECT p.proname, has_function_privilege('mon_app', p.oid, 'EXECUTE') AS app,
              has_function_privilege('public', p.oid, 'EXECUTE') AS umum
         FROM pg_proc p WHERE p.pronamespace = 'ds_monitoring'::regnamespace ORDER BY 1`,
    );
    assert.ok(r.rows.length >= 15);
    assert.deepEqual(
      r.rows.filter((x) => !x.app || x.umum),
      [],
    );
  });
});
