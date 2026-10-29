import '../../models/location.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// Typed access to the backend location endpoints.
///
/// Endpoint paths are relative to [ApiClient.baseUrl] (which already ends in
/// `/api`). The contract follows Phases 4 and 27: public reads return active
/// locations only; admin writes create/update/archive/reactivate locations.
class LocationsApi {
  LocationsApi(this._client);

  final ApiClient _client;

  Future<List<Location>> list({String? token}) async {
    final payload = await _client.get('/locations', token: token);
    if (payload is! Map || payload['locations'] is! List) {
      throw malformedResponse();
    }

    final records = payload['locations'] as List;
    final locations = <Location>[];
    for (final record in records) {
      final location = _parseRecord(record);
      if (location.isActive) locations.add(location);
    }
    return locations;
  }

  Future<Location> createLocation({
    required String name,
    required String address,
    String? token,
  }) async {
    final payload = await _client.post(
      '/locations',
      body: {'name': name, 'address': address},
      token: token,
    );
    return _parseRecord(payload);
  }

  Future<Location> updateLocation(
    int locationId, {
    required String name,
    required String address,
    String? token,
  }) async {
    final payload = await _client.patch(
      '/locations/$locationId',
      body: {'name': name, 'address': address},
      token: token,
    );
    return _parseRecord(payload);
  }

  Future<Location> setLocationStatus(
    int locationId, {
    required bool isActive,
    String? token,
  }) async {
    final payload = await _client.patch(
      '/locations/$locationId/status',
      body: {'isActive': isActive},
      token: token,
    );
    return _parseRecord(payload);
  }

  static Location _parseRecord(Object? record) {
    if (record is! Map) throw malformedResponse();

    final id = record['id'];
    final name = record['name'];
    final address = record['address'];
    final isActive = record['isActive'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (name is! String || name.isEmpty) throw malformedResponse();
    if (address is! String) throw malformedResponse();
    if (isActive is! bool) throw malformedResponse();

    return Location(id: id, name: name, address: address, isActive: isActive);
  }

  static ApiException malformedResponse() => const ApiException(
    code: 'UNEXPECTED_RESPONSE',
    message: 'The server returned an unexpected response.',
  );
}
