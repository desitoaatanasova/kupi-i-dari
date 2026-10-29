import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/api/shifts_api.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/registration_scope.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_scope.dart';
import '../core/statuses.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';
import '../models/location.dart';
import '../models/shift.dart';
import '../widgets/search_field.dart';
import '../widgets/shift_card.dart';
import 'shift_detail_screen.dart';
import 'shift_editor_screen.dart';
import 'volunteer_identification_screen.dart';

class ShiftsScreen extends StatefulWidget {
  const ShiftsScreen({super.key, this.location});

  final Location? location;

  @override
  State<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends State<ShiftsScreen> {
  static const _statusPriority = <ShiftStatus, int>{
    ShiftStatus.draft: 0,
    ShiftStatus.available: 1,
    ShiftStatus.almostFull: 2,
    ShiftStatus.upcoming: 3,
    ShiftStatus.inProcess: 4,
    ShiftStatus.full: 5,
    ShiftStatus.completed: 6,
    ShiftStatus.archived: 7,
  };

  static const int _detailConcurrency = 4;

  final _searchController = TextEditingController();
  String _query = '';
  ShiftStatus? _statusFilter;

  bool _loading = true;
  bool _loaded = false;
  Object? _error;
  List<Shift> _allShifts = const [];
  final Map<int, List<ShiftDetailLocation>> _detailLocationsCache = {};
  bool _resolvingLocations = false;
  Object? _locationFilterError;

  /// Bumped for every list read. A response or error from an older read must
  /// never replace the state of a newer read.
  int _loadRevision = 0;

  /// True when the visitor has no session and must identify before the shifts
  /// can be read.
  bool _requiresIdentification = false;

  /// The authentication state of the last read, used to detect a session that
  /// appeared or disappeared while the screen was mounted.
  bool? _wasAuthenticated;

  bool get _hasActiveFilters => _query.isNotEmpty || _statusFilter != null;

  bool _isAuthenticated(SessionController? session) {
    return session != null &&
        session.isAuthenticated &&
        session.session?.token != null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authenticated = _isAuthenticated(SessionScope.maybeOf(context));
    if (_wasAuthenticated != null && _wasAuthenticated != authenticated) {
      // The session appeared or disappeared: the list has to be read again.
      _loaded = false;
    }
    _wasAuthenticated = authenticated;
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _resetFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _statusFilter = null;
    });
  }

  void _openDetail(Shift shift) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => ShiftDetailScreen(
              shift: shift,
              onChanged: () {
                if (mounted) _load();
              },
            ),
      ),
    );
  }

  bool get _isAdmin {
    final session = SessionScope.maybeOf(context);
    return session != null &&
        session.isAuthenticated &&
        session.role == UserRole.admin;
  }

  Future<void> _openCreate() async {
    final knownShiftIds = _allShifts.map((shift) => shift.id).toSet();
    final messenger = ScaffoldMessenger.of(context);
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ShiftEditorScreen(initialLocation: widget.location),
      ),
    );
    if (created != true || !mounted) return;
    _resetFilters();
    await _load();
    if (!mounted || widget.location == null) return;

    Shift? newShift;
    for (final shift in _allShifts) {
      if (!knownShiftIds.contains(shift.id)) {
        newShift = shift;
        break;
      }
    }
    final hiddenShift = newShift;
    if (hiddenShift == null || _belongsToSelectedLocation(hiddenShift)) {
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Смяната е създадена, но не е за избрания пункт и не се показва в '
          'този списък.',
        ),
        action: SnackBarAction(
          label: 'Виж новата',
          onPressed: () {
            if (mounted) _openDetail(hiddenShift);
          },
        ),
      ),
    );
  }

  /// Opens the existing volunteer identification screen.
  void _openIdentification() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const VolunteerIdentificationScreen(),
      ),
    );
  }

  Future<void> _load() async {
    if (!mounted) return;
    final revision = ++_loadRevision;
    setState(() {
      _loading = true;
      _error = null;
      _locationFilterError = null;
      _resolvingLocations = false;
      _requiresIdentification = false;
    });

    final session = SessionScope.maybeOf(context);
    // The shifts endpoint requires a bearer token. An anonymous visitor is
    // never asked for one: the screen shows a prompt instead of sending a
    // request that could only fail.
    if (!_isAuthenticated(session)) {
      setState(() {
        _loading = false;
        _requiresIdentification = true;
      });
      return;
    }

    try {
      final token = session?.session?.token;
      final api = ApiScope.shiftsOf(context);
      final shifts = await api.list(token: token);
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _allShifts = shifts;
        _loading = false;
      });
      if (widget.location != null) {
        await _resolveLocationMembership(revision);
      }
    } on ApiException catch (error) {
      if (!mounted || revision != _loadRevision) return;
      if (error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _resolveLocationMembership([int? revision]) async {
    final location = widget.location;
    if (location == null) return;
    if (_allShifts.isEmpty) return;
    if (!mounted) return;
    final requestRevision = revision ?? _loadRevision;
    if (requestRevision != _loadRevision) return;

    setState(() {
      _resolvingLocations = true;
      _locationFilterError = null;
    });

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    // The responses belong to the user the request is made for.
    final userId = session?.user?.id;
    final api = ApiScope.shiftsOf(context);

    final toFetch = <Shift>[];
    for (final shift in _allShifts) {
      if (!_detailLocationsCache.containsKey(shift.id)) {
        toFetch.add(shift);
      }
    }

    var index = 0;
    final workers = <Future<void>>[];
    while (workers.length < _detailConcurrency && index < toFetch.length) {
      final shift = toFetch[index++];
      workers.add(
        _fetchDetailForLocation(shift.id, api, token, userId, requestRevision),
      );
    }

    while (workers.isNotEmpty) {
      await workers.removeAt(0);
      if (requestRevision != _loadRevision) return;
      if (index < toFetch.length && mounted) {
        final shift = toFetch[index++];
        workers.add(
          _fetchDetailForLocation(
            shift.id,
            api,
            token,
            userId,
            requestRevision,
          ),
        );
      }
    }

    if (!mounted || requestRevision != _loadRevision) return;
    setState(() {
      _resolvingLocations = false;
    });
  }

  Future<void> _fetchDetailForLocation(
    int shiftId,
    ShiftsApi api,
    String? token,
    int? userId,
    int requestRevision,
  ) async {
    try {
      final detail = await api.getDetail(shiftId, token: token);
      if (!mounted || requestRevision != _loadRevision) return;
      setState(() {
        _detailLocationsCache[shiftId] = detail.locations;
      });
      // The detail was fetched anyway for the location filter, so the
      // registration state it carries is published as well - no extra request.
      if (userId != null) {
        RegistrationScope.maybeOf(context)?.setStatus(
          userId: userId,
          shiftId: shiftId,
          status: detail.myRegistration?.status,
        );
      }
    } catch (error) {
      if (!mounted || requestRevision != _loadRevision) return;
      if (error is ApiException && error.isUnauthorized) {
        SessionScope.maybeOf(context)?.handleUnauthorized();
        setState(() {
          _locationFilterError = error;
        });
      }
    }
  }

  bool _belongsToSelectedLocation(Shift shift) {
    final location = widget.location;
    if (location == null) return true;
    final cached = _detailLocationsCache[shift.id];
    if (cached == null) return false;
    for (final loc in cached) {
      if (loc.id == location.id) return true;
    }
    return false;
  }

  /// The backend id of the signed-in volunteer, or `null` when the session is
  /// missing, anonymous or not a volunteer.
  ///
  /// Only a volunteer can have registrations, so staff sessions never show a
  /// registration chip.
  int? get _volunteerId {
    final session = SessionScope.maybeOf(context);
    if (session == null || !session.isAuthenticated) return null;
    if (session.role != UserRole.volunteer) return null;
    return session.user?.id;
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;

    final visible = <Shift>[];
    for (final shift in _allShifts) {
      if (location != null && !_belongsToSelectedLocation(shift)) {
        continue;
      }
      if (_statusFilter != null && shift.status != _statusFilter) {
        continue;
      }
      if (_query.isNotEmpty &&
          !shift.title.toLowerCase().contains(_query.toLowerCase())) {
        continue;
      }
      visible.add(shift);
    }

    visible.sort((a, b) {
      final byPriority = _statusPriority[a.status]!.compareTo(
        _statusPriority[b.status]!,
      );
      if (byPriority != 0) return byPriority;
      return a.date.compareTo(b.date);
    });

    final presentStatuses = <ShiftStatus>{};
    for (final shift in _allShifts) {
      if (location != null && !_belongsToSelectedLocation(shift)) {
        continue;
      }
      presentStatuses.add(shift.status);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_requiresIdentification) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceLg,
              AppTokens.spaceLg,
              AppTokens.spaceMd,
            ),
            child: SearchField(
              controller: _searchController,
              hintText: 'Търсене на смяна...',
              onChanged: (value) => setState(() => _query = value),
              onClear: () {
                _searchController.clear();
                setState(() => _query = '');
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceLg,
              ),
              children: [
                _StatusFilterChip(
                  label: 'Всички',
                  selected: _statusFilter == null,
                  onTap: () => setState(() => _statusFilter = null),
                ),
                for (final status in ShiftStatus.values)
                  if (presentStatuses.contains(status))
                    _StatusFilterChip(
                      label: status.label,
                      selected: _statusFilter == status,
                      textColor: status.textColor,
                      backgroundColor: status.backgroundColor,
                      onTap: () => setState(() => _statusFilter = status),
                    ),
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceLg,
            AppTokens.spaceMd,
            AppTokens.spaceLg,
            AppTokens.spaceSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  location == null
                      ? 'Всички смени'
                      : 'Смени за ${location.name}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_hasActiveFilters)
                TextButton(
                  onPressed: _resetFilters,
                  child: const Text('Нулирай филтрите'),
                ),
              if (_isAdmin)
                TextButton.icon(
                  onPressed: _openCreate,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Нова смяна'),
                ),
            ],
          ),
        ),
        Expanded(child: _buildBody(visible)),
        const SizedBox(height: AppTokens.spaceLg),
      ],
    );
  }

  Widget _buildBody(List<Shift> visible) {
    // The shared registration cache is observed here, so the list rebuilds
    // when a registration is confirmed. It never triggers a reload.
    final registrationState = RegistrationScope.maybeOf(context);
    final volunteerId = _volunteerId;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      final message =
          _error is ApiException
              ? AuthMessages.forException(_error as ApiException)
              : 'Възникна грешка при зареждане на смените.';
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
    if (_requiresIdentification) {
      return _buildIdentificationPrompt();
    }
    if (widget.location != null && _resolvingLocations) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.location != null && _locationFilterError != null) {
      final message =
          _locationFilterError is ApiException
              ? AuthMessages.forException(_locationFilterError as ApiException)
              : 'Не успяхме да проверим кои смени са за избрания пункт.';
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
              TextButton(
                onPressed: () async {
                  setState(() {
                    _locationFilterError = null;
                  });
                  await _resolveLocationMembership();
                },
                child: const Text('Повтори'),
              ),
            ],
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
          children: const [
            SizedBox(height: 120),
            Center(
              child: Text(
                'Няма намерени смени.',
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final shift = visible[index];
          return ShiftCard(
            shift: shift,
            isRegistered:
                registrationState?.isRegistered(
                  shift.id,
                  userId: volunteerId,
                ) ??
                false,
            onTap: () => _openDetail(shift),
            onButtonPressed: () => _openDetail(shift),
          );
        },
      ),
    );
  }

  /// The state shown to a visitor without a session.
  ///
  /// The shifts endpoint requires a bearer token, so no request is sent for an
  /// anonymous visitor and no "session expired" message is shown for a session
  /// that never existed.
  Widget _buildIdentificationPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.person_outline,
              size: 48,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            const Text(
              'Идентифицирайте се, за да виждате смените.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            OutlinedButton.icon(
              onPressed: _openIdentification,
              icon: const Icon(Icons.login_outlined),
              label: const Text('Идентифицирайте се'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  const _StatusFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.textColor,
    this.backgroundColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? textColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final color = textColor ?? AppColors.primary;
    final bg = backgroundColor ?? AppColors.primary.withValues(alpha: 0.10);
    return Padding(
      padding: const EdgeInsets.only(right: AppTokens.spaceSm),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? color : AppColors.textSecondary,
        ),
        selectedColor: bg,
        backgroundColor: AppColors.backgroundSecondary,
        side: BorderSide(color: selected ? color : AppColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusPill),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      ),
    );
  }
}
