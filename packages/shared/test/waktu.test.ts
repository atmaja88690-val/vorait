import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tanggalDi, selisihHari } from '../src/waktu.js';

test('tengah malam WITA: 16:30 UTC sudah berganti hari di Asia/Makassar', () => {
  assert.equal(tanggalDi(new Date('2026-11-25T16:30:00Z')), '2026-11-26');
  assert.equal(tanggalDi(new Date('2026-11-25T15:59:00Z')), '2026-11-25');
});

test('selisihHari menghitung hari kalender', () => {
  assert.equal(selisihHari('2026-11-18', '2026-11-25'), 7);
  assert.equal(selisihHari('2026-11-25', '2026-11-25'), 0);
  assert.throws(() => selisihHari('x', '2026-11-25'));
});
