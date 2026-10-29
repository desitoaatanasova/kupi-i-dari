import 'package:flutter/foundation.dart';

/// A product as returned by `GET /api/products`.
///
/// This mirrors the backend safe shape exactly
/// (`{ id, name, category, isActive }`) and is deliberately separate from the
/// UI-only demo [Product] model (which carries a local `categoryId`). The
/// backend has no category resource: `category` is an optional free-form
/// string that the client groups by.
@immutable
class CatalogProduct {
  const CatalogProduct({
    required this.id,
    required this.name,
    required this.category,
    required this.isActive,
  });

  final int id;
  final String name;

  /// Free-form category label, or `null` when the product has none.
  final String? category;
  final bool isActive;
}

/// A product variant as returned by `GET /api/products/:productId/variants`.
///
/// Safe shape: `{ id, productId, unitLabel, unitValue, isActive }`.
@immutable
class CatalogVariant {
  const CatalogVariant({
    required this.id,
    required this.productId,
    required this.unitLabel,
    required this.unitValue,
    required this.isActive,
  });

  final int id;
  final int productId;

  /// Human-readable package label, e.g. `1 кг`.
  final String unitLabel;

  /// Optional numeric unit value; `null` when unspecified.
  final num? unitValue;
  final bool isActive;
}
