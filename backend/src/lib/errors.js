'use strict';

// Application error compatible with the existing error middleware, which reads
// `err.status`, `err.code` and `err.message`. Responses are rendered as
// { "error": { "code": "...", "message": "..." } }.
class AppError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.code = code;
    Error.captureStackTrace(this, AppError);
  }
}

module.exports = { AppError };
