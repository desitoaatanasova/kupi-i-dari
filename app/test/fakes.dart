import 'dart:async';

import 'package:kupi_i_dari/core/api/admin_users_api.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/auth_api.dart';
import 'package:kupi_i_dari/core/api/entry_api.dart';
import 'package:kupi_i_dari/core/api/locations_api.dart';
import 'package:kupi_i_dari/core/api/products_api.dart';
import 'package:kupi_i_dari/core/api/shifts_api.dart';
import 'package:kupi_i_dari/core/session/auth_session.dart';
import 'package:kupi_i_dari/data/sample_data.dart';
import 'package:kupi_i_dari/models/admin_user_page.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/models/catalog_product.dart';
import 'package:kupi_i_dari/models/entry_context.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/models/shift.dart';

/// A ready-made backend token response.
AuthSession buildSession({
  String token = 'token-123',
  UserRole role = UserRole.admin,
  bool mustChangePassword = false,
  int? expiresIn = 3600,
}) {
  return AuthSession(
    token: token,
    expiresIn: expiresIn,
    user: AppUser(
      id: 1,
      phone: '+359881000001',
      firstName: 'Тестов',
      lastName: 'Потребител',
      role: role,
      isActive: true,
      mustChangePassword: mustChangePassword,
    ),
  );
}

ApiException buildError(
  int statusCode,
  String code, {
  String message = 'server text',
}) {
  return ApiException(statusCode: statusCode, code: code, message: message);
}

/// In-memory [AuthApi] fake: records calls, can be gated and can fail on demand.
class FakeAuthApi implements AuthApi {
  AuthSession? loginResponse = buildSession();
  Object? loginError;
  Completer<void>? loginGate;
  int loginCalls = 0;
  String? lastLoginPhone;
  String? lastLoginPassword;

  AuthSession? registerResponse = buildSession(
    role: UserRole.volunteer,
    token: 'register-token',
  );
  Object? registerError;
  Completer<void>? registerGate;
  int registerCalls = 0;
  String? lastRegisterFirstName;
  String? lastRegisterLastName;
  String? lastRegisterPhone;
  UserRole? lastRegisterRole;

  AuthSession? volunteerLoginResponse = buildSession(
    role: UserRole.volunteer,
    token: 'vol-login-token',
  );
  Object? volunteerLoginError;
  Completer<void>? volunteerLoginGate;
  int volunteerLoginCalls = 0;
  String? lastVolunteerLoginFirstName;
  String? lastVolunteerLoginLastName;
  String? lastVolunteerLoginPhone;

  AuthSession? volunteerResponse = buildSession(
    role: UserRole.volunteer,
    token: 'vol-token',
  );
  Object? volunteerError;
  int volunteerCalls = 0;
  String? lastVolunteerFirstName;
  String? lastVolunteerLastName;
  String? lastVolunteerPhone;

  AppUser? meResponse;
  Object? meError;
  int meCalls = 0;

  AuthSession? changeResponse = buildSession(token: 'changed-token');
  Object? changeError;
  int changeCalls = 0;
  String? lastCurrentPassword;
  String? lastNewPassword;

  Object? logoutError;
  int logoutCalls = 0;
  String? lastLogoutToken;

  @override
  Future<AuthSession> login({
    required String phone,
    required String password,
  }) async {
    loginCalls += 1;
    lastLoginPhone = phone;
    lastLoginPassword = password;
    if (loginGate != null) await loginGate!.future;
    final error = loginError;
    if (error != null) throw error;
    return loginResponse!;
  }

  @override
  Future<AuthSession> registerVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
    required UserRole role,
  }) async {
    registerCalls += 1;
    lastRegisterFirstName = firstName;
    lastRegisterLastName = lastName;
    lastRegisterPhone = phone;
    lastRegisterRole = role;
    if (registerGate != null) await registerGate!.future;
    final error = registerError;
    if (error != null) throw error;
    return registerResponse!;
  }

  @override
  Future<AuthSession> loginVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    volunteerLoginCalls += 1;
    lastVolunteerLoginFirstName = firstName;
    lastVolunteerLoginLastName = lastName;
    lastVolunteerLoginPhone = phone;
    if (volunteerLoginGate != null) await volunteerLoginGate!.future;
    final error = volunteerLoginError;
    if (error != null) throw error;
    return volunteerLoginResponse!;
  }

  @override
  Future<AuthSession> identifyVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    volunteerCalls += 1;
    lastVolunteerFirstName = firstName;
    lastVolunteerLastName = lastName;
    lastVolunteerPhone = phone;
    final error = volunteerError;
    if (error != null) throw error;
    return volunteerResponse!;
  }

  @override
  Future<AppUser> me({required String token}) async {
    meCalls += 1;
    final error = meError;
    if (error != null) throw error;
    return meResponse!;
  }

  @override
  Future<AuthSession> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    changeCalls += 1;
    lastCurrentPassword = currentPassword;
    lastNewPassword = newPassword;
    final error = changeError;
    if (error != null) throw error;
    return changeResponse!;
  }

  @override
  Future<void> logout({required String token}) async {
    logoutCalls += 1;
    lastLogoutToken = token;
    final error = logoutError;
    if (error != null) throw error;
  }
}

/// In-memory [LocationsApi] fake: records calls, can be gated and can fail on demand.
class FakeLocationsApi implements LocationsApi {
  List<Location>? listResponse = const [
    Location(
      id: 1,
      name: 'Площад „Светлина“',
      address: 'ул. Централна 12, София',
    ),
    Location(
      id: 2,
      name: 'Квартален пункт „Младост“',
      address: 'бул. Александър Малинов 45, София',
    ),
    Location(
      id: 3,
      name: 'Пункт „Тракия“',
      address: 'ул. Христо Ботев 8, Пловдив',
    ),
    Location(id: 4, name: 'Пункт „Северен“', address: 'бул. Дунав 3, Варна'),
  ];

  Object? listError;
  Completer<void>? listGate;
  int listCalls = 0;
  String? lastToken;

  Location? createResponse;
  Object? createError;
  Completer<void>? createGate;
  int createCalls = 0;
  String? lastCreateName;
  String? lastCreateAddress;
  String? lastCreateToken;

  Location? updateResponse;
  Object? updateError;
  Completer<void>? updateGate;
  int updateCalls = 0;
  int? lastUpdateId;
  String? lastUpdateName;
  String? lastUpdateAddress;
  String? lastUpdateToken;

  Location? setStatusResponse;
  Object? setStatusError;
  Completer<void>? setStatusGate;
  int setStatusCalls = 0;
  int? lastSetStatusId;
  bool? lastSetStatusValue;
  String? lastSetStatusToken;

  /// Makes the next [list] call hang until the returned gate is completed.
  Completer<void> setPending() {
    final completer = Completer<void>();
    listGate = completer;
    return completer;
  }

  Completer<void> setCreatePending() {
    final completer = Completer<void>();
    createGate = completer;
    return completer;
  }

  Completer<void> setUpdatePending() {
    final completer = Completer<void>();
    updateGate = completer;
    return completer;
  }

  Completer<void> setSetStatusPending() {
    final completer = Completer<void>();
    setStatusGate = completer;
    return completer;
  }

  @override
  Future<List<Location>> list({String? token}) async {
    listCalls += 1;
    lastToken = token;
    final gate = listGate;
    if (gate != null) await gate.future;
    final error = listError;
    if (error != null) throw error;
    return List<Location>.unmodifiable(listResponse ?? const []);
  }

  @override
  Future<Location> createLocation({
    required String name,
    required String address,
    String? token,
  }) async {
    createCalls += 1;
    lastCreateName = name;
    lastCreateAddress = address;
    lastCreateToken = token;
    final gate = createGate;
    if (gate != null) await gate.future;
    final error = createError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = createResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No create response configured.',
      );
    }
    return response;
  }

  @override
  Future<Location> updateLocation(
    int locationId, {
    required String name,
    required String address,
    String? token,
  }) async {
    updateCalls += 1;
    lastUpdateId = locationId;
    lastUpdateName = name;
    lastUpdateAddress = address;
    lastUpdateToken = token;
    final gate = updateGate;
    if (gate != null) await gate.future;
    final error = updateError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = updateResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No update response configured.',
      );
    }
    return response;
  }

  @override
  Future<Location> setLocationStatus(
    int locationId, {
    required bool isActive,
    String? token,
  }) async {
    setStatusCalls += 1;
    lastSetStatusId = locationId;
    lastSetStatusValue = isActive;
    lastSetStatusToken = token;
    final gate = setStatusGate;
    if (gate != null) await gate.future;
    final error = setStatusError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = setStatusResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No status response configured.',
      );
    }
    return response;
  }
}

/// In-memory [ShiftsApi] fake: records calls, can be gated and can fail on demand.
class FakeShiftsApi implements ShiftsApi {
  FakeShiftsApi() {
    listResponse = List<Shift>.unmodifiable(SampleData.shifts);
    for (final shift in SampleData.shifts) {
      detailResponses[shift.id] = ShiftDetail(
        shift: shift,
        locations: [
          for (final id in shift.locationIds)
            for (final location in SampleData.locations)
              if (location.id == id)
                ShiftDetailLocation(
                  id: location.id,
                  name: location.name,
                  address: location.address,
                  isActive: location.isActive,
                ),
        ],
        myRegistration: null,
      );
    }
  }

  List<Shift>? listResponse;
  Object? listError;
  Completer<void>? listGate;
  final List<Completer<void>> listGateQueue = <Completer<void>>[];
  final List<Object?> listResults = <Object?>[];
  int listCalls = 0;
  String? lastToken;
  String? lastStatus;
  String? lastDate;

  final Map<int, ShiftDetail> detailResponses = <int, ShiftDetail>{};
  Object? defaultDetailError;
  final Map<int, Object?> detailErrors = <int, Object?>{};
  final Map<int, Completer<void>> detailGates = <int, Completer<void>>{};
  final Map<int, List<Completer<void>>> detailGateQueues =
      <int, List<Completer<void>>>{};
  final Map<int, List<Object?>> detailResults = <int, List<Object?>>{};
  int detailCalls = 0;
  final List<int> detailCallIds = <int>[];

  RegistrationResult? registrationResponse;
  Object? registrationError;
  Completer<void>? registrationGate;
  int registrationCalls = 0;
  int? lastRegistrationShiftId;
  String? lastRegistrationToken;

  RegistrationResult? cancelResponse;
  Object? cancelError;
  Completer<void>? cancelGate;
  int cancelCalls = 0;
  int? lastCancelShiftId;
  int? lastCancelRegistrationId;
  String? lastCancelToken;

  ShiftDetail? createShiftResponse;
  Object? createShiftError;
  Completer<void>? createShiftGate;
  int createShiftCalls = 0;
  String? lastCreateTitle;
  DateTime? lastCreateDate;
  String? lastCreateStartTime;
  String? lastCreateEndTime;
  List<int>? lastCreateLocationIds;
  String? lastCreateToken;

  Shift? updateShiftResponse;
  Object? updateShiftError;
  Completer<void>? updateShiftGate;
  int updateShiftCalls = 0;
  int? lastUpdateShiftId;
  String? lastUpdateTitle;
  DateTime? lastUpdateDate;
  String? lastUpdateStartTime;
  String? lastUpdateEndTime;
  String? lastUpdateToken;

  Shift? setStatusResponse;
  Object? setStatusError;
  Completer<void>? setStatusGate;
  int setStatusCalls = 0;
  int? lastSetStatusShiftId;
  String? lastSetStatus;
  String? lastSetStatusToken;

  List<ShiftDetailLocation>? replaceLocationsResponse;
  Object? replaceLocationsError;
  Completer<void>? replaceLocationsGate;
  int replaceLocationsCalls = 0;
  int? lastReplaceLocationsShiftId;
  List<int>? lastReplaceLocationIds;
  String? lastReplaceLocationsToken;

  /// Makes the next [list] call hang until the returned gate is completed.
  Completer<void> setPending() {
    final completer = Completer<void>();
    listGate = completer;
    return completer;
  }

  /// Queues a one-shot gate for the next [list] calls.
  Completer<void> queueListPending() {
    final completer = Completer<void>();
    listGateQueue.add(completer);
    return completer;
  }

  /// Queues a one-shot result or error for the next [list] calls.
  void queueListResult(Object result) {
    listResults.add(result);
  }

  /// Makes detail requests for [shiftId] hang until completed.
  Completer<void> setDetailPending(int shiftId) {
    final completer = Completer<void>();
    detailGates[shiftId] = completer;
    return completer;
  }

  /// Queues a one-shot gate for the next detail requests of [shiftId].
  Completer<void> queueDetailPending(int shiftId) {
    final completer = Completer<void>();
    detailGateQueues
        .putIfAbsent(shiftId, () => <Completer<void>>[])
        .add(completer);
    return completer;
  }

  /// Queues a one-shot result or error for the next detail requests of
  /// [shiftId].
  void queueDetailResult(int shiftId, Object result) {
    detailResults.putIfAbsent(shiftId, () => <Object?>[]).add(result);
  }

  Completer<void> setCreateShiftPending() {
    final completer = Completer<void>();
    createShiftGate = completer;
    return completer;
  }

  Completer<void> setUpdateShiftPending() {
    final completer = Completer<void>();
    updateShiftGate = completer;
    return completer;
  }

  Completer<void> setSetStatusPending() {
    final completer = Completer<void>();
    setStatusGate = completer;
    return completer;
  }

  /// Makes registration requests hang until the returned gate is completed.
  Completer<void> setRegistrationPending() {
    final completer = Completer<void>();
    registrationGate = completer;
    return completer;
  }

  /// Makes cancellation requests hang until the returned gate is completed.
  Completer<void> setCancelPending() {
    final completer = Completer<void>();
    cancelGate = completer;
    return completer;
  }

  @override
  Future<List<Shift>> list({
    String? token,
    String? status,
    String? date,
  }) async {
    listCalls += 1;
    lastToken = token;
    lastStatus = status;
    lastDate = date;
    final queuedGate = listGateQueue.isEmpty ? null : listGateQueue.removeAt(0);
    final hasQueuedResult = listResults.isNotEmpty;
    final queuedResult = hasQueuedResult ? listResults.removeAt(0) : null;
    final gate = queuedGate ?? listGate;
    if (gate != null) await gate.future;
    if (hasQueuedResult) {
      final result = queuedResult;
      if (result is Exception) throw result;
      if (result is List<Shift>) return List<Shift>.unmodifiable(result);
      throw Exception(result.toString());
    }
    final error = listError;
    if (error != null) throw error;
    return List<Shift>.unmodifiable(listResponse ?? const []);
  }

  @override
  Future<ShiftDetail> getDetail(int shiftId, {String? token}) async {
    detailCalls += 1;
    detailCallIds.add(shiftId);
    final gateQueue = detailGateQueues[shiftId];
    final queuedGate =
        (gateQueue != null && gateQueue.isNotEmpty)
            ? gateQueue.removeAt(0)
            : null;
    final resultQueue = detailResults[shiftId];
    final hasQueuedResult = resultQueue != null && resultQueue.isNotEmpty;
    final queuedResult = hasQueuedResult ? resultQueue.removeAt(0) : null;
    final gate = queuedGate ?? detailGates[shiftId];
    if (gate != null) await gate.future;
    if (hasQueuedResult) {
      final result = queuedResult;
      if (result is Exception) throw result;
      if (result is ShiftDetail) return result;
      throw Exception(result.toString());
    }
    final specificError = detailErrors[shiftId];
    if (specificError != null) {
      if (specificError is Exception) throw specificError;
      throw specificError;
    }
    final error = defaultDetailError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    final response = detailResponses[shiftId];
    if (response != null) return response;
    throw const ApiException(
      code: 'NOT_FOUND',
      message: 'Shift not found.',
      statusCode: 404,
    );
  }

  @override
  Future<RegistrationResult> registerSelf(int shiftId, {String? token}) async {
    registrationCalls += 1;
    lastRegistrationShiftId = shiftId;
    lastRegistrationToken = token;
    final gate = registrationGate;
    if (gate != null) await gate.future;
    final error = registrationError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = registrationResponse;
    if (response == null) {
      throw const ApiException(
        code: 'NOT_FOUND',
        message: 'Shift not found.',
        statusCode: 404,
      );
    }
    return response;
  }

  @override
  Future<RegistrationResult> cancelSelf(
    int shiftId,
    int registrationId, {
    String? token,
  }) async {
    cancelCalls += 1;
    lastCancelShiftId = shiftId;
    lastCancelRegistrationId = registrationId;
    lastCancelToken = token;
    final gate = cancelGate;
    if (gate != null) await gate.future;
    final error = cancelError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = cancelResponse;
    if (response == null) {
      throw const ApiException(
        code: 'NOT_FOUND',
        message: 'Registration not found.',
        statusCode: 404,
      );
    }
    return response;
  }

  @override
  Future<ShiftDetail> createShift({
    required String? title,
    required DateTime date,
    required String startTime,
    required String endTime,
    required List<int> locationIds,
    String? token,
  }) async {
    createShiftCalls += 1;
    lastCreateTitle = title;
    lastCreateDate = date;
    lastCreateStartTime = startTime;
    lastCreateEndTime = endTime;
    lastCreateLocationIds = List<int>.unmodifiable(locationIds);
    lastCreateToken = token;
    final gate = createShiftGate;
    if (gate != null) await gate.future;
    final error = createShiftError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = createShiftResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No create response configured.',
      );
    }
    return response;
  }

  @override
  Future<Shift> updateShift(
    int shiftId, {
    required String? title,
    required DateTime date,
    required String startTime,
    required String endTime,
    String? token,
  }) async {
    updateShiftCalls += 1;
    lastUpdateShiftId = shiftId;
    lastUpdateTitle = title;
    lastUpdateDate = date;
    lastUpdateStartTime = startTime;
    lastUpdateEndTime = endTime;
    lastUpdateToken = token;
    final gate = updateShiftGate;
    if (gate != null) await gate.future;
    final error = updateShiftError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = updateShiftResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No update response configured.',
      );
    }
    return response;
  }

  @override
  Future<Shift> setShiftStatus(
    int shiftId,
    String status, {
    String? token,
  }) async {
    setStatusCalls += 1;
    lastSetStatusShiftId = shiftId;
    lastSetStatus = status;
    lastSetStatusToken = token;
    final gate = setStatusGate;
    if (gate != null) await gate.future;
    final error = setStatusError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = setStatusResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No status response configured.',
      );
    }
    return response;
  }

  @override
  Future<List<ShiftDetailLocation>> replaceShiftLocations(
    int shiftId, {
    required List<int> locationIds,
    String? token,
  }) async {
    replaceLocationsCalls += 1;
    lastReplaceLocationsShiftId = shiftId;
    lastReplaceLocationIds = List<int>.unmodifiable(locationIds);
    lastReplaceLocationsToken = token;
    final gate = replaceLocationsGate;
    if (gate != null) await gate.future;
    final error = replaceLocationsError;
    if (error != null) {
      if (error is Exception) throw error;
      throw error;
    }
    final response = replaceLocationsResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'No locations response configured.',
      );
    }
    return List<ShiftDetailLocation>.unmodifiable(response);
  }
}

/// In-memory [ProductsApi] fake: records calls and can fail on demand.
class FakeProductsApi implements ProductsApi {
  FakeProductsApi({this.products = const [], this.variants = const {}});

  List<CatalogProduct> products;
  Map<int, List<CatalogVariant>> variants;

  Object? listError;
  Object? defaultVariantsError;
  final Map<int, Object?> variantsErrors = <int, Object?>{};

  /// When set, every variant request waits for this gate.
  Completer<void>? variantsGate;

  /// The highest number of variant requests that were in flight at the same
  /// time.
  int maxVariantsInFlight = 0;
  int _variantsInFlight = 0;

  int listCalls = 0;
  final List<int> variantCalls = <int>[];
  String? lastToken;

  /// Makes every variant request hang until the returned gate is completed.
  Completer<void> setVariantsPending() {
    final completer = Completer<void>();
    variantsGate = completer;
    return completer;
  }

  @override
  Future<List<CatalogProduct>> listProducts({String? token}) async {
    listCalls++;
    lastToken = token;
    final error = listError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    return List<CatalogProduct>.unmodifiable(products);
  }

  @override
  Future<List<CatalogVariant>> getVariants(
    int productId, {
    String? token,
  }) async {
    variantCalls.add(productId);
    lastToken = token;
    _variantsInFlight += 1;
    if (_variantsInFlight > maxVariantsInFlight) {
      maxVariantsInFlight = _variantsInFlight;
    }
    try {
      final gate = variantsGate;
      if (gate != null) await gate.future;
      final error = variantsErrors[productId] ?? defaultVariantsError;
      if (error != null) {
        if (error is Exception) throw error;
        throw Exception(error.toString());
      }
      return List<CatalogVariant>.unmodifiable(variants[productId] ?? const []);
    } finally {
      _variantsInFlight -= 1;
    }
  }
}

/// In-memory [EntryApi] fake: records calls and can fail on demand.
class FakeEntryApi implements EntryApi {
  FakeEntryApi();

  EntryContext? contextResponse;
  Object? contextError;

  List<QuantityRecord>? submitResponse;
  Object? submitError;
  Completer<void>? submitGate;

  int contextCalls = 0;
  int submitCalls = 0;
  String? lastToken;
  int? lastShiftId;
  int? lastLocationId;
  List<({int variantId, int quantity})>? lastItems;

  @override
  Future<EntryContext> getEntryContext(int shiftId, {String? token}) async {
    contextCalls++;
    lastToken = token;
    lastShiftId = shiftId;
    final error = contextError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    final response = contextResponse;
    if (response == null) {
      throw const ApiException(
        code: 'NOT_FOUND',
        message: 'Shift not found.',
        statusCode: 404,
      );
    }
    return response;
  }

  @override
  Future<List<QuantityRecord>> submitQuantities(
    int shiftId, {
    required int locationId,
    required List<({int variantId, int quantity})> items,
    String? token,
  }) async {
    submitCalls++;
    lastToken = token;
    lastShiftId = shiftId;
    lastLocationId = locationId;
    lastItems = items;
    final gate = submitGate;
    if (gate != null) await gate.future;
    final error = submitError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    return List<QuantityRecord>.unmodifiable(submitResponse ?? const []);
  }
}

/// In-memory [AdminUsersApi] fake for deterministic tests.
class FakeAdminUsersApi extends AdminUsersApi {
  FakeAdminUsersApi() : super(_DummyApiClient());

  AdminUserPage? listPageResponse;
  Object? listError;
  Completer<void>? listGate;

  /// Per-call gates, consumed in request order.
  final List<Completer<void>> listGateQueue = <Completer<void>>[];

  /// Per-call results for list requests, bound at request time. Entries may be
  /// an [AdminUserPage] or an error to throw.
  final List<Object?> listResults = <Object?>[];

  int listCalls = 0;
  String? lastListToken;
  UserRole? lastListRole;
  bool? lastListIsActive;
  int? lastListPage;
  int? lastListPageSize;
  final List<({UserRole? role, bool? isActive, int page, int pageSize})>
  listRequests = <({UserRole? role, bool? isActive, int page, int pageSize})>[];

  AppUser? createResponse;
  Object? createError;
  Completer<void>? createGate;
  int createCalls = 0;
  String? lastCreateToken;
  String? lastCreateFirstName;
  String? lastCreateLastName;
  String? lastCreatePhone;
  UserRole? lastCreateRole;
  String? lastCreatePassword;

  AppUser? updateResponse;
  Object? updateError;
  Completer<void>? updateGate;
  int updateCalls = 0;
  String? lastUpdateToken;
  int? lastUpdateUserId;
  String? lastUpdateFirstName;
  String? lastUpdateLastName;
  String? lastUpdatePhone;

  AppUser? setStatusResponse;
  Object? setStatusError;
  Completer<void>? setStatusGate;
  int setStatusCalls = 0;
  String? lastSetStatusToken;
  int? lastSetStatusUserId;
  bool? lastSetStatusValue;

  Completer<void> setListPending() {
    final completer = Completer<void>();
    listGateQueue.add(completer);
    return completer;
  }

  Completer<void> setCreatePending() {
    final completer = Completer<void>();
    createGate = completer;
    return completer;
  }

  Completer<void> setUpdatePending() {
    final completer = Completer<void>();
    updateGate = completer;
    return completer;
  }

  Completer<void> setStatusPending() {
    final completer = Completer<void>();
    setStatusGate = completer;
    return completer;
  }

  @override
  Future<AdminUserPage> listUserPage({
    required String token,
    UserRole? role,
    bool? isActive,
    int page = 1,
    int pageSize = 20,
  }) async {
    listCalls++;
    lastListToken = token;
    lastListRole = role;
    lastListIsActive = isActive;
    lastListPage = page;
    lastListPageSize = pageSize;
    listRequests.add((
      role: role,
      isActive: isActive,
      page: page,
      pageSize: pageSize,
    ));

    final queuedResult = listResults.isEmpty ? null : listResults.removeAt(0);
    final queuedGate = listGateQueue.isEmpty ? null : listGateQueue.removeAt(0);
    final gate = queuedGate ?? listGate;
    if (gate != null) await gate.future;

    final error = listError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    if (queuedResult != null) {
      if (queuedResult is AdminUserPage) return queuedResult;
      if (queuedResult is Exception) throw queuedResult;
      throw Exception(queuedResult.toString());
    }
    final response = listPageResponse;
    if (response != null) return response;
    return AdminUserPage(
      users: const [],
      page: page,
      pageSize: pageSize,
      total: 0,
      totalPages: 0,
    );
  }

  @override
  Future<AppUser> createStaff({
    required String token,
    required String firstName,
    required String lastName,
    required String phone,
    required UserRole role,
    required String password,
  }) async {
    createCalls++;
    lastCreateToken = token;
    lastCreateFirstName = firstName;
    lastCreateLastName = lastName;
    lastCreatePhone = phone;
    lastCreateRole = role;
    lastCreatePassword = password;
    final gate = createGate;
    if (gate != null) await gate.future;
    final error = createError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    final response = createResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'The server returned an unexpected response.',
      );
    }
    return response;
  }

  @override
  Future<AppUser> updateUserProfile(
    int userId, {
    required String token,
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    updateCalls++;
    lastUpdateToken = token;
    lastUpdateUserId = userId;
    lastUpdateFirstName = firstName;
    lastUpdateLastName = lastName;
    lastUpdatePhone = phone;
    final gate = updateGate;
    if (gate != null) await gate.future;
    final error = updateError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    final response = updateResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'The server returned an unexpected response.',
      );
    }
    return response;
  }

  @override
  Future<AppUser> setUserStatus(
    int userId, {
    required String token,
    required bool isActive,
  }) async {
    setStatusCalls++;
    lastSetStatusToken = token;
    lastSetStatusUserId = userId;
    lastSetStatusValue = isActive;
    final gate = setStatusGate;
    if (gate != null) await gate.future;
    final error = setStatusError;
    if (error != null) {
      if (error is Exception) throw error;
      throw Exception(error.toString());
    }
    final response = setStatusResponse;
    if (response == null) {
      throw const ApiException(
        code: 'UNEXPECTED_RESPONSE',
        message: 'The server returned an unexpected response.',
      );
    }
    return response;
  }
}

class _DummyApiClient extends ApiClient {
  _DummyApiClient() : super(baseUrl: 'http://localhost:3001/api');
}
