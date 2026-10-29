import 'package:flutter/widgets.dart';

import 'admin_users_api.dart';
import 'entry_api.dart';
import 'locations_api.dart';
import 'products_api.dart';
import 'shifts_api.dart';

/// Provides the shared business-data API clients to the widget tree.
///
/// A plain [InheritedWidget] is enough because the clients are stateless and
/// stable for the lifetime of the app. No fallback client is ever created here;
/// callers that require one must find it explicitly.
class ApiScope extends InheritedWidget {
  const ApiScope({
    super.key,
    required this.locationsApi,
    required this.shiftsApi,
    required this.productsApi,
    required this.entryApi,
    required this.adminUsersApi,
    required super.child,
  });

  final LocationsApi locationsApi;
  final ShiftsApi shiftsApi;
  final ProductsApi productsApi;
  final EntryApi entryApi;
  final AdminUsersApi adminUsersApi;

  static LocationsApi of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ApiScope>();
    assert(scope != null, 'ApiScope was not found in the widget tree.');
    return scope!.locationsApi;
  }

  static LocationsApi? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ApiScope>()?.locationsApi;
  }

  static ShiftsApi shiftsOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ApiScope>();
    assert(scope != null, 'ApiScope was not found in the widget tree.');
    return scope!.shiftsApi;
  }

  static ShiftsApi? maybeShiftsOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ApiScope>()?.shiftsApi;
  }

  static ProductsApi productsOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ApiScope>();
    assert(scope != null, 'ApiScope was not found in the widget tree.');
    return scope!.productsApi;
  }

  static ProductsApi? maybeProductsOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ApiScope>()?.productsApi;
  }

  static EntryApi entryOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ApiScope>();
    assert(scope != null, 'ApiScope was not found in the widget tree.');
    return scope!.entryApi;
  }

  static EntryApi? maybeEntryOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ApiScope>()?.entryApi;
  }

  static AdminUsersApi adminUsersOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ApiScope>();
    assert(scope != null, 'ApiScope was not found in the widget tree.');
    return scope!.adminUsersApi;
  }

  static AdminUsersApi? maybeAdminUsersOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ApiScope>()
        ?.adminUsersApi;
  }

  @override
  bool updateShouldNotify(ApiScope oldWidget) {
    return !identical(locationsApi, oldWidget.locationsApi) ||
        !identical(shiftsApi, oldWidget.shiftsApi) ||
        !identical(productsApi, oldWidget.productsApi) ||
        !identical(entryApi, oldWidget.entryApi) ||
        !identical(adminUsersApi, oldWidget.adminUsersApi);
  }
}
