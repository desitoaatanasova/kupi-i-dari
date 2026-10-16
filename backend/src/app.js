'use strict';

const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

const config = require('./config');
const healthRouter = require('./routes/health');
const authRouter = require('./routes/auth');
const adminRouter = require('./routes/admin');
const locationsRouter = require('./routes/locations');
const productsRouter = require('./routes/products');
const quantitiesRouter = require('./routes/quantities');
const shiftsRouter = require('./routes/shifts');
const { notFoundHandler, errorHandler } = require('./middleware/error-handler');

const app = express();

app.disable('x-powered-by');
app.set('trust proxy', 1);

app.use(helmet({ contentSecurityPolicy: false }));

const corsOptions = {
  origin(origin, callback) {
    if (!origin) return callback(null, true);
    if (config.corsOrigins.length === 0) {
      return callback(null, config.env !== 'production');
    }
    return callback(null, config.corsOrigins.includes(origin));
  },
};
app.use(cors(corsOptions));

app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false, limit: '1mb' }));

const apiLimiter = rateLimit({
  windowMs: config.rateLimit.windowMs,
  max: config.rateLimit.max,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use('/api', apiLimiter);

app.use('/api/health', healthRouter);
app.use('/api/auth', authRouter);
app.use('/api/admin', adminRouter);
app.use('/api/locations', locationsRouter);
app.use('/api/products', productsRouter);
app.use('/api/quantities', quantitiesRouter);
app.use('/api/shifts', shiftsRouter);

app.use(notFoundHandler);
app.use(errorHandler);

module.exports = app;
