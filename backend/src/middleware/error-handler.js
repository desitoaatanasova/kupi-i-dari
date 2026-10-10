'use strict';

const config = require('../config');

// eslint-disable-next-line no-unused-vars
function notFoundHandler(req, res, next) {
  res.status(404).json({
    error: { code: 'NOT_FOUND', message: 'Resource not found' },
  });
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  const status = Number.isInteger(err.status) ? err.status : 500;
  const code = err.code || (status === 500 ? 'INTERNAL_ERROR' : 'ERROR');
  const message =
    status === 500 && config.env === 'production'
      ? 'Internal server error'
      : err.message || 'Internal server error';

  if (status >= 500) {
    console.error(`[error] ${req.method} ${req.originalUrl}: ${err.message}`);
  }

  res.status(status).json({ error: { code, message } });
}

module.exports = { notFoundHandler, errorHandler };
