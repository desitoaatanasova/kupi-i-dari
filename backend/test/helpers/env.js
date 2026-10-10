'use strict';

require('dotenv').config();

process.env.NODE_ENV = process.env.NODE_ENV || 'test';
process.env.TZ = process.env.TZ || 'Europe/Sofia';
process.env.DB_NAME = process.env.DB_NAME_TEST || 'kupi_i_dari_test';
