import express from 'express';
import { APP_TZ, hariIni } from '@vorait/shared';
import { bacaConfig } from './config.js';

const config = bacaConfig();
const app = express();
app.disable('x-powered-by');

app.get('/api/health', (_req, res) => {
  res.json({ ok: true, app: 'Kegiatan Tim IT Vora', tz: APP_TZ, hariIni: hariIni() });
});

app.listen(config.PORT, config.HOST, () => {
  console.info(`[api] mendengarkan http://${config.HOST}:${config.PORT}`);
});
