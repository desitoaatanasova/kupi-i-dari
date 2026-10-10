'use strict';

const config = require('./config');

process.env.TZ = config.timezone;

const app = require('./app');

const server = app.listen(config.port, () => {
  console.log(
    `[server] Купи и Дари API listening on port ${config.port} ` +
      `(env=${config.env}, tz=${config.timezone})`
  );
});

function shutdown(signal) {
  console.log(`[server] received ${signal}, shutting down`);
  server.close(() => process.exit(0));
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

module.exports = server;
