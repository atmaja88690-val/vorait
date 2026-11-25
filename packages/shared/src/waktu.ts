/** Zona waktu aplikasi (FR-73). "Hari ini" selalu dihitung di sini, bukan di jam peramban/host. */
export const APP_TZ = 'Asia/Makassar';

/** Tanggal kalender (YYYY-MM-DD) di zona aplikasi untuk sebuah instan. */
export function tanggalDi(instan: Date, tz: string = APP_TZ): string {
  const p = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  return p.format(instan);
}

export function hariIni(sekarang: Date = new Date()): string {
  return tanggalDi(sekarang);
}

/** Selisih hari kalender b - a (keduanya YYYY-MM-DD). */
export function selisihHari(a: string, b: string): number {
  const ms = Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`);
  if (Number.isNaN(ms)) throw new Error(`Tanggal tidak valid: ${a} / ${b}`);
  return Math.round(ms / 86_400_000);
}
