'use strict';

const { pool } = require('../db');

// Build the shared JOIN + WHERE fragments reused by every aggregate query, so
// totals and grouped results always apply identical conditions. Only static SQL
// fragments are assembled here; every value is bound as a parameter.
//
// `shifts` is joined only when a shift or date filter is present. A date
// predicate lives on the shift row, so this join naturally excludes legacy
// unlinked rows (shift_id IS NULL) whenever a date filter is supplied. Without a
// shift/date filter the shift table is not touched, so unlinked rows stay part
// of the report.
//
// A RESPONSIBLE caller adds a `responsible_locations` join, restricting every
// query to their assigned locations without multiplying rows (the (user,
// location) pair is unique).
function buildFilter({ filters = {}, responsibleUserId } = {}) {
  const joins = [];
  const clauses = [];
  const params = [];

  const needsShift =
    filters.shiftId !== undefined ||
    filters.dateFrom !== undefined ||
    filters.dateTo !== undefined;
  if (needsShift) {
    joins.push('JOIN shifts s ON s.shift_id = cq.shift_id');
  }

  if (responsibleUserId !== undefined) {
    joins.push(
      'JOIN responsible_locations rl ON rl.location_id = cq.location_id AND rl.user_id = ?'
    );
    params.push(responsibleUserId);
  }

  if (filters.locationId !== undefined) {
    clauses.push('cq.location_id = ?');
    params.push(filters.locationId);
  }
  if (filters.productId !== undefined) {
    joins.push('JOIN product_variants pv ON pv.variant_id = cq.variant_id');
    clauses.push('pv.product_id = ?');
    params.push(filters.productId);
  }
  if (filters.shiftId !== undefined) {
    clauses.push('cq.shift_id = ?');
    params.push(filters.shiftId);
  }
  if (filters.dateFrom !== undefined) {
    clauses.push('s.shift_date >= ?');
    params.push(filters.dateFrom);
  }
  if (filters.dateTo !== undefined) {
    clauses.push('s.shift_date <= ?');
    params.push(filters.dateTo);
  }

  return {
    joins: joins.join(' '),
    where: clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '',
    params,
  };
}

// MySQL returns SUM() over an INT column as a DECIMAL string; COUNT() may also
// arrive as a string. Normalise every aggregate to a JavaScript number.
function toNumber(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

// Read-only summary of recorded quantity rows. Returns exactly totals, a
// per-location aggregation and a per-product aggregation. It is a sum of the
// recorded rows, not an inventory balance or a donation/distribution report.
//
// The three SELECTs share the same filters but are separate round-trips, so a
// concurrent write could in principle be observed by one aggregate and not the
// other. No locks are taken: this is an operational read, not a ledger.
//
// Ordering is deterministic: units DESC, then the entity id ASC.
async function sumCollected({ filters = {}, responsibleUserId } = {}) {
  const { joins, where, params } = buildFilter({ filters, responsibleUserId });

  const [totalsRows] = await pool.query(
    `SELECT COALESCE(SUM(cq.quantity), 0) AS units, COUNT(*) AS row_count
       FROM collected_quantities cq
       ${joins}
       ${where}`,
    params
  );

  const [locationRows] = await pool.query(
    `SELECT cq.location_id AS location_id, l.name AS location_name,
            COALESCE(SUM(cq.quantity), 0) AS units, COUNT(*) AS row_count
       FROM collected_quantities cq
       JOIN locations l ON l.location_id = cq.location_id
       ${joins}
       ${where}
      GROUP BY cq.location_id, l.name
      ORDER BY units DESC, cq.location_id ASC`,
    params
  );

  const [productRows] = await pool.query(
    `SELECT pva.product_id AS product_id, p.name AS product_name, p.category AS category,
            COALESCE(SUM(cq.quantity), 0) AS units, COUNT(*) AS row_count
       FROM collected_quantities cq
       JOIN product_variants pva ON pva.variant_id = cq.variant_id
       JOIN products p ON p.product_id = pva.product_id
       ${joins}
       ${where}
      GROUP BY pva.product_id, p.name, p.category
      ORDER BY units DESC, pva.product_id ASC`,
    params
  );

  const totals = totalsRows[0] || {};

  return {
    totals: {
      units: toNumber(totals.units),
      rows: toNumber(totals.row_count),
    },
    byLocation: locationRows.map((row) => ({
      locationId: row.location_id,
      locationName: row.location_name,
      units: toNumber(row.units),
      rows: toNumber(row.row_count),
    })),
    byProduct: productRows.map((row) => ({
      productId: row.product_id,
      productName: row.product_name,
      category: row.category === undefined ? null : row.category,
      units: toNumber(row.units),
      rows: toNumber(row.row_count),
    })),
  };
}

// Build the JOIN + WHERE fragments for ONE branch of the inventory UNION ALL
// query. Both branches share the same filter fields, so they are produced by a
// single helper to guarantee the collected and distributed sides apply identical
// conditions. Only static fragments are concatenated; every value is bound.
//
// `alias`        table alias for the fact table
// `shiftJoin`    true only for the collection branch when a date filter needs
//                `shifts.shift_date`; the INNER join then excludes legacy
//                `shift_id IS NULL` rows (the Phase 9 convention)
// `dateColumn`   column the date predicates act on (shift date or
//                distribution_date)
function buildInventoryBranch({
  alias,
  filters = {},
  responsibleUserId,
  shiftJoin,
  dateColumn,
}) {
  const joins = [];
  const clauses = [];
  const params = [];

  if (shiftJoin) {
    joins.push(`JOIN shifts s ON s.shift_id = ${alias}.shift_id`);
  }
  if (responsibleUserId !== undefined) {
    joins.push(
      `JOIN responsible_locations rl ON rl.location_id = ${alias}.location_id AND rl.user_id = ?`
    );
    params.push(responsibleUserId);
  }
  if (filters.productId !== undefined) {
    joins.push(`JOIN product_variants pv ON pv.variant_id = ${alias}.variant_id`);
  }

  if (filters.locationId !== undefined) {
    clauses.push(`${alias}.location_id = ?`);
    params.push(filters.locationId);
  }
  if (filters.variantId !== undefined) {
    clauses.push(`${alias}.variant_id = ?`);
    params.push(filters.variantId);
  }
  if (filters.productId !== undefined) {
    clauses.push('pv.product_id = ?');
    params.push(filters.productId);
  }
  if (filters.dateFrom !== undefined) {
    clauses.push(`${dateColumn} >= ?`);
    params.push(filters.dateFrom);
  }
  if (filters.dateTo !== undefined) {
    clauses.push(`${dateColumn} <= ?`);
    params.push(filters.dateTo);
  }

  return {
    joinSql: joins.join(' '),
    whereSql: clauses.length > 0 ? `WHERE ${clauses.join(' AND ')}` : '',
    params,
  };
}

// Fold a flat aggregate row into a group map, summing both quantities.
function addToGroup(map, key, entry, collected, distributed) {
  const existing = map.get(key);
  if (existing) {
    existing.collectedQuantity += collected;
    existing.distributedQuantity += distributed;
  } else {
    map.set(key, {
      ...entry,
      collectedQuantity: collected,
      distributedQuantity: distributed,
    });
  }
}

// Order groups by collected quantity desc, then entity id asc. Deterministic.
function byCollectedThenId(idKey) {
  return (a, b) => b.collectedQuantity - a.collectedQuantity || a[idKey] - b[idKey];
}

function finalize(entry) {
  entry.remainingQuantity = entry.collectedQuantity - entry.distributedQuantity;
  return entry;
}

// Read-only inventory balance report: collected minus distributed per
// (location, variant), with totals and per-location / per-product / per-variant
// roll-ups. The two sources are aggregated INDEPENDENTLY inside a UNION ALL, so
// multiple collection and distribution rows for the same (location, variant)
// never multiply. The key set is the union of both sources, so a
// distribution-only pair appears with `collectedQuantity = 0` and a negative
// `remainingQuantity`; pairs with no activity at all are omitted (no
// location-by-variant cross product). `remainingQuantity` is never clamped.
//
// Date filters are applied to both branches but use different date sources: the
// collection branch dates on `shifts.shift_date` (so legacy unlinked rows are
// excluded) and the distribution branch on `distributions.distribution_date`.
// A date-filtered report is therefore window net flow, not a historical balance.
//
// One round-trip: all grouping is folded in JavaScript from the (location,
// variant) rows, avoiding N+1 access and keeping every section consistent with
// the same snapshot.
async function sumInventory({ filters = {}, responsibleUserId } = {}) {
  const hasDateFilter =
    filters.dateFrom !== undefined || filters.dateTo !== undefined;

  const collected = buildInventoryBranch({
    alias: 'cq',
    filters,
    responsibleUserId,
    shiftJoin: hasDateFilter,
    dateColumn: 's.shift_date',
  });
  const distributed = buildInventoryBranch({
    alias: 'd',
    filters,
    responsibleUserId,
    shiftJoin: false,
    dateColumn: 'd.distribution_date',
  });

  const [rows] = await pool.query(
    `SELECT x.location_id AS location_id, x.variant_id AS variant_id,
            x.collected AS collected, x.distributed AS distributed,
            l.name AS location_name,
            pv.product_id AS product_id, pv.unit_label AS unit_label,
            p.name AS product_name, p.category AS category
       FROM (
         SELECT cq.location_id AS location_id, cq.variant_id AS variant_id,
                COALESCE(SUM(cq.quantity), 0) AS collected, 0 AS distributed
           FROM collected_quantities cq
           ${collected.joinSql}
           ${collected.whereSql}
          GROUP BY cq.location_id, cq.variant_id
         UNION ALL
         SELECT d.location_id AS location_id, d.variant_id AS variant_id,
                0 AS collected, COALESCE(SUM(d.quantity), 0) AS distributed
           FROM distributions d
           ${distributed.joinSql}
           ${distributed.whereSql}
          GROUP BY d.location_id, d.variant_id
       ) x
       JOIN locations l ON l.location_id = x.location_id
       JOIN product_variants pv ON pv.variant_id = x.variant_id
       JOIN products p ON p.product_id = pv.product_id`,
    [...collected.params, ...distributed.params]
  );

  const locations = new Map();
  const products = new Map();
  const variants = new Map();
  let collectedTotal = 0;
  let distributedTotal = 0;

  for (const row of rows) {
    const collectedQuantity = toNumber(row.collected);
    const distributedQuantity = toNumber(row.distributed);

    collectedTotal += collectedQuantity;
    distributedTotal += distributedQuantity;

    addToGroup(
      locations,
      row.location_id,
      { locationId: row.location_id, locationName: row.location_name },
      collectedQuantity,
      distributedQuantity
    );
    addToGroup(
      products,
      row.product_id,
      {
        productId: row.product_id,
        productName: row.product_name,
        category: row.category === undefined ? null : row.category,
      },
      collectedQuantity,
      distributedQuantity
    );
    addToGroup(
      variants,
      row.variant_id,
      {
        variantId: row.variant_id,
        productId: row.product_id,
        productName: row.product_name,
        unitLabel: row.unit_label,
      },
      collectedQuantity,
      distributedQuantity
    );
  }

  const byLocation = [...locations.values()]
    .map(finalize)
    .sort(byCollectedThenId('locationId'));
  const byProduct = [...products.values()]
    .map(finalize)
    .sort(byCollectedThenId('productId'));
  const byVariant = [...variants.values()]
    .map(finalize)
    .sort(byCollectedThenId('variantId'));

  return {
    totals: {
      collectedQuantity: collectedTotal,
      distributedQuantity: distributedTotal,
      remainingQuantity: collectedTotal - distributedTotal,
    },
    byLocation,
    byProduct,
    byVariant,
  };
}

module.exports = { sumCollected, sumInventory };
