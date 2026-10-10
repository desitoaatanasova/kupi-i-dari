/// Centralised API configuration.
///
/// The base URL can be overridden at build/run time:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3001/api
class ApiConfig {
  const ApiConfig._();

  /// Base URL for the backend REST API.
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:3001/api',
  );

  /// Convenience getter for the health endpoint.
  static String get healthUrl => '$baseUrl/health';
}
