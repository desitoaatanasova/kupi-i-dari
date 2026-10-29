import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/models/catalog_product.dart';
import 'package:kupi_i_dari/models/entry_context.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/models/shift.dart';
import 'package:kupi_i_dari/screens/entry_screen.dart';
import 'package:kupi_i_dari/widgets/primary_button.dart';
import 'package:kupi_i_dari/widgets/product_sticker_card.dart';

import 'fakes.dart';

/// Phase 23 — the entry screen must not report quantities for a point the
/// volunteer did not choose, must load the catalog with a bounded number of
/// parallel requests and must never show an invented "saved on the server"
/// marker for another point.

const _locationOne = Location(
  id: 1,
  name: 'Център',
  address: 'ул. Витоша 1',
  isActive: true,
);

const _locationTwo = Location(
  id: 2,
  name: 'Студентски',
  address: 'ул. Гущера 5',
  isActive: true,
);

const _savedMarker = 'Записано на сървъра';

EntryContext _buildContext({
  List<Location> locations = const [_locationOne],
  List<QuantityRecord> quantities = const [],
  bool canSubmit = true,
  String? submissionError,
}) {
  return EntryContext(
    shift: Shift(
      id: 5,
      title: 'Смяна в центъра',
      date: DateTime(2026, 3, 2),
      startTime: '09:00:00',
      endTime: '13:00:00',
      locationIds: [1, 2],
      status: ShiftStatus.available,
    ),
    canSubmit: canSubmit,
    submissionError: submissionError,
    entryWindow: const EntryWindow(
      opensAt: '2026-03-02T09:00:00+02:00',
      closesAt: '2026-03-02T13:30:00+02:00',
    ),
    locations: locations,
    quantities: quantities,
  );
}

/// Three products in a single category, each with exactly one variant.
FakeProductsApi _buildProducts() {
  return FakeProductsApi(
    products: const [
      CatalogProduct(
        id: 10,
        name: 'Шампоан',
        category: 'Хигиена',
        isActive: true,
      ),
      CatalogProduct(
        id: 11,
        name: 'Сапун',
        category: 'Хигиена',
        isActive: true,
      ),
      CatalogProduct(id: 12, name: 'Ориз', category: 'Хигиена', isActive: true),
    ],
    variants: const {
      10: [
        CatalogVariant(
          id: 100,
          productId: 10,
          unitLabel: 'бутилка',
          unitValue: 0.5,
          isActive: true,
        ),
      ],
      11: [
        CatalogVariant(
          id: 110,
          productId: 11,
          unitLabel: 'бр',
          unitValue: null,
          isActive: true,
        ),
      ],
      12: [
        CatalogVariant(
          id: 120,
          productId: 12,
          unitLabel: 'кг',
          unitValue: null,
          isActive: true,
        ),
      ],
    },
  );
}

FakeProductsApi _buildManyProducts(int count) {
  return FakeProductsApi(
    products: [
      for (var index = 0; index < count; index++)
        CatalogProduct(
          id: 1000 + index,
          name: 'Продукт $index',
          category: 'Хигиена',
          isActive: true,
        ),
    ],
    variants: {
      for (var index = 0; index < count; index++)
        1000 + index: [
          CatalogVariant(
            id: 10000 + index,
            productId: 1000 + index,
            unitLabel: 'бр',
            unitValue: null,
            isActive: true,
          ),
        ],
    },
  );
}

Future<SessionController> _volunteerSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.identifyVolunteer(
    firstName: 'Иван',
    lastName: 'Петров',
    phone: '0888123456',
  );
  return controller;
}

void _setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpEntry(
  WidgetTester tester, {
  required SessionController session,
  required FakeEntryApi entryApi,
  required FakeProductsApi productsApi,
  bool settle = true,
}) async {
  _setLargeSurface(tester);
  await tester.pumpWidget(
    SessionScope(
      controller: session,
      child: ApiScope(
        adminUsersApi: FakeAdminUsersApi(),
        locationsApi: FakeLocationsApi(),
        shiftsApi: FakeShiftsApi(),
        productsApi: productsApi,
        entryApi: entryApi,
        child: const MaterialApp(home: EntryScreen(shiftId: 5)),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

Future<void> _settleSnackbar(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump();
}

/// Selects a point in the "Пункт" dropdown.
Future<void> _selectPoint(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// The product card the "saved on the server" marker belongs to.
///
/// The marker is rendered directly below the card of its variant.
String _productOfMarker(WidgetTester tester) {
  final marker = find.text(_savedMarker);
  final markerTop = tester.getTopLeft(marker).dy;
  final cards = find.byType(ProductStickerCard);
  String? name;
  var best = double.negativeInfinity;
  for (var index = 0; index < cards.evaluate().length; index++) {
    final card = cards.at(index);
    final top = tester.getTopLeft(card).dy;
    if (top <= markerTop && top > best) {
      best = top;
      name = tester.widget<ProductStickerCard>(card).name;
    }
  }
  return name ?? '';
}

void main() {
  group('EntryScreen catalog loading', () {
    testWidgets('loads the variants with at most six parallel requests', (
      tester,
    ) async {
      final session = await _volunteerSession();
      final entryApi = FakeEntryApi()..contextResponse = _buildContext();
      final productsApi = _buildManyProducts(10);
      final gate = productsApi.setVariantsPending();

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
        settle: false,
      );
      await tester.pump();
      await tester.pump();

      // Six requests run at the same time; the rest wait for a free slot.
      expect(productsApi.maxVariantsInFlight, 6);
      expect(productsApi.variantCalls.length, 6);

      gate.complete();
      await tester.pumpAndSettle();

      // Every product is still requested exactly once.
      expect(productsApi.variantCalls.length, 10);
      expect(productsApi.variantCalls.toSet().length, 10);
      expect(find.text('Продукти — 10 бр.'), findsOneWidget);
    });

    testWidgets('fails the whole load when one variant request fails', (
      tester,
    ) async {
      final session = await _volunteerSession();
      final entryApi = FakeEntryApi()..contextResponse = _buildContext();
      final productsApi =
          _buildProducts()
            ..variantsErrors[11] = buildError(500, 'INTERNAL_ERROR');

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
      );

      expect(find.text('Повтори'), findsOneWidget);
      // A partially loaded catalog is never presented as loaded.
      expect(find.text('Шампоан'), findsNothing);
      expect(find.text('Продукти — 3 бр.'), findsNothing);
    });
  });

  group('EntryScreen point selection', () {
    testWidgets('clears the pending quantities when the point changes', (
      tester,
    ) async {
      final session = await _volunteerSession();
      final entryApi =
          FakeEntryApi()
            ..contextResponse = _buildContext(
              locations: const [_locationOne, _locationTwo],
            );
      final productsApi = _buildProducts();

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
      );

      await _selectPoint(tester, 'Център');
      await tester.tap(find.byTooltip('Увеличи').first);
      await tester.pump();
      expect(find.text('1'), findsWidgets);

      await _selectPoint(tester, 'Студентски');

      // The pending quantity belonged to the previous point and is dropped.
      expect(
        find.text('Количествата са изчистени, защото сменихте пункта.'),
        findsOneWidget,
      );
      expect(find.text('1'), findsNothing);
      await _settleSnackbar(tester);

      // An empty batch is never sent to the backend.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
      await tester.pump();
      expect(find.text('Въведете поне едно количество.'), findsOneWidget);
      expect(entryApi.submitCalls, 0);
      await _settleSnackbar(tester);

      // The next submission belongs to the newly selected point.
      await tester.tap(find.byTooltip('Увеличи').first);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
      await tester.pumpAndSettle();

      expect(entryApi.submitCalls, 1);
      expect(entryApi.lastLocationId, 2);
    });

    testWidgets('marks only the rows of the selected point as saved', (
      tester,
    ) async {
      final session = await _volunteerSession();
      final entryApi =
          FakeEntryApi()
            ..contextResponse = _buildContext(
              locations: const [_locationOne, _locationTwo],
              quantities: const [
                QuantityRecord(
                  id: 1,
                  shiftId: 5,
                  locationId: 1,
                  variantId: 100,
                  quantity: 5,
                ),
                QuantityRecord(
                  id: 2,
                  shiftId: 5,
                  locationId: 2,
                  variantId: 120,
                  quantity: 7,
                ),
              ],
            );
      final productsApi = _buildProducts();

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
      );

      await _selectPoint(tester, 'Център');
      expect(find.text(_savedMarker), findsOneWidget);
      expect(_productOfMarker(tester), 'Шампоан');

      await _selectPoint(tester, 'Студентски');
      expect(find.text(_savedMarker), findsOneWidget);
      expect(_productOfMarker(tester), 'Ориз');
    });

    testWidgets(
      'a successful submission replaces only the rows of the submitted point',
      (tester) async {
        final session = await _volunteerSession();
        final entryApi =
            FakeEntryApi()
              ..contextResponse = _buildContext(
                locations: const [_locationOne, _locationTwo],
                quantities: const [
                  QuantityRecord(
                    id: 1,
                    shiftId: 5,
                    locationId: 1,
                    variantId: 100,
                    quantity: 5,
                  ),
                  QuantityRecord(
                    id: 2,
                    shiftId: 5,
                    locationId: 2,
                    variantId: 120,
                    quantity: 7,
                  ),
                ],
              )
              ..submitResponse = const [
                QuantityRecord(
                  id: 3,
                  shiftId: 5,
                  locationId: 1,
                  variantId: 110,
                  quantity: 3,
                ),
              ];
        final productsApi = _buildProducts();

        await _pumpEntry(
          tester,
          session: session,
          entryApi: entryApi,
          productsApi: productsApi,
        );

        await _selectPoint(tester, 'Център');
        expect(find.text(_savedMarker), findsOneWidget);

        // Report a quantity for a second variant of the same point.
        await tester.tap(find.byTooltip('Увеличи').at(1));
        await tester.pump();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
        await tester.pumpAndSettle();

        expect(entryApi.submitCalls, 1);
        expect(entryApi.lastLocationId, 1);
        expect(find.text('Количествата са записани успешно.'), findsOneWidget);

        // The submitted point now knows both of its rows.
        expect(find.text(_savedMarker), findsNWidgets(2));

        // The rows of the other point are untouched.
        await _selectPoint(tester, 'Студентски');
        expect(find.text(_savedMarker), findsOneWidget);
        expect(_productOfMarker(tester), 'Ориз');

        await _selectPoint(tester, 'Център');
        expect(find.text(_savedMarker), findsNWidgets(2));
      },
    );
  });

  group('EntryScreen accessibility semantics', () {
    testWidgets('the submit action exposes Изпрати and is enabled', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final session = await _volunteerSession();
      final entryApi = FakeEntryApi()..contextResponse = _buildContext();

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: _buildProducts(),
      );

      final node = tester.getSemantics(find.byType(PrimaryButton));
      expect(node.label, contains('Изпрати'));
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);

      semantics.dispose();
    });

    testWidgets('the submit action exposes its disabled state', (tester) async {
      final semantics = tester.ensureSemantics();
      final session = await _volunteerSession();
      final entryApi =
          FakeEntryApi()
            ..contextResponse = _buildContext(
              canSubmit: false,
              submissionError: 'REGISTRATION_REQUIRED',
            );

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: _buildProducts(),
      );

      final node = tester.getSemantics(find.byType(PrimaryButton));
      expect(node.label, contains('Изпрати'));
      expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);

      semantics.dispose();
    });

    testWidgets('the saved confirmation exposes its label', (tester) async {
      final semantics = tester.ensureSemantics();
      final session = await _volunteerSession();
      final entryApi =
          FakeEntryApi()
            ..contextResponse = _buildContext(
              quantities: const [
                QuantityRecord(
                  id: 1,
                  shiftId: 5,
                  locationId: 1,
                  variantId: 100,
                  quantity: 5,
                ),
              ],
            );

      await _pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: _buildProducts(),
      );

      expect(find.text(_savedMarker), findsOneWidget);
      final node = tester.getSemantics(find.text(_savedMarker));
      expect(node.label, contains(_savedMarker));

      semantics.dispose();
    });
  });
}
