import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { ADMIN, PELAKU, siapkanDb, type DbUji } from './bantu.js';

/** T-006: trigger touch, audit, riwayat status, penjaga metode proyek, penjaga cuti (termasuk paralel). */
describe('T-006 trigger ds_monitoring', { skip: !ADMIN && 'UJI_PG_ADMIN_URL tidak diisi' }, () => {
  let d: DbUji;
  let app: pg.Client;
  const ids: Record<string, string> = {};

  /** Satu transaksi mon_app dengan pelaku terpasang, langsung COMMIT. */
  async function tulis(c: pg.Client, sql: string, p: unknown[] = []) {
    await c.query('BEGIN');
    try {
      await c.query(`SELECT set_config('app.user_id', $1, true), set_config('app.role', 'admin', true)`, [
        PELAKU,
      ]);
      const r = await c.query(sql, p);
      await c.query('COMMIT');
      return r;
    } catch (e) {
      await c.query('ROLLBACK');
      throw e;
    }
  }
  const audit = async (tabel: string, rowId: string) =>
    (
      await d.admin.query(
        `SELECT op, actor_id, changed, old_data, new_data FROM audit.data_changes
          WHERE table_name = $1 AND row_id = $2 ORDER BY id`,
        [`ds_monitoring.${tabel}`, rowId],
      )
    ).rows;

  before(async () => {
    d = await siapkanDb('uji_trg');
    app = d.sambung('mon_app');
    await app.connect();
    const one = async (sql: string, p: unknown[] = []) => (await tulis(app, sql, p)).rows[0].id as string;
    ids['tim'] = await one(
      `INSERT INTO ds_monitoring.teams(code,name) VALUES ('WEB','Web Dev') RETURNING id`,
    );
    ids['emp'] = await one(`INSERT INTO ds_monitoring.employees(full_name) VALUES ('Uji Satu') RETURNING id`);
    ids['tip'] = await one(
      `INSERT INTO ds_monitoring.item_types(team_id,code,name) VALUES ($1,'task','Tugas') RETURNING id`,
      [ids['tim']],
    );
    const kat = await d.admin.query(`SELECT code, id FROM ds_monitoring.calendar_categories`);
    for (const r of kat.rows) ids[`kat_${r.code}`] = r.id;
  });
  after(async () => {
    await app.end();
    await d.hapus();
  });

  test('semua 25 tabel punya trg_10_touch dan trg_90_audit', async () => {
    const r = await d.admin.query(
      `SELECT tgname, count(*)::int AS n FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relnamespace = 'ds_monitoring'::regnamespace AND tgname IN ('trg_10_touch','trg_90_audit')
        GROUP BY tgname ORDER BY tgname`,
    );
    assert.deepEqual(r.rows, [
      { tgname: 'trg_10_touch', n: 25 },
      { tgname: 'trg_90_audit', n: 25 },
    ]);
  });

  test('VR001: mon_app tanpa app.user_id ditolak; mon_schema (migrasi) diaudit dengan pelaku kosong', async () => {
    await assert.rejects(
      app.query(`INSERT INTO ds_monitoring.positions(name) VALUES ('Tanpa Pelaku')`),
      (e: unknown) => (e as { code?: string }).code === 'VR001',
    );
    const o = d.sambung('mon_owner');
    await o.connect();
    await o.query('BEGIN; SET LOCAL ROLE mon_schema;');
    const id = (
      await o.query(`INSERT INTO ds_monitoring.positions(name) VALUES ('Dari Migrasi') RETURNING id`)
    ).rows[0].id;
    await o.query('COMMIT');
    await o.end();
    const a = await audit('positions', id);
    assert.equal(a.length, 1);
    assert.equal(a[0].op, 'I');
    assert.equal(a[0].actor_id, null);
  });

  test('fn_touch: row_version naik, updated_by = pelaku, created_* dikunci', async () => {
    const r1 = (
      await tulis(
        app,
        `INSERT INTO ds_monitoring.positions(name, row_version, created_by) VALUES ('Teknisi', 99, gen_random_uuid()) RETURNING *`,
      )
    ).rows[0];
    assert.equal(r1.row_version, 1);
    assert.equal(r1.created_by, PELAKU);
    const r2 = (
      await tulis(
        app,
        `UPDATE ds_monitoring.positions SET name='Teknisi Senior', created_at='2000-01-01', row_version=7 WHERE id=$1 RETURNING *`,
        [r1.id],
      )
    ).rows[0];
    assert.equal(r2.row_version, 2);
    assert.equal(r2.updated_by, PELAKU);
    assert.deepEqual(r2.created_at, r1.created_at);
    assert.ok(r2.updated_at >= r1.updated_at);
    await assert.rejects(
      tulis(app, `UPDATE ds_monitoring.positions SET id=gen_random_uuid() WHERE id=$1`, [r1.id]),
      /id tidak boleh diubah/,
    );
  });

  test('fn_audit: INSERT penuh, UPDATE hanya kolom berubah, UPDATE tanpa perubahan nyata tidak dicatat', async () => {
    const id = (await tulis(app, `INSERT INTO ds_monitoring.positions(name) VALUES ('Analis') RETURNING id`))
      .rows[0].id;
    await tulis(app, `UPDATE ds_monitoring.positions SET name='Analis Sistem' WHERE id=$1`, [id]);
    await tulis(app, `UPDATE ds_monitoring.positions SET name='Analis Sistem' WHERE id=$1`, [id]);
    const a = await audit('positions', id);
    assert.deepEqual(
      a.map((x) => x.op),
      ['I', 'U'],
    );
    assert.equal(a[0].actor_id, PELAKU);
    assert.equal(a[0].new_data.name, 'Analis');
    assert.deepEqual(a[1].changed, ['name']);
    assert.deepEqual(a[1].old_data, { name: 'Analis' });
    assert.deepEqual(a[1].new_data, { name: 'Analis Sistem' });
  });

  test('riwayat status item & VR002 penjaga metode proyek', async () => {
    const prjBebas = (
      await tulis(
        app,
        `INSERT INTO ds_monitoring.projects(code,name,team_id,method) VALUES ('BEBAS','Bebas',$1,'scrum') RETURNING id`,
        [ids['tim']],
      )
    ).rows[0].id;
    await tulis(app, `UPDATE ds_monitoring.projects SET method='kanban' WHERE id=$1`, [prjBebas]);

    const prj = (
      await tulis(
        app,
        `INSERT INTO ds_monitoring.projects(code,name,team_id,method) VALUES ('WEB','Portal',$1,'scrum') RETURNING id`,
        [ids['tim']],
      )
    ).rows[0].id;
    const item = (
      await tulis(
        app,
        `INSERT INTO ds_monitoring.work_items(project_id,item_key,type_id,title,status_code,story_points) VALUES ($1,'WEB-1',$2,'uji','todo',3) RETURNING id`,
        [prj, ids['tip']],
      )
    ).rows[0].id;
    await tulis(app, `UPDATE ds_monitoring.work_items SET status_code='doing' WHERE id=$1`, [item]);
    await tulis(app, `UPDATE ds_monitoring.work_items SET title='uji 2' WHERE id=$1`, [item]);
    const h = await d.admin.query(
      `SELECT from_code, to_code, points, changed_by FROM ds_monitoring.work_item_status_history WHERE item_id=$1`,
      [item],
    );
    assert.deepEqual(h.rows, [{ from_code: 'todo', to_code: 'doing', points: 3, changed_by: PELAKU }]);
    // item 'doing' tidak dikenal sebagai backlog (todo) -> metode dikunci
    await assert.rejects(
      tulis(app, `UPDATE ds_monitoring.projects SET method='kanban' WHERE id=$1`, [prj]),
      (e: unknown) => (e as { code?: string }).code === 'VR002',
    );
    await tulis(
      app,
      `INSERT INTO ds_monitoring.sprints(project_id,name,start_date,end_date) VALUES ($1,'S1','2026-11-23','2026-12-04')`,
      [prjBebas],
    );
    await assert.rejects(
      tulis(app, `UPDATE ds_monitoring.projects SET method='scrum' WHERE id=$1`, [prjBebas]),
      (e: unknown) => (e as { code?: string }).code === 'VR002',
    );
  });

  const ev = `INSERT INTO ds_monitoring.calendar_events(employee_id,category_id,event_date,all_day,title) VALUES ($1,$2,$3,true,'uji') RETURNING id`;

  test('VR003: cuti dan kegiatan kerja di hari yang sama saling menolak; dibatalkan tidak dihitung', async () => {
    await tulis(app, ev, [ids['emp'], ids['kat_cuti'], '2026-12-01']);
    await assert.rejects(
      tulis(app, ev, [ids['emp'], ids['kat_kerja_proyek'], '2026-12-01']),
      (e: unknown) => (e as { code?: string }).code === 'VR003',
    );
    const kerja = (await tulis(app, ev, [ids['emp'], ids['kat_rapat'], '2026-12-02'])).rows[0].id;
    await assert.rejects(
      tulis(app, ev, [ids['emp'], ids['kat_cuti'], '2026-12-02']),
      (e: unknown) => (e as { code?: string }).code === 'VR003',
    );
    await tulis(app, `UPDATE ds_monitoring.calendar_events SET status='cancelled' WHERE id=$1`, [kerja]);
    await tulis(app, ev, [ids['emp'], ids['kat_cuti'], '2026-12-02']);
  });

  test('VR003 paralel: cuti dan kerja disimpan bersamaan → tepat satu berhasil', async () => {
    const a = d.sambung('mon_app');
    const b = d.sambung('mon_app');
    await a.connect();
    await b.connect();
    try {
      for (const c of [a, b]) {
        await c.query('BEGIN');
        await c.query(`SELECT set_config('app.user_id', $1, true), set_config('app.role', 'admin', true)`, [
          PELAKU,
        ]);
      }
      await a.query(ev, [ids['emp'], ids['kat_cuti'], '2026-12-03']); // A memegang kunci, belum COMMIT
      const pb = b.query(ev, [ids['emp'], ids['kat_kerja_proyek'], '2026-12-03']).then(
        () => 'ok',
        (e: { code?: string }) => e.code,
      ); // B menunggu kunci
      await new Promise((r) => setTimeout(r, 300));
      await a.query('COMMIT');
      assert.equal(await pb, 'VR003');
      await b.query('ROLLBACK');
    } finally {
      await a.end();
      await b.end();
    }
    const n = await d.admin.query(
      `SELECT count(*)::int AS n FROM ds_monitoring.calendar_events WHERE employee_id=$1 AND event_date='2026-12-03'`,
      [ids['emp']],
    );
    assert.equal(n.rows[0].n, 1);
  });
});
