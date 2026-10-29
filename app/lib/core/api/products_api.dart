import '../../models/catalog_product.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// Typed access to the backend product catalog endpoints.
///
/// Endpoint paths are relative to [ApiClient.baseUrl] (which already ends in
/// `/api`). All three reads are **public** in the backend (Phase 5): active
/// catalog entries are non-sensitive. [token] is optional and only forwarded
/// when the caller already holds a session.
class ProductsApi {
  ProductsApi(this._client);

  final ApiClient _client;

  /// `GET /api/products` — active products, ordered by name then id.
  Future<List<CatalogProduct>> listProducts({String? token}) async {
    final payload = await _client.get('/products', token: token);
    if (payload is! Map || payload['products'] is! List) {
      throw malformedResponse();
    }
    final records = payload['products'] as List;
    final products = <CatalogProduct>[];
    for (final record in records) {
      products.add(_parseProduct(record));
    }
    return products;
  }

  /// `GET /api/products/:productId/variants` — active variants of an active
  /// product. A missing/archived product returns `404` from the backend.
  Future<List<CatalogVariant>> getVariants(
    int productId, {
    String? token,
  }) async {
    if (productId <= 0) throw malformedResponse();
    final payload = await _client.get(
      '/products/$productId/variants',
      token: token,
    );
    if (payload is! Map || payload['variants'] is! List) {
      throw malformedResponse();
    }
    final records = payload['variants'] as List;
    final variants = <CatalogVariant>[];
    for (final record in records) {
      variants.add(_parseVariant(record));
    }
    return variants;
  }

  static CatalogProduct _parseProduct(Object? record) {
    if (record is! Map) throw malformedResponse();

    final id = record['id'];
    final name = record['name'];
    final category = record['category'];
    final isActive = record['isActive'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (name is! String || name.isEmpty) throw malformedResponse();
    if (category != null && category is! String) throw malformedResponse();
    if (isActive is! bool) throw malformedResponse();

    return CatalogProduct(
      id: id,
      name: name,
      category: category as String?,
      isActive: isActive,
    );
  }

  static CatalogVariant _parseVariant(Object? record) {
    if (record is! Map) throw malformedResponse();

    final id = record['id'];
    final productId = record['productId'];
    final unitLabel = record['unitLabel'];
    final unitValue = record['unitValue'];
    final isActive = record['isActive'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (productId is! int || productId <= 0) throw malformedResponse();
    if (unitLabel is! String || unitLabel.isEmpty) throw malformedResponse();
    if (unitValue != null && unitValue is! num) throw malformedResponse();
    if (isActive is! bool) throw malformedResponse();

    return CatalogVariant(
      id: id,
      productId: productId,
      unitLabel: unitLabel,
      unitValue: unitValue as num?,
      isActive: isActive,
    );
  }

  static ApiException malformedResponse() => const ApiException(
    code: 'UNEXPECTED_RESPONSE',
    message: 'The server returned an unexpected response.',
  );
}
