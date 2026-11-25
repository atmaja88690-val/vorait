/** Kode galat seragam (PRD GridBuilder §6). */
export const KODE_GALAT = {
  VALIDATION_FAILED: 422,
  BUSINESS_RULE: 422,
  CONFLICT: 409,
  VERSION_CONFLICT: 412,
  VERSION_REQUIRED: 428,
  NOT_FOUND: 404,
  LOCK_TIMEOUT: 423,
  QUERY_TIMEOUT: 503,
} as const;

export type KodeGalat = keyof typeof KODE_GALAT;

export interface BentukGalat {
  error: { code: KodeGalat; message: string; fields?: Record<string, string> };
}
