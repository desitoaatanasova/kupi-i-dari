import 'package:flutter/material.dart';

import 'core/api/admin_users_api.dart';
import 'core/api/api_client.dart';
import 'core/api/api_scope.dart';
import 'core/api/auth_api.dart';
import 'core/api/entry_api.dart';
import 'core/api/locations_api.dart';
import 'core/api/products_api.dart';
import 'core/api/shifts_api.dart';
import 'core/session/registration_scope.dart';
import 'core/session/registration_state_controller.dart';
import 'core/session/session_controller.dart';
import 'core/session/session_scope.dart';
import 'core/theme/app_theme.dart';
import 'screens/start_screen.dart';

void main() {
  runApp(const KupiIDariApp());
}

class KupiIDariApp extends StatefulWidget {
  const KupiIDariApp({
    super.key,
    this.sessionController,
    this.registrationStateController,
    this.locationsApi,
    this.shiftsApi,
    this.productsApi,
    this.entryApi,
    this.adminUsersApi,
  });

  /// Optional injected controller for tests. When omitted, the app builds a
  /// real [ApiClient] → [AuthApi] → [SessionController] chain once.
  final SessionController? sessionController;

  /// Optional injected registration-state cache for tests. When omitted, the
  /// app creates an in-memory one and owns its lifetime.
  final RegistrationStateController? registrationStateController;

  /// Optional injected locations API for tests. When omitted, the shared
  /// [ApiClient] is used.
  final LocationsApi? locationsApi;

  /// Optional injected shifts API for tests. When omitted, the shared
  /// [ApiClient] is used.
  final ShiftsApi? shiftsApi;

  /// Optional injected products API for tests. When omitted, the shared
  /// [ApiClient] is used.
  final ProductsApi? productsApi;

  /// Optional injected entry API for tests. When omitted, the shared
  /// [ApiClient] is used.
  final EntryApi? entryApi;

  /// Optional injected admin-user API for tests. When omitted, the shared
  /// [ApiClient] is used.
  final AdminUsersApi? adminUsersApi;

  @override
  State<KupiIDariApp> createState() => _KupiIDariAppState();
}

class _KupiIDariAppState extends State<KupiIDariApp> {
  late final SessionController _controller;
  late final RegistrationStateController _registrationStateController;
  late final LocationsApi _locationsApi;
  late final ShiftsApi _shiftsApi;
  late final ProductsApi _productsApi;
  late final EntryApi _entryApi;
  late final AdminUsersApi _adminUsersApi;
  late final bool _ownsController;
  late final bool _ownsRegistrationStateController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.sessionController == null;
    _ownsRegistrationStateController =
        widget.registrationStateController == null;

    final needsClient =
        widget.sessionController == null ||
        widget.locationsApi == null ||
        widget.shiftsApi == null ||
        widget.productsApi == null ||
        widget.entryApi == null ||
        widget.adminUsersApi == null;
    final sharedClient =
        needsClient ? ApiClient(onUnauthorized: _handleUnauthorized) : null;

    _controller =
        widget.sessionController ??
        SessionController(authApi: AuthApi(sharedClient!));
    _registrationStateController =
        widget.registrationStateController ?? RegistrationStateController();
    _locationsApi = widget.locationsApi ?? LocationsApi(sharedClient!);
    _shiftsApi = widget.shiftsApi ?? ShiftsApi(sharedClient!);
    _productsApi = widget.productsApi ?? ProductsApi(sharedClient!);
    _entryApi = widget.entryApi ?? EntryApi(sharedClient!);
    _adminUsersApi = widget.adminUsersApi ?? AdminUsersApi(sharedClient!);
  }

  void _handleUnauthorized() {
    if (!mounted) return;
    _controller.handleUnauthorized();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    if (_ownsRegistrationStateController) {
      _registrationStateController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      controller: _controller,
      child: RegistrationScope(
        controller: _registrationStateController,
        child: ApiScope(
          locationsApi: _locationsApi,
          shiftsApi: _shiftsApi,
          productsApi: _productsApi,
          entryApi: _entryApi,
          adminUsersApi: _adminUsersApi,
          child: MaterialApp(
            title: 'Купи и Дари',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            home: const StartScreen(),
          ),
        ),
      ),
    );
  }
}
