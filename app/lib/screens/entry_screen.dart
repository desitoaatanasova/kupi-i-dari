import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/api/products_api.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/catalog_product.dart';
import '../models/entry_context.dart';
import '../models/location.dart';
import '../widgets/category_card.dart';
import '../widgets/primary_button.dart';
import '../widgets/product_sticker_card.dart';

/// Volunteer-facing quantity entry for one shift (Phase 19).
///
/// Reached from a specific shift's detail screen with its [shiftId]. All data
/// (shift, locations, products, variants) comes from the backend; when no
/// shift id is supplied no data is loaded and an instruction state is shown.
/// A failed API request never falls back to sample data.
class EntryScreen extends StatefulWidget {
  const EntryScreen({super.key, this.shiftId});

  final int? shiftId;

  @override
  State<EntryScreen> createState() => _EntryScreenState();
}

enum _EntryStatus { idle, loading, ready, error }

class _EntryScreenState extends State<EntryScreen> {
  static const int _maxQuantity = 2147483647;

  /// Maximum number of variant requests that may run at the same time.
  static const int _variantConcurrency = 6;

  /// Message shown when the pending quantities are dropped because the
  /// volunteer switched the point they belong to.
  static const String _pointChangedMessage =
      'Количествата са изчистени, защото сменихте пункта.';

  bool _loaded = false;

  _EntryStatus _status = _EntryStatus.idle;
  Object? _error;

  EntryContext? _context;
  List<CatalogProduct> _products = const [];
  final Map<int, List<CatalogVariant>> _variantsByProduct = {};
  String? _selectedCategory;

  int? _locationId;
  final Map<int, int> _quantities = <int, int>{};

  /// The stored quantity rows known locally.
  ///
  /// Seeded from the entry context and updated with the rows returned by a
  /// successful submission. The rows of every point of the shift are kept, so
  /// the "saved on the server" marker can be scoped to the selected point.
  List<QuantityRecord> _quantityRows = const [];

  bool _submitting = false;

  bool get _hasShiftId => widget.shiftId != null && widget.shiftId! > 0;

  int get _total => _quantities.values.fold(0, (sum, value) => sum + value);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    if (!_hasShiftId) {
      _status = _EntryStatus.idle;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final entryApi = ApiScope.maybeEntryOf(context);
    final productsApi = ApiScope.maybeProductsOf(context);
    if (entryApi == null || productsApi == null) {
      setState(() {
        _status = _EntryStatus.error;
        _error = null;
      });
      return;
    }

    setState(() {
      _status = _EntryStatus.loading;
      _error = null;
    });

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;

    try {
      final context_ = await entryApi.getEntryContext(
        widget.shiftId!,
        token: token,
      );
      final products = await productsApi.listProducts(token: token);
      final variantsByProduct = await _loadVariants(
        products,
        productsApi,
        token: token,
      );

      if (!mounted) return;
      setState(() {
        _context = context_;
        _products = products;
        _variantsByProduct
          ..clear()
          ..addAll(variantsByProduct);
        _selectedCategory = _firstCategory(products);
        _locationId = _initialLocationId(context_.locations);
        _quantities.clear();
        _quantityRows = context_.quantities;
        _status = _EntryStatus.ready;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
      }
      setState(() {
        _status = _EntryStatus.error;
        _error = error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _EntryStatus.error;
        _error = error;
      });
    }
  }

  /// Loads the variants of every product with a bounded worker pool.
  ///
  /// The request count is unchanged (exactly one request per product) and at
  /// most [_variantConcurrency] requests run at the same time, so a large
  /// catalog loads much faster without flooding the backend. A failing
  /// request fails the whole load, exactly like the sequential load did: a
  /// partially loaded catalog is never presented as loaded.
  Future<Map<int, List<CatalogVariant>>> _loadVariants(
    List<CatalogProduct> products,
    ProductsApi productsApi, {
    String? token,
  }) async {
    final variantsByProduct = <int, List<CatalogVariant>>{};
    Object? failure;
    StackTrace? failureStack;

    var index = 0;
    final workers = <Future<void>>[];

    void startWorker() {
      if (index >= products.length) return;
      final product = products[index];
      index += 1;
      workers.add(() async {
        try {
          variantsByProduct[product.id] = await productsApi.getVariants(
            product.id,
            token: token,
          );
        } catch (error, stack) {
          // The first failure wins, but every worker is awaited so no
          // asynchronous error is left unhandled.
          failure ??= error;
          failureStack ??= stack;
        }
      }());
    }

    while (workers.length < _variantConcurrency && index < products.length) {
      startWorker();
    }

    while (workers.isNotEmpty) {
      await workers.removeAt(0);
      if (index < products.length) {
        startWorker();
      }
    }

    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    return variantsByProduct;
  }

  static String? _firstCategory(List<CatalogProduct> products) {
    for (final product in products) {
      return product.category ?? '';
    }
    return null;
  }

  static int? _initialLocationId(List<Location> locations) {
    if (locations.length == 1) return locations.first.id;
    return null;
  }

  /// The variant ids that already have a stored row **for the selected
  /// point**.
  ///
  /// The entry context contains the rows of every point of the shift, so a
  /// row of another point must never be marked as saved for this one.
  Set<int> get _savedVariantIds {
    final locationId = _locationId;
    if (locationId == null) return const <int>{};
    return <int>{
      for (final row in _quantityRows)
        if (row.locationId == locationId) row.variantId,
    };
  }

  /// Replaces the stored rows with the rows a successful submission returned.
  ///
  /// The submission is an absolute replacement of the **listed** variants of the
  /// submitted point only: a variant that was not part of the batch keeps its
  /// stored row. The rows of every other point stay untouched.
  static List<QuantityRecord> _mergeRows(
    List<QuantityRecord> existing,
    List<QuantityRecord> saved,
  ) {
    final savedKeys = <(int, int)>{
      for (final row in saved) (row.locationId, row.variantId),
    };
    final merged = <QuantityRecord>[
      for (final row in existing)
        if (!savedKeys.contains((row.locationId, row.variantId))) row,
    ];
    merged.addAll(saved);
    return merged;
  }

  List<String> get _categories {
    final seen = <String>[];
    final hasNull = <bool>[false];
    for (final product in _products) {
      if (product.category == null) {
        hasNull[0] = true;
      } else if (!seen.contains(product.category)) {
        seen.add(product.category!);
      }
    }
    final categories = <String>[...seen];
    if (hasNull[0]) categories.add('');
    return categories;
  }

  static String _categoryLabel(String category) =>
      category.isEmpty ? 'Без категория' : category;

  List<CatalogProduct> get _visibleProducts {
    final selected = _selectedCategory;
    if (selected == null) return const [];
    return _products
        .where((product) => (product.category ?? '') == selected)
        .toList();
  }

  void _changeQuantity(int variantId, int delta) {
    setState(() {
      final current = _quantities[variantId] ?? 0;
      final next = current + delta;
      if (next <= 0) {
        _quantities.remove(variantId);
      } else if (next > _maxQuantity) {
        _quantities[variantId] = _maxQuantity;
      } else {
        _quantities[variantId] = next;
      }
    });
  }

  /// Switches the point the quantities are reported for.
  ///
  /// The pending quantities belong to the point they were entered for, so they
  /// are dropped when the point changes. Otherwise they would be submitted for
  /// the new point and would silently overwrite another point's numbers.
  void _changeLocation(int? locationId) {
    if (locationId == null || locationId == _locationId) return;

    final hadPendingQuantities = _quantities.isNotEmpty;
    setState(() {
      _locationId = locationId;
      _quantities.clear();
    });

    if (!hadPendingQuantities) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(_pointChangedMessage)));
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final context_ = _context;
    if (context_ == null) return;

    final messenger = ScaffoldMessenger.of(context);
    if (_total <= 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Въведете поне едно количество.')),
      );
      return;
    }
    final locationId = _locationId;
    if (locationId == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Изберете пункт, преди да изпратите.')),
      );
      return;
    }

    final entryApi = ApiScope.maybeEntryOf(context);
    if (entryApi == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text(AuthMessages.fallback)),
      );
      return;
    }

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;

    setState(() => _submitting = true);
    try {
      final saved = await entryApi.submitQuantities(
        widget.shiftId!,
        locationId: locationId,
        items: [
          for (final entry in _quantities.entries)
            (variantId: entry.key, quantity: entry.value),
        ],
        token: token,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _quantityRows = _mergeRows(_quantityRows, saved);
        _quantities.clear();
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Количествата са записани успешно.')),
      );
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
      }
      if (!mounted) return;
      // Preserve every entered quantity so the batch can be retried.
      setState(() => _submitting = false);
      messenger.showSnackBar(
        SnackBar(content: Text(AuthMessages.forException(error))),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(
        const SnackBar(content: Text(AuthMessages.fallback)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Отчитане на количества')),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (!_hasShiftId) {
      return const _EntryMessage(
        icon: Icons.event_outlined,
        message:
            'Изберете смяна от екрана с детайли, за да отчетете количества.',
      );
    }
    switch (_status) {
      case _EntryStatus.idle:
      case _EntryStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case _EntryStatus.error:
        return _buildError();
      case _EntryStatus.ready:
        return _buildReady();
    }
  }

  Widget _buildError() {
    final message =
        _error is ApiException
            ? AuthMessages.forException(_error as ApiException)
            : 'Възникна грешка при зареждане на отчитането.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextButton(onPressed: _load, child: const Text('Повтори')),
          ],
        ),
      ),
    );
  }

  Widget _buildReady() {
    final context_ = _context!;
    final locations = context_.locations;
    final categories = _categories;
    final products = _visibleProducts;
    final canSubmit = context_.canSubmit;
    final submissionError = context_.submissionError;

    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      children: [
        Text(
          context_.shift.title.isEmpty ? 'Смяна' : context_.shift.title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppTokens.spaceMd),
        if (submissionError != null)
          _SubmissionNotice(error: submissionError)
        else if (!canSubmit)
          const _SubmissionNotice(error: null),
        if (submissionError != null || !canSubmit)
          const SizedBox(height: AppTokens.spaceLg),
        if (locations.isEmpty)
          const Text(
            'Няма налични пунктове за тази смяна.',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          )
        else ...[
          DropdownButtonFormField<int>(
            value: _locationId,
            decoration: const InputDecoration(labelText: 'Пункт'),
            items: [
              for (final location in locations)
                DropdownMenuItem<int>(
                  value: location.id,
                  child: Text(location.name),
                ),
            ],
            onChanged: _submitting ? null : (value) => _changeLocation(value),
          ),
          const SizedBox(height: AppTokens.spaceLg),
        ],
        if (products.isEmpty && _products.isEmpty)
          const Text(
            'Няма налични продукти в каталога.',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          )
        else ...[
          for (final category in categories)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
              child: CategoryCard.labelled(
                name: _categoryLabel(category),
                productCount:
                    _products
                        .where((p) => (p.category ?? '') == category)
                        .length,
                selected: category == _selectedCategory,
                onTap:
                    _submitting
                        ? null
                        : () => setState(() => _selectedCategory = category),
              ),
            ),
          const SizedBox(height: AppTokens.spaceMd),
          Text(
            'Продукти — ${products.length} бр.',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          for (final product in products)
            _ProductEntry(
              product: product,
              variants: _variantsByProduct[product.id] ?? const [],
              quantities: _quantities,
              savedVariantIds: _savedVariantIds,
              enabled: canSubmit && !_submitting,
              onIncrease: _changeQuantity,
            ),
          const SizedBox(height: AppTokens.spaceMd),
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            decoration: BoxDecoration(
              color: AppColors.backgroundSecondary,
              borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
            ),
            child: Row(
              children: [
                const Text(
                  'Общо:',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '$_total',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppTokens.spaceLg),
        Semantics(
          button: true,
          enabled: canSubmit && !_submitting,
          label: 'Изпрати',
          child: PrimaryButton(
            label: 'Изпрати',
            icon: Icons.send_outlined,
            busy: _submitting,
            onPressed: canSubmit ? _submit : null,
          ),
        ),
        const SizedBox(height: AppTokens.spaceLg),
      ],
    );
  }
}

/// Per-product block: one card per active variant (or a single card when the
/// product has no variants).
class _ProductEntry extends StatelessWidget {
  const _ProductEntry({
    required this.product,
    required this.variants,
    required this.quantities,
    required this.savedVariantIds,
    required this.enabled,
    required this.onIncrease,
  });

  final CatalogProduct product;
  final List<CatalogVariant> variants;
  final Map<int, int> quantities;
  final Set<int> savedVariantIds;
  final bool enabled;
  final void Function(int variantId, int delta) onIncrease;

  @override
  Widget build(BuildContext context) {
    if (variants.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final variant in variants)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProductStickerCard.labelled(
                  name: product.name,
                  unitLabel: variant.unitLabel,
                  quantity: quantities[variant.id] ?? 0,
                  enabled: enabled,
                  onIncrease: () => onIncrease(variant.id, 1),
                  onDecrease: () => onIncrease(variant.id, -1),
                  onIncreaseLongPress: () => onIncrease(variant.id, 10),
                  onDecreaseLongPress: () => onIncrease(variant.id, -10),
                ),
                if (savedVariantIds.contains(variant.id))
                  Padding(
                    padding: const EdgeInsets.only(
                      left: AppTokens.spaceSm,
                      top: 2,
                    ),
                    child: Semantics(
                      label: 'Записано на сървъра',
                      child: Text(
                        'Записано на сървъра',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Small immutable view model so [CategoryCard] can be reused without the demo
/// [Category] model (which carries a local icon).
class CategoryView {
  const CategoryView({required this.name, required this.count});

  final String name;
  final int count;
}

class _SubmissionNotice extends StatelessWidget {
  const _SubmissionNotice({required this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final message =
        error == null
            ? 'В момента не можете да отчитате количества за тази смяна.'
            : AuthMessages.forCode(error!);
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.secondary, size: 20),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}

class _EntryMessage extends StatelessWidget {
  const _EntryMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textTertiary),
            const SizedBox(height: AppTokens.spaceMd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
