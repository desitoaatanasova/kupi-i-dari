import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/location.dart';
import '../models/shift.dart';
import '../widgets/primary_button.dart';

/// Creates a new DRAFT shift or edits the metadata of an existing shift.
///
/// The backend creates shifts as DRAFT and only allows metadata changes while
/// a shift is DRAFT or OPEN. Location replacement is handled separately on the
/// shift detail screen, so an edit never changes the location set implicitly.
class ShiftEditorScreen extends StatefulWidget {
  const ShiftEditorScreen({super.key, this.shift, this.initialLocation});

  /// The shift to edit, or `null` to create a new one.
  final Shift? shift;

  /// A location preselected when the editor is opened from a filtered list.
  final Location? initialLocation;

  @override
  State<ShiftEditorScreen> createState() => _ShiftEditorScreenState();
}

class _ShiftEditorScreenState extends State<ShiftEditorScreen> {
  final _titleController = TextEditingController();
  final _dateController = TextEditingController();
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  final Set<int> _selectedLocationIds = <int>{};

  List<Location> _locations = const [];
  bool _loadingLocations = false;
  bool _locationsRequested = false;
  Object? _locationsError;
  bool _submitting = false;
  String? _formError;

  bool get _isEditing => widget.shift != null;

  @override
  void initState() {
    super.initState();
    final shift = widget.shift;
    if (shift != null) {
      _titleController.text = shift.title;
      _dateController.text = _formatDate(shift.date);
      _startController.text = _shortTime(shift.startTime);
      _endController.text = _shortTime(shift.endTime);
    } else {
      final location = widget.initialLocation;
      if (location != null) _selectedLocationIds.add(location.id);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isEditing || _locationsRequested) return;
    _locationsRequested = true;
    _loadLocations();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _dateController.dispose();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    if (!mounted) return;
    setState(() {
      _loadingLocations = true;
      _locationsError = null;
    });
    try {
      final token = SessionScope.maybeOf(context)?.session?.token;
      final api = ApiScope.maybeOf(context);
      if (api == null) {
        throw const ApiException(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Locations are unavailable.',
        );
      }
      final locations = await api.list(token: token);
      if (!mounted) return;
      setState(() {
        _locations = locations.where((location) => location.isActive).toList();
        _selectedLocationIds.removeWhere(
          (id) => !_locations.any((location) => location.id == id),
        );
        _loadingLocations = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
      }
      setState(() {
        _loadingLocations = false;
        _locationsError = error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingLocations = false;
        _locationsError = error;
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final title = _titleController.text.trim();
    if (title.length > 120) {
      setState(() => _formError = 'Заглавието може да е до 120 знака.');
      return;
    }
    final date = _parseDate(_dateController.text.trim());
    if (date == null) {
      setState(
        () => _formError = 'Въведете валидна дата във формат ГГГГ-ММ-ДД.',
      );
      return;
    }
    final start = _startController.text.trim();
    final end = _endController.text.trim();
    if (!_isTime(start) || !_isTime(end)) {
      setState(() => _formError = 'Въведете валиден час във формат ЧЧ:ММ.');
      return;
    }
    if (_minutes(end) <= _minutes(start)) {
      setState(
        () => _formError = 'Краят на смяната трябва да е след началото.',
      );
      return;
    }
    if (!_isEditing && _selectedLocationIds.isEmpty) {
      setState(() => _formError = 'Изберете поне един пункт.');
      return;
    }
    if (!_isEditing && _selectedLocationIds.length > 100) {
      setState(() => _formError = 'Може да изберете до 100 пункта.');
      return;
    }

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) {
      setState(() => _formError = AuthMessages.forCode('UNAUTHORIZED'));
      return;
    }
    final api = ApiScope.maybeShiftsOf(context);
    if (api == null) {
      setState(() => _formError = AuthMessages.fallback);
      return;
    }

    setState(() {
      _submitting = true;
      _formError = null;
    });

    try {
      if (_isEditing) {
        await api.updateShift(
          widget.shift!.id,
          title: title.isEmpty ? null : title,
          date: date,
          startTime: start,
          endTime: end,
          token: token,
        );
      } else {
        await api.createShift(
          title: title.isEmpty ? null : title,
          date: date,
          startTime: start,
          endTime: end,
          locationIds: _selectedLocationIds.toList()..sort(),
          token: token,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() {
        _submitting = false;
        _formError = AuthMessages.forException(error);
      });
      if (!_isEditing && error.code == 'INVALID_LOCATION') {
        _locationsRequested = false;
        await _loadLocations();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = AuthMessages.fallback;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Редактиране на смяна' : 'Нова смяна'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: [
            TextFormField(
              key: const Key('shift-title-field'),
              controller: _titleController,
              enabled: !_submitting,
              maxLength: 120,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Заглавие (по избор)',
                hintText: 'Например: Сутрешна смяна',
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextFormField(
              key: const Key('shift-date-field'),
              controller: _dateController,
              enabled: !_submitting,
              keyboardType: TextInputType.datetime,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Дата',
                hintText: 'ГГГГ-ММ-ДД',
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    key: const Key('shift-start-field'),
                    controller: _startController,
                    enabled: !_submitting,
                    keyboardType: TextInputType.datetime,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Начало',
                      hintText: 'ЧЧ:ММ',
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: TextFormField(
                    key: const Key('shift-end-field'),
                    controller: _endController,
                    enabled: !_submitting,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: 'Край',
                      hintText: 'ЧЧ:ММ',
                    ),
                  ),
                ),
              ],
            ),
            if (!_isEditing) ...[
              const SizedBox(height: AppTokens.spaceXl),
              const Text(
                'Пунктове',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppTokens.spaceXs),
              const Text(
                'Изберете поне един активен пункт за новата смяна.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              _buildLocationPicker(),
            ],
            if (_formError != null) ...[
              const SizedBox(height: AppTokens.spaceLg),
              Text(
                _formError!,
                key: const Key('shift-form-error'),
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: AppTokens.spaceXl),
            PrimaryButton(
              label: _isEditing ? 'Запази промените' : 'Създай смяна',
              icon: _isEditing ? Icons.save_outlined : Icons.add,
              busy: _submitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationPicker() {
    if (_loadingLocations) {
      return const Padding(
        padding: EdgeInsets.all(AppTokens.spaceLg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_locationsError != null) {
      final message =
          _locationsError is ApiException
              ? AuthMessages.forException(_locationsError as ApiException)
              : 'Възникна грешка при зареждане на пунктовете.';
      return Column(
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: AppTokens.spaceSm),
          TextButton(onPressed: _loadLocations, child: const Text('Повтори')),
        ],
      );
    }
    if (_locations.isEmpty) {
      return const Text(
        'Няма активни пунктове. Създайте или активирайте пункт, преди да '
        'създадете смяна.',
        style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
      );
    }
    return Column(
      children: [
        for (final location in _locations)
          CheckboxListTile(
            value: _selectedLocationIds.contains(location.id),
            onChanged:
                _submitting
                    ? null
                    : (selected) {
                      setState(() {
                        if (selected ?? false) {
                          _selectedLocationIds.add(location.id);
                        } else {
                          _selectedLocationIds.remove(location.id);
                        }
                      });
                    },
            title: Text(location.name),
            subtitle: Text(location.address),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
      ],
    );
  }

  static String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static String _shortTime(String value) {
    final parts = value.split(':');
    if (parts.length >= 2) return '${parts[0]}:${parts[1]}';
    return value;
  }

  static DateTime? _parseDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    final parts = value.split('-');
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  static bool _isTime(String value) {
    return RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value);
  }

  static int _minutes(String value) {
    final parts = value.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}
