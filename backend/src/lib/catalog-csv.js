'use strict';

const { TextDecoder } = require('util');

const HEADERS = Object.freeze([
  'category',
  'product_name',
  'variant_label',
  'unit_value',
  'unit_type',
  'source_label',
]);

// Mirrors the existing product validators and schema limits.
const LIMITS = Object.freeze({
  categoryMax: 80,
  productNameMax: 120,
  variantLabelMax: 40,
  unitValueMax: 9999999.999,
  unitValuePlaces: 3,
});

const CORRUPTED_TEXT = /[\uFFFD\u0000]/;
const CONTROL_CHARACTERS = /[\u0001-\u0008\u000B\u000C\u000E-\u001F\u007F]/;

function normalizeText(value) {
  return String(value).trim().replace(/\s+/g, ' ');
}

function decodeUtf8(input) {
  if (typeof input === 'string') return input;
  if (!Buffer.isBuffer(input)) {
    throw new Error('CSV input must be a string or a Buffer.');
  }

  // Fatal decoding rejects malformed UTF-8 instead of silently inserting
  // replacement characters. The BOM, if present, is stripped below.
  const decoder = new TextDecoder('utf-8', { fatal: true });
  try {
    return decoder.decode(input);
  } catch (error) {
    const decodeError = new Error('CSV file is not valid UTF-8.');
    decodeError.code = 'INVALID_ENCODING';
    throw decodeError;
  }
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function parseCsvRecords(text) {
  const errors = [];
  const warnings = [];
  const records = [];

  let field = '';
  let fields = [];
  let inQuotes = false;
  let afterQuote = false;
  let line = 1;
  let recordLine = 1;
  let recordHasSyntaxError = false;

  function addSyntaxError(code, message) {
    errors.push({ line: recordLine, code, message });
    recordHasSyntaxError = true;
  }

  function finishField() {
    fields.push(field);
    field = '';
    afterQuote = false;
  }

  function finishRecord() {
    finishField();
    records.push({ line: recordLine, fields, syntaxError: recordHasSyntaxError });
    fields = [];
    recordHasSyntaxError = false;
  }

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];

    if (inQuotes) {
      if (char === '"') {
        if (text[index + 1] === '"') {
          field += '"';
          index += 1;
        } else {
          inQuotes = false;
          afterQuote = true;
        }
      } else if (char === '\r') {
        if (text[index + 1] === '\n') index += 1;
        field += '\n';
        line += 1;
      } else if (char === '\n') {
        field += '\n';
        line += 1;
      } else {
        field += char;
      }
      continue;
    }

    if (afterQuote) {
      if (char === ',') {
        finishField();
      } else if (char === '\r' || char === '\n') {
        if (char === '\r' && text[index + 1] === '\n') index += 1;
        finishRecord();
        line += 1;
        recordLine = line;
      } else {
        addSyntaxError(
          'INVALID_QUOTE',
          'Unexpected character after a closing quote. Quote the whole field or escape inner quotes.'
        );
        field += char;
        afterQuote = false;
      }
      continue;
    }

    if (char === '"') {
      if (field.length > 0) {
        addSyntaxError(
          'INVALID_QUOTE',
          'A quote may only appear at the start of a quoted field.'
        );
        field += char;
      } else {
        inQuotes = true;
      }
    } else if (char === ',') {
      finishField();
    } else if (char === '\r' || char === '\n') {
      if (char === '\r' && text[index + 1] === '\n') index += 1;

      if (fields.length === 0 && field.length === 0 && !afterQuote) {
        warnings.push({
          line,
          code: 'EMPTY_LINE',
          message: 'Blank CSV line ignored.',
        });
      } else {
        finishRecord();
      }

      line += 1;
      recordLine = line;
    } else {
      field += char;
    }
  }

  if (inQuotes) {
    errors.push({
      line: recordLine,
      code: 'UNTERMINATED_QUOTE',
      message: 'Quoted field is not terminated before the end of the file.',
    });
  } else if (fields.length > 0 || field.length > 0 || afterQuote) {
    finishRecord();
  }

  return { records, errors, warnings };
}

function validateRow(record) {
  const errors = [];

  if (record.fields.length !== HEADERS.length) {
    return {
      row: null,
      errors: [
        {
          line: record.line,
          code: 'COLUMN_COUNT',
          message: `Expected ${HEADERS.length} columns, received ${record.fields.length}.`,
        },
      ],
    };
  }

  const raw = Object.fromEntries(HEADERS.map((header, index) => [header, record.fields[index]]));

  for (const header of HEADERS) {
    if (CORRUPTED_TEXT.test(raw[header]) || CONTROL_CHARACTERS.test(raw[header])) {
      errors.push({
        line: record.line,
        field: header,
        code: 'CORRUPTED_TEXT',
        message: 'Field contains a replacement character, NUL, or an invalid control character.',
      });
    }
  }

  const category = normalizeText(raw.category);
  const productName = normalizeText(raw.product_name);
  const variantLabel = normalizeText(raw.variant_label);
  const unitValueText = raw.unit_value.trim();
  const unitType = raw.unit_type.trim();
  const sourceLabel = raw.source_label.trim();

  if (category.length > LIMITS.categoryMax) {
    errors.push({
      line: record.line,
      field: 'category',
      code: 'CATEGORY_TOO_LONG',
      message: `Category must be at most ${LIMITS.categoryMax} characters.`,
    });
  }

  if (productName.length === 0) {
    errors.push({
      line: record.line,
      field: 'product_name',
      code: 'PRODUCT_NAME_REQUIRED',
      message: 'Product name is required.',
    });
  } else if (productName.length > LIMITS.productNameMax) {
    errors.push({
      line: record.line,
      field: 'product_name',
      code: 'PRODUCT_NAME_TOO_LONG',
      message: `Product name must be at most ${LIMITS.productNameMax} characters.`,
    });
  }

  if (variantLabel.length === 0) {
    errors.push({
      line: record.line,
      field: 'variant_label',
      code: 'VARIANT_LABEL_REQUIRED',
      message: 'Variant label is required.',
    });
  } else if (variantLabel.length > LIMITS.variantLabelMax) {
    errors.push({
      line: record.line,
      field: 'variant_label',
      code: 'VARIANT_LABEL_TOO_LONG',
      message: `Variant label must be at most ${LIMITS.variantLabelMax} characters.`,
    });
  }

  let unitValue = null;
  if (unitValueText.length > 0) {
    if (!/^\d+(?:\.\d+)?$/.test(unitValueText)) {
      errors.push({
        line: record.line,
        field: 'unit_value',
        code: 'UNIT_VALUE_FORMAT',
        message: 'Unit value must use digits with an optional dot decimal separator.',
      });
    } else {
      const dot = unitValueText.indexOf('.');
      const places = dot === -1 ? 0 : unitValueText.length - dot - 1;
      if (places > LIMITS.unitValuePlaces) {
        errors.push({
          line: record.line,
          field: 'unit_value',
          code: 'UNIT_VALUE_PRECISION',
          message: `Unit value must have at most ${LIMITS.unitValuePlaces} decimal places.`,
        });
      } else {
        unitValue = Number(unitValueText);
        if (!Number.isFinite(unitValue) || unitValue > LIMITS.unitValueMax) {
          errors.push({
            line: record.line,
            field: 'unit_value',
            code: 'UNIT_VALUE_RANGE',
            message: `Unit value must be at most ${LIMITS.unitValueMax}.`,
          });
        }
      }
    }
  }

  return {
    row: {
      line: record.line,
      category: category.length === 0 ? null : category,
      productName,
      variantLabel,
      unitValue,
      unitType,
      sourceLabel,
    },
    errors,
  };
}

// Parse and validate a catalog CSV. Data problems are returned as structured
// errors rather than thrown; every invalid source row is represented by at
// least one error and no row is silently discarded.
function parseCatalogCsv(input) {
  const errors = [];
  const warnings = [];
  let text;

  try {
    text = stripBom(decodeUtf8(input));
  } catch (error) {
    return {
      ok: false,
      header: null,
      rows: [],
      errors: [
        {
          line: 1,
          code: error.code || 'INVALID_ENCODING',
          message: error.message,
        },
      ],
      warnings,
      recordCount: 0,
      sourceRecordCount: 0,
    };
  }

  if (text.length === 0) {
    return {
      ok: false,
      header: null,
      rows: [],
      errors: [{ line: 1, code: 'EMPTY_FILE', message: 'CSV file is empty.' }],
      warnings,
      recordCount: 0,
      sourceRecordCount: 0,
    };
  }

  const parsed = parseCsvRecords(text);
  errors.push(...parsed.errors);
  warnings.push(...parsed.warnings);

  if (parsed.records.length === 0) {
    return {
      ok: false,
      header: null,
      rows: [],
      errors: errors.length > 0
        ? errors
        : [{ line: 1, code: 'EMPTY_FILE', message: 'CSV file contains no records.' }],
      warnings,
      recordCount: 0,
      sourceRecordCount: 0,
    };
  }

  const headerRecord = parsed.records[0];
  const header = headerRecord.fields;
  const headerMatches =
    header.length === HEADERS.length &&
    HEADERS.every((expected, index) => header[index] === expected);

  if (!headerMatches) {
    errors.push({
      line: headerRecord.line,
      code: 'INVALID_HEADER',
      message: `Expected headers: ${HEADERS.join(', ')}.`,
    });
    return {
      ok: false,
      header,
      rows: [],
      errors,
      warnings,
      recordCount: 0,
      sourceRecordCount: parsed.records.length - 1,
    };
  }

  const rows = [];
  for (const record of parsed.records.slice(1)) {
    const result = validateRow(record);
    errors.push(...result.errors);
    if (result.row) rows.push(result.row);
  }

  return {
    ok: errors.length === 0,
    header,
    rows,
    errors,
    warnings,
    recordCount: rows.length,
    sourceRecordCount: parsed.records.length - 1,
  };
}

// Stable key for comparing a CSV number, a JSON number, or a mysql2 DECIMAL
// string without floating-point drift. NULL and an absent value are distinct
// from zero.
function decimalKey(value) {
  if (value === null || value === undefined || value === '') return null;
  const text = String(value).trim();
  const match = /^(\d+)(?:\.(\d{1,3}))?$/.exec(text);
  if (!match) {
    throw new Error(`Unsupported decimal value: ${text}`);
  }
  const whole = Number(match[1]);
  const fraction = (match[2] || '').padEnd(3, '0');
  return (whole * 1000 + Number(fraction)).toString();
}

module.exports = {
  HEADERS,
  LIMITS,
  normalizeText,
  parseCatalogCsv,
  decimalKey,
};
