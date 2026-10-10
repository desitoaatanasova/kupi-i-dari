'use strict';

const express = require('express');
const config = require('../config');
const { ping } = require('../db');

const router = express.Router();

router.get('/', async (req, res) => {
  let database = 'ok';
  try {
    await ping();
  } catch (error) {
    database = 'error';
  }

  const healthy = database === 'ok';
  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'ok' : 'degraded',
    database,
    timezone: config.timezone,
  });
});

module.exports = router;
