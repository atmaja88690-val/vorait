import { z } from 'zod';

const Skema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('production'),
  PORT: z.coerce.number().int().min(1).max(65535).default(8320),
  HOST: z.string().default('127.0.0.1'),
});

export type Config = z.infer<typeof Skema>;

/** Gagal tertutup: env tidak valid = proses berhenti dengan pesan jelas. */
export function bacaConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const hasil = Skema.safeParse(env);
  if (!hasil.success) {
    throw new Error(`Konfigurasi tidak valid: ${hasil.error.issues.map((i) => i.path.join('.')).join(', ')}`);
  }
  return hasil.data;
}
