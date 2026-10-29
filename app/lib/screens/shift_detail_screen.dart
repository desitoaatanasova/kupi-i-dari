import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/api/shifts_api.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/registration_scope.dart';
import '../core/session/session_scope.dart';
import '../core/statuses.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';
import '../models/location.dart';
import '../models/shift.dart';
import '../widgets/primary_button.dart';
import '../widgets/status_chip.dart';
import 'entry_screen.dart';
import 'shift_editor_screen.dart';

class ShiftDetailScreen extends StatefulWidget {
  const ShiftDetailScreen({super.key, required this.shift, this.onChanged});

  final Shift shift;

  /// Called after a confirmed admin mutation so a parent list can refresh.
  final VoidCallback? onChanged;

  @override
  State<ShiftDetailScreen> createState() => _ShiftDetailScreenState();
}

class _ShiftDetailScreenState extends State<ShiftDetailScreen> {
  bool _loadingDetail = true;
  bool _detailLoaded = false;
  Object? _detailError;
  Shift? _shift;
  List<ShiftDetailLocation> _locations = const [];

  /// The caller's registration status as reported by the backend detail
  /// (`REGISTERED` / `CANCELLED`) or `null` when none exists.
  String? _registrationStatus;

  /// Bumped every time the backend confirms a registration or a cancellation.
  /// A detail response that was requested before that confirmation can never
  /// overwrite the newer, confirmed state.
  int _registrationRevision = 0;

  /// True while the backend confirmed a cancellation during this session.
  ///
  /// A confirmed cancellation is never undone by a server status that still
  /// reports the pre-cancellation registration.
  bool _cancellationConfirmed = false;

  /// A registration request is currently in flight.
  bool _registering = false;

  /// A cancellation request is currently in flight.
  bool _cancelling = false;

  /// An admin mutation is currently in flight.
  bool _adminBusy = false;

  /// Bumped after every confirmed admin mutation. A detail response requested
  /// before that confirmation can never restore stale metadata or status.
  int _adminRevision = 0;

  @override
  void initState() {
    super.initState();
    _shift = widget.shift;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_detailLoaded) return;
    _detailLoaded = true;
    if (ApiScope.maybeShiftsOf(context) == null) {
      _loadingDetail = false;
    } else {
      _loadDetail();
    }
  }

  /// Loads the shift detail from the backend.
  ///
  /// A [silent] refresh reconciles the visible state without replacing the
  /// screen with a loading indicator; it is used after a registration attempt
  /// so a confirmed registration is never lost to a failing or stale reload.
  Future<void> _loadDetail({bool silent = false}) async {
    if (!mounted) return;
    // Remember the confirmed state so a response that arrives after a
    // confirmed registration cannot undo it.
    final requestRevision = _registrationRevision;
    final requestAdminRevision = _adminRevision;
    setState(() {
      if (!silent) {
        _loadingDetail = true;
      }
      _detailError = null;
    });

    try {
      final session = SessionScope.maybeOf(context);
      final token = session?.session?.token;
      // The response belongs to the user the request was made for.
      final requestUserId = session?.user?.id;
      final api = ApiScope.maybeShiftsOf(context);
      if (api == null) {
        if (!mounted) return;
        setState(() {
          _loadingDetail = false;
        });
        return;
      }
      final detail = await api.getDetail(widget.shift.id, token: token);
      if (!mounted) return;
      if (requestAdminRevision != _adminRevision) return;
      final serverStatus = detail.myRegistration?.status;
      // A response that raced with a confirmed registration or cancellation is
      // not authoritative for the registration state.
      final authoritative = requestRevision == _registrationRevision;
      // A missing status never erases a confirmed registration.
      var effectiveStatus =
          (serverStatus != null || _registrationStatus == null)
              ? serverStatus
              : _registrationStatus;
      // A confirmed cancellation is never undone by a server status that still
      // reports the pre-cancellation registration.
      if (_cancellationConfirmed && effectiveStatus == 'REGISTERED') {
        effectiveStatus = _registrationStatus;
      }
      setState(() {
        _shift = detail.shift;
        _locations = detail.locations;
        if (authoritative) {
          _registrationStatus = effectiveStatus;
        }
        _loadingDetail = false;
      });
      if (authoritative) {
        _publishRegistrationStatus(requestUserId, effectiveStatus);
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
      }
      if (silent) return;
      setState(() {
        _detailError = error;
        _loadingDetail = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (silent) return;
      setState(() {
        _detailError = error;
        _loadingDetail = false;
      });
    }
  }

  /// The volunteer is registered only when the backend says `REGISTERED`.
  /// A `CANCELLED` registration is not a registration: the backend reactivates
  /// that row with `200` when the volunteer registers again.
  bool get _isRegistered => _registrationStatus == 'REGISTERED';

  /// Whether the current volunteer may register for this shift.
  ///
  /// The register action is offered only to an authenticated volunteer, for an
  /// open shift, when the volunteer is not registered yet. While a request is
  /// in flight the action is not available, but the button stays visible and
  /// disabled so the pending state is visible to the user.
  bool get _canRegister {
    if (_isRegistered) return false;
    final session = SessionScope.maybeOf(context);
    if (session == null || !session.isAuthenticated) return false;
    if (session.role != UserRole.volunteer) return false;
    if (session.session?.token == null) return false;
    return (_shift ?? widget.shift).status == ShiftStatus.available;
  }

  Future<void> _register() async {
    if (_registering) return;
    if (!_canRegister) return;

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (session == null || !session.isAuthenticated || token == null) return;
    final userId = session.user?.id;

    final api = ApiScope.maybeShiftsOf(context);
    if (api == null) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _registering = true);
    try {
      final result = await api.registerSelf(widget.shift.id, token: token);
      if (!mounted) return;
      // The backend confirmed the registration: only now is it reported.
      setState(() {
        _registering = false;
        _registrationStatus = result.status;
        _cancellationConfirmed = false;
        _registrationRevision += 1;
      });
      _publishRegistrationStatus(
        userId,
        result.status,
        registrationId: result.id,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Записахте се успешно.')),
      );
      // Reconcile with the server's view of the shift without dropping the
      // confirmed registration.
      await _loadDetail(silent: true);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        session.handleUnauthorized();
      }
      if (!mounted) return;
      setState(() => _registering = false);
      messenger.showSnackBar(
        SnackBar(content: Text(_registrationErrorMessage(error))),
      );
      // Reconcile with the server: an ALREADY_REGISTERED response means the
      // volunteer is in fact registered, and a SHIFT_NOT_OPEN response means
      // the shift status has changed. The UI must reflect the server state
      // and must never claim a new registration happened.
      if (error.code == 'ALREADY_REGISTERED' ||
          error.code == 'SHIFT_NOT_OPEN') {
        await _loadDetail(silent: true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _registering = false);
      messenger.showSnackBar(
        const SnackBar(content: Text(AuthMessages.fallback)),
      );
    }
  }

  /// The registration id known for the current user and shift.
  ///
  /// The backend returns the id only in a registration response, so it is
  /// known for registrations made during the current app session. A shift
  /// detail reports the status alone and never exposes the id.
  int? get _registrationId {
    final session = SessionScope.maybeOf(context);
    final userId = session?.user?.id;
    if (userId == null) return null;
    return RegistrationScope.maybeOf(
      context,
    )?.registrationIdFor(widget.shift.id, userId: userId);
  }

  /// Whether the current volunteer may cancel their registration.
  ///
  /// The backend accepts a cancellation only while the shift is open and only
  /// for the caller's own registration. The registration id must be known, so
  /// a registration that was made in an earlier app session cannot be
  /// cancelled.
  bool _canCancel(int? registrationId) {
    if (!_isRegistered) return false;
    final session = SessionScope.maybeOf(context);
    if (session == null || !session.isAuthenticated) return false;
    if (session.role != UserRole.volunteer) return false;
    if (session.session?.token == null) return false;
    if ((_shift ?? widget.shift).status != ShiftStatus.available) return false;
    return registrationId != null;
  }

  /// Cancels the caller's registration for this shift.
  ///
  /// The request is only sent after the volunteer confirms it and only when
  /// the registration id is known. The shared state is changed exclusively
  /// after the backend confirmed the cancellation.
  Future<void> _cancel(int registrationId) async {
    if (_cancelling) return;

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (session == null || !session.isAuthenticated || token == null) return;
    final userId = session.user?.id;
    if (userId == null) return;

    final api = ApiScope.maybeShiftsOf(context);
    if (api == null) return;

    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Отказ от записа'),
            content: const Text(
              'Сигурни ли сте, че искате да откажете записа си за тази смяна?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Не, оставам'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Да, откажи'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    setState(() => _cancelling = true);
    try {
      final result = await api.cancelSelf(
        widget.shift.id,
        registrationId,
        token: token,
      );
      if (!mounted) return;
      // The backend confirmed the cancellation: only now is it reported.
      setState(() {
        _cancelling = false;
        _registrationStatus = result.status;
        _cancellationConfirmed = true;
        _registrationRevision += 1;
      });
      _publishRegistrationStatus(
        userId,
        result.status,
        registrationId: result.id,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Отказахте записа си за тази смяна.')),
      );
      // Reconcile with the server's view of the shift without dropping the
      // confirmed cancellation.
      await _loadDetail(silent: true);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        session.handleUnauthorized();
      }
      if (!mounted) return;
      setState(() => _cancelling = false);
      messenger.showSnackBar(
        SnackBar(content: Text(_cancelErrorMessage(error))),
      );
      // Reconcile with the server: a SHIFT_NOT_OPEN response means the shift
      // status has changed and a NOT_FOUND response means the registration is
      // gone. The UI must reflect the server state and must never claim a
      // cancellation happened.
      if (error.code == 'SHIFT_NOT_OPEN' || error.code == 'NOT_FOUND') {
        await _loadDetail(silent: true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      messenger.showSnackBar(
        const SnackBar(content: Text(AuthMessages.fallback)),
      );
    }
  }

  bool get _isAdmin {
    final session = SessionScope.maybeOf(context);
    return session != null &&
        session.isAuthenticated &&
        session.role == UserRole.admin &&
        session.session?.token != null;
  }

  bool get _canManageShift {
    if (!_isAdmin) return false;
    final status = (_shift ?? widget.shift).status;
    return status == ShiftStatus.draft || status == ShiftStatus.available;
  }

  Future<void> _openEditor() async {
    if (_adminBusy || !_canManageShift) return;
    final messenger = ScaffoldMessenger.of(context);
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ShiftEditorScreen(shift: _shift ?? widget.shift),
      ),
    );
    if (changed != true || !mounted) return;
    setState(() => _adminRevision += 1);
    widget.onChanged?.call();
    messenger.showSnackBar(
      const SnackBar(content: Text('Промените по смяната са запазени.')),
    );
    await _loadDetail(silent: true);
  }

  Future<void> _editLocations() async {
    if (_adminBusy || !_canManageShift) return;
    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) return;

    final selected = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder:
          (_) =>
              _ShiftLocationPicker(currentLocations: _locations, token: token),
    );
    if (selected == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final api = ApiScope.maybeShiftsOf(context);
    if (api == null) return;
    setState(() => _adminBusy = true);
    try {
      final locations = await api.replaceShiftLocations(
        widget.shift.id,
        locationIds: selected,
        token: token,
      );
      if (!mounted) return;
      setState(() {
        _locations = locations;
        _adminBusy = false;
        _adminRevision += 1;
      });
      widget.onChanged?.call();
      messenger.showSnackBar(
        const SnackBar(content: Text('Пунктовете на смяната са обновени.')),
      );
      await _loadDetail(silent: true);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() => _adminBusy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(AuthMessages.forException(error))),
      );
      if (error.code == 'SHIFT_NOT_EDITABLE' ||
          error.code == 'INVALID_LOCATION' ||
          error.code == 'NOT_FOUND') {
        await _loadDetail(silent: true);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _adminBusy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text(AuthMessages.fallback)),
      );
    }
  }

  Future<void> _publishShift() {
    return _changeStatus('OPEN', successMessage: 'Смяната е публикувана.');
  }

  Future<void> _closeShift() {
    return _changeStatus(
      'CLOSED',
      successMessage: 'Смяната е затворена.',
      confirmationTitle: 'Затваряне на смяната',
      confirmationText:
          'След затваряне смяната не може да бъде редактирана или отворена '
          'отново. Сигурни ли сте?',
      confirmationAction: 'Да, затвори',
      cancellationAction: 'Не, остава отворена',
    );
  }

  Future<void> _cancelShift() {
    return _changeStatus(
      'CANCELLED',
      successMessage: 'Смяната е отменена.',
      confirmationTitle: 'Отмяна на смяната',
      confirmationText:
          'Отменената смяна не може да бъде отворена или редактирана отново. '
          'Сигурни ли сте?',
      confirmationAction: 'Да, отмени',
      cancellationAction: 'Не, запази смяната',
    );
  }

  Future<void> _changeStatus(
    String status, {
    required String successMessage,
    String? confirmationTitle,
    String? confirmationText,
    String? confirmationAction,
    String? cancellationAction,
  }) async {
    if (_adminBusy || !_canManageShift) return;

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) return;

    if (confirmationTitle != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: Text(confirmationTitle),
              content: Text(confirmationText ?? ''),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(cancellationAction ?? 'Не'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(confirmationAction ?? 'Да'),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
    }

    final api = ApiScope.maybeShiftsOf(context);
    final messenger = ScaffoldMessenger.of(context);
    if (api == null) return;
    setState(() => _adminBusy = true);
    try {
      await api.setShiftStatus(widget.shift.id, status, token: token);
      if (!mounted) return;
      setState(() {
        _adminBusy = false;
        _adminRevision += 1;
      });
      widget.onChanged?.call();
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
      await _loadDetail(silent: true);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() => _adminBusy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(AuthMessages.forException(error))),
      );
      if (error.code == 'SHIFT_NOT_EDITABLE' ||
          error.code == 'INVALID_STATUS_TRANSITION' ||
          error.code == 'NOT_FOUND') {
        await _loadDetail(silent: true);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _adminBusy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text(AuthMessages.fallback)),
      );
    }
  }

  /// Publishes a registration status observed in a confirmed backend response
  /// to the shared client-side cache.
  ///
  /// Only server-confirmed states are published; nothing is ever assumed.
  /// Without an authenticated user id there is nobody to publish for, and
  /// without the scope the cache is simply absent (for example in tests).
  ///
  /// [registrationId] is published only when the confirmed response carried
  /// it. An observation without an id never erases a known id.
  void _publishRegistrationStatus(
    int? userId,
    String? status, {
    int? registrationId,
  }) {
    if (userId == null) return;
    RegistrationScope.maybeOf(context)?.setStatus(
      userId: userId,
      shiftId: widget.shift.id,
      status: status,
      registrationId: registrationId,
    );
  }

  /// Bulgarian message for a failed registration. `SHIFT_NOT_OPEN` is
  /// registration-specific here (the shared mapping is worded for quantity
  /// entry).
  static String _registrationErrorMessage(ApiException error) {
    if (error.code == 'SHIFT_NOT_OPEN') {
      return 'Записването е възможно само докато смяната е отворена.';
    }
    return AuthMessages.forCode(error.code);
  }

  /// Bulgarian message for a failed cancellation. The shared `SHIFT_NOT_OPEN`
  /// wording is for quantity entry and stays untouched here.
  static String _cancelErrorMessage(ApiException error) {
    if (error.code == 'SHIFT_NOT_OPEN') {
      return 'Отказът на записа е възможен само докато смяната е отворена.';
    }
    if (error.code == 'NOT_FOUND') {
      return 'Записът не е намерен. Възможно е вече да е отменен.';
    }
    return AuthMessages.forCode(error.code);
  }

  void _openEntry() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EntryScreen(shiftId: widget.shift.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shift = _shift ?? widget.shift;
    final locations = _locations;
    // The registration id is read from the shared state, so the screen is a
    // dependant of it and rebuilds when the state changes.
    final registrationId = _registrationId;
    final shiftIsOpen = shift.status == ShiftStatus.available;
    final canCancel = _canCancel(registrationId);
    final canManageShift = _canManageShift;

    if (_loadingDetail) {
      return Scaffold(
        appBar: AppBar(title: const Text('Детайли за смяната')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_detailError != null) {
      final message =
          _detailError is ApiException
              ? AuthMessages.forException(_detailError as ApiException)
              : 'Възникна грешка при зареждане на детайлите за смяната.';
      return Scaffold(
        appBar: AppBar(title: const Text('Детайли за смяната')),
        body: Center(
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
                TextButton(
                  onPressed: _loadDetail,
                  child: const Text('Повтори'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Детайли за смяната')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    shift.title.isEmpty ? 'Смяна' : shift.title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                StatusChip(status: shift.status),
              ],
            ),
            const SizedBox(height: AppTokens.spaceMd),
            _InfoRow(
              icon: Icons.calendar_today_outlined,
              text: '${shift.weekdayLabel}, ${shift.dateLabel}',
            ),
            const SizedBox(height: AppTokens.spaceSm),
            _InfoRow(icon: Icons.schedule_outlined, text: shift.timeRange),
            if (shift.description.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceLg),
              Text(
                shift.description,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: AppTokens.spaceXl),
            const Text(
              'Пунктове',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            if (locations.isEmpty)
              const Text(
                'Няма информация за пунктове.',
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
              )
            else
              for (final location in locations)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: AppTokens.spaceSm),
                      Expanded(
                        child: Text(
                          '${location.name} — ${location.address}',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
            if (canManageShift) ...[
              const SizedBox(height: AppTokens.spaceXl),
              const Divider(),
              const SizedBox(height: AppTokens.spaceMd),
              const Text(
                'Управление на смяната',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              OutlinedButton.icon(
                onPressed: _adminBusy ? null : _openEditor,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Редактирай данните'),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              OutlinedButton.icon(
                onPressed: _adminBusy ? null : _editLocations,
                icon: const Icon(Icons.location_on_outlined),
                label: const Text('Промени пунктовете'),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              if (shift.status == ShiftStatus.draft)
                PrimaryButton(
                  label: 'Публикувай',
                  icon: Icons.publish_outlined,
                  busy: _adminBusy,
                  onPressed: _publishShift,
                )
              else if (shift.status == ShiftStatus.available)
                PrimaryButton(
                  label: 'Затвори смяната',
                  icon: Icons.lock_outline,
                  busy: _adminBusy,
                  onPressed: _closeShift,
                ),
              const SizedBox(height: AppTokens.spaceXs),
              TextButton(
                onPressed: _adminBusy ? null : _cancelShift,
                child: const Text('Отмени смяната'),
              ),
            ],
            const SizedBox(height: AppTokens.spaceXl),
            if (_isRegistered)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppTokens.spaceMd),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE7F5EC),
                      borderRadius: BorderRadius.circular(
                        AppTokens.radiusMedium,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          color: Color(0xFF2E7D32),
                          size: 22,
                        ),
                        const SizedBox(width: AppTokens.spaceSm),
                        const Expanded(
                          child: Text(
                            'Записахте се за тази смяна.',
                            style: TextStyle(
                              color: Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (canCancel) ...[
                    const SizedBox(height: AppTokens.spaceSm),
                    OutlinedButton(
                      onPressed:
                          _cancelling ? null : () => _cancel(registrationId!),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_cancelling)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const Icon(Icons.close, size: 18),
                          const SizedBox(width: AppTokens.spaceSm),
                          const Text('Отказ от записа'),
                        ],
                      ),
                    ),
                  ] else if (registrationId == null && shiftIsOpen) ...[
                    const SizedBox(height: AppTokens.spaceSm),
                    const Text(
                      'Този запис е направен в предишна сесия и не може да бъде '
                      'отменен от приложението.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              )
            else if (_canRegister)
              PrimaryButton(
                label: 'Запиши се',
                busy: _registering,
                onPressed: _register,
              ),
            const SizedBox(height: AppTokens.spaceLg),
            OutlinedButton.icon(
              onPressed: _openEntry,
              icon: const Icon(Icons.edit_note_outlined),
              label: const Text('Отчитане на количества'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Selects the complete active location set of a shift.
///
/// Archived locations that are still linked to the shift are shown but cannot
/// be selected: the backend only accepts active location ids, so saving removes
/// them from the shift. The current active locations start selected.
class _ShiftLocationPicker extends StatefulWidget {
  const _ShiftLocationPicker({
    required this.currentLocations,
    required this.token,
  });

  final List<ShiftDetailLocation> currentLocations;
  final String token;

  @override
  State<_ShiftLocationPicker> createState() => _ShiftLocationPickerState();
}

class _ShiftLocationPickerState extends State<_ShiftLocationPicker> {
  final Set<int> _selectedLocationIds = <int>{};
  List<Location> _activeLocations = const [];
  bool _loading = true;
  bool _requested = false;
  Object? _error;

  List<ShiftDetailLocation> get _archivedLocations =>
      widget.currentLocations.where((location) => !location.isActive).toList();

  @override
  void initState() {
    super.initState();
    _selectedLocationIds.addAll(
      widget.currentLocations
          .where((location) => location.isActive)
          .map((location) => location.id),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ApiScope.maybeOf(context);
      if (api == null) {
        throw const ApiException(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Locations are unavailable.',
        );
      }
      final locations = await api.list(token: widget.token);
      if (!mounted) return;
      final active = locations.where((location) => location.isActive).toList();
      setState(() {
        _activeLocations = active;
        _selectedLocationIds.removeWhere(
          (id) => !active.any((location) => location.id == id),
        );
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
      }
      setState(() {
        _loading = false;
        _error = error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final archived = _archivedLocations;
    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceLg,
              AppTokens.spaceLg,
              AppTokens.spaceSm,
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Пунктове на смяната',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: 'Затвори',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
            child: Text(
              'Изборът замества целия набор от пунктове. Изберете поне един '
              'активен пункт.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Expanded(child: _buildBody(archived)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: PrimaryButton(
                label: 'Запази пунктовете',
                icon: Icons.save_outlined,
                onPressed:
                    _loading || _error != null || _selectedLocationIds.isEmpty
                        ? null
                        : () => Navigator.of(
                          context,
                        ).pop(_selectedLocationIds.toList()..sort()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(List<ShiftDetailLocation> archived) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      final message =
          _error is ApiException
              ? AuthMessages.forException(_error as ApiException)
              : 'Възникна грешка при зареждане на пунктовете.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: AppTokens.spaceSm),
              TextButton(onPressed: _load, child: const Text('Повтори')),
            ],
          ),
        ),
      );
    }
    if (_activeLocations.isEmpty && archived.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppTokens.spaceLg),
          child: Text(
            'Няма активни пунктове.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
      children: [
        for (final location in _activeLocations)
          CheckboxListTile(
            value: _selectedLocationIds.contains(location.id),
            onChanged: (selected) {
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
        if (archived.isNotEmpty) ...[
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
            child: Text(
              'Архивирани пунктове',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          for (final location in archived)
            ListTile(
              enabled: false,
              leading: const Icon(Icons.archive_outlined),
              title: Text(location.name),
              subtitle: Text(
                '${location.address}\nАрхивиран пункт: при запазване ще бъде '
                'премахнат от смяната.',
              ),
              contentPadding: EdgeInsets.zero,
            ),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: AppColors.textSecondary),
        const SizedBox(width: AppTokens.spaceSm),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
