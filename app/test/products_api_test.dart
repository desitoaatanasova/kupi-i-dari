import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/products_api.dart';

http.Response jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('ProductsApi', () {
    test('parses the products envelope and forwards the token', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/products');
        expect(request.headers['Authorization'], 'Bearer token-123');
        return jsonResponse({
          'products': [
            {
              'id': 1,
              'name': 'Шампоан',
              'category': 'Хигиена',
              'isActive': true,
            },
            {'id': 2, 'name': 'Ориз', 'category': null, 'isActive': true},
          ],
        }, 200);
      });

      final api = ProductsApi(ApiClient(httpClient: client));
      final products = await api.listProducts(token: 'token-123');
      expect(products.length, 2);
      expect(products.first.id, 1);
      expect(products.first.name, 'Шампоан');
      expect(products.first.category, 'Хигиена');
      expect(products.first.isActive, isTrue);
      expect(products[1].category, isNull);
    });

    test('parses variants with nullable unit value', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/products/7/variants');
        return jsonResponse({
          'variants': [
            {
              'id': 70,
              'productId': 7,
              'unitLabel': 'бутилка',
              'unitValue': 0.5,
              'isActive': true,
            },
            {
              'id': 71,
              'productId': 7,
              'unitLabel': 'бр',
              'unitValue': null,
              'isActive': true,
            },
          ],
        }, 200);
      });

      final api = ProductsApi(ApiClient(httpClient: client));
      final variants = await api.getVariants(7);
      expect(variants.length, 2);
      expect(variants.first.unitLabel, 'бутилка');
      expect(variants.first.unitValue, 0.5);
      expect(variants[1].unitValue, isNull);
    });

    test('maps the backend error envelope to an ApiException', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'error': {'code': 'NOT_FOUND', 'message': 'Product not found.'},
        }, 404);
      });

      final api = ProductsApi(ApiClient(httpClient: client));
      expect(
        () => api.getVariants(99),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'NOT_FOUND')
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('rejects malformed product payloads', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'products': [
            {'id': 'not-an-int', 'name': 'X', 'isActive': true},
          ],
        }, 200);
      });

      final api = ProductsApi(ApiClient(httpClient: client));
      expect(
        () => api.listProducts(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });
  });
}
