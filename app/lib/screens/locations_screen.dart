import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/api/locations_api.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';
import '../models/location.dart';
import '../widgets/location_card.dart';
import '../widgets/search_field.dart';
import 'location_editor_screen.dart';
import 'shifts_screen.dart';

enum _LocationsStatus { loading, success, error }

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, this.locationsApi});

  final LocationsApi? locationsApi;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  _LocationsStatus _status = _LocationsStatus.loading;
  List<Location> _locations = const [];
  String? _errorMessage;
  bool _notMounted = false;
  bool _loaded = false;
  int _loadRevision = 0;
  final Set<int> _mutatingLocationIds = <int>{};
  bool _creating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _loadLocations();
    }
  }

  @override
  void dispose() {
    _notMounted = true;
    _searchController.dispose();
    super.dispose();
  }

  bool get _isAdmin {
    final session = SessionScope.maybeOf(context);
    if (session == null || !session.isAuthenticated) return false;
    return session.role == UserRole.admin;
  }

  Future<void> _loadLocations() async {
    final api = _resolveApi();
    if (api == null) {
      if (_notMounted) return;
      setState(() {
        _status = _LocationsStatus.error;
        _errorMessage = 'Възникна неочаквана грешка. Опитайте отново.';
        _locations = const [];
      });
      return;
    }

    final revision = ++_loadRevision;
    if (!_notMounted) {
      setState(() {
        _status = _LocationsStatus.loading;
        _errorMessage = null;
      });
    }

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;

    try {
      final locations = await api.list(token: token);
      if (_notMounted || revision != _loadRevision) return;
      setState(() {
        _locations = locations;
        _status = _LocationsStatus.success;
        _errorMessage = null;
      });
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      if (_notMounted || revision != _loadRevision) return;
      setState(() {
        _status = _LocationsStatus.error;
        _errorMessage = AuthMessages.forCode(error.code);
        _locations = const [];
      });
    } catch (_) {
      if (_notMounted || revision != _loadRevision) return;
      setState(() {
        _status = _LocationsStatus.error;
        _errorMessage = AuthMessages.fallback;
        _locations = const [];
      });
    }
  }

  LocationsApi? _resolveApi() {
    final injected = widget.locationsApi;
    if (injected != null) return injected;
    try {
      return ApiScope.maybeOf(context);
    } catch (_) {
      return null;
    }
  }

  void _openShifts(BuildContext context, Location location) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => Scaffold(
              appBar: AppBar(title: Text(location.name)),
              body: ShiftsScreen(location: location),
            ),
      ),
    );
  }

  Future<void> _openCreate() async {
    if (_creating || !mounted) return;
    setState(() => _creating = true);
    try {
      final result = await Navigator.of(context).push<Location>(
        MaterialPageRoute<Location>(
          builder: (_) => const LocationEditorScreen(),
        ),
      );
      if (result != null && mounted) _applyCreated(result);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _openEdit(Location location) async {
    if (_mutatingLocationIds.contains(location.id)) return;
    final result = await Navigator.of(context).push<Location>(
      MaterialPageRoute<Location>(
        builder: (_) => LocationEditorScreen(location: location),
      ),
    );
    if (result == null || !mounted) return;
    _applyUpdated(result);
  }

  void _applyCreated(Location created) {
    final hadQuery = _query.isNotEmpty;
    final matchesQuery = _matches(created, _query);
    setState(() {
      _loadRevision++;
      final list = List<Location>.from(_locations);
      list.removeWhere((item) => item.id == created.id);
      list.add(created);
      list.sort((a, b) {
        final byName = a.name.compareTo(b.name);
        if (byName != 0) return byName;
        return a.id.compareTo(b.id);
      });
      _locations = list;
      _status = _LocationsStatus.success;
      _errorMessage = null;
      if (hadQuery && !matchesQuery) {
        _query = '';
        _searchController.clear();
      }
    });
  }

  void _applyUpdated(Location updated) {
    setState(() {
      _loadRevision++;
      final list =
          _locations
              .map((item) => item.id == updated.id ? updated : item)
              .where((item) => item.isActive)
              .toList();
      list.sort((a, b) {
        final byName = a.name.compareTo(b.name);
        if (byName != 0) return byName;
        return a.id.compareTo(b.id);
      });
      _locations = list;
      _status = _LocationsStatus.success;
      _errorMessage = null;
    });
  }

  bool _matches(Location location, String query) {
    if (query.isEmpty) return true;
    final haystack = '${location.name} ${location.address}'.toLowerCase();
    return haystack.contains(query.toLowerCase());
  }

  Future<void> _archiveLocation(Location location) async {
    if (!_isAdmin) return;
    if (_mutatingLocationIds.contains(location.id)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Архивиране на пункт'),
            content: Text(
              'Пунктът „${location.name}“ ще бъде скрит от списъка. Продължавате ли?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Отказ'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Архивирай'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    final api = _resolveApi();
    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) {
      _showMessage(AuthMessages.forCode('UNAUTHORIZED'));
      return;
    }
    if (api == null) {
      _showMessage(AuthMessages.fallback);
      return;
    }

    setState(() {
      _mutatingLocationIds.add(location.id);
    });

    try {
      final archived = await api.setLocationStatus(
        location.id,
        isActive: false,
        token: token,
      );
      if (!mounted) return;
      if (archived.isActive) {
        setState(() {
          _mutatingLocationIds.remove(location.id);
        });
        _showMessage(AuthMessages.fallback);
        return;
      }
      setState(() {
        _mutatingLocationIds.remove(location.id);
        _loadRevision++;
        _locations =
            _locations.where((item) => item.id != archived.id).toList();
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Пунктът е архивиран.'),
          action: SnackBarAction(
            label: 'Върни',
            onPressed: () => _undoArchive(archived),
          ),
        ),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() {
        _mutatingLocationIds.remove(location.id);
      });
      if (!mounted) return;
      _showMessage(AuthMessages.forException(error));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mutatingLocationIds.remove(location.id);
      });
      if (!mounted) return;
      _showMessage(AuthMessages.fallback);
    }
  }

  Future<void> _undoArchive(Location archived) async {
    if (!mounted) return;
    if (_mutatingLocationIds.contains(archived.id)) return;
    final api = _resolveApi();
    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) {
      _showMessage(AuthMessages.forCode('UNAUTHORIZED'));
      return;
    }
    if (api == null) {
      _showMessage(AuthMessages.fallback);
      return;
    }

    setState(() {
      _mutatingLocationIds.add(archived.id);
    });

    try {
      final restored = await api.setLocationStatus(
        archived.id,
        isActive: true,
        token: token,
      );
      if (!mounted) return;
      if (!restored.isActive) {
        setState(() {
          _mutatingLocationIds.remove(archived.id);
        });
        _showMessage(AuthMessages.fallback);
        return;
      }
      setState(() {
        _mutatingLocationIds.remove(restored.id);
        _loadRevision++;
        final list = List<Location>.from(_locations);
        list.removeWhere((item) => item.id == restored.id);
        list.add(restored);
        list.sort((a, b) {
          final byName = a.name.compareTo(b.name);
          if (byName != 0) return byName;
          return a.id.compareTo(b.id);
        });
        _locations = list.where((item) => item.isActive).toList();
      });
      if (!mounted) return;
      _showMessage('Пунктът е възстановен.');
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() {
        _mutatingLocationIds.remove(archived.id);
      });
      if (!mounted) return;
      _showMessage(AuthMessages.forException(error));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mutatingLocationIds.remove(archived.id);
      });
      if (!mounted) return;
      _showMessage(AuthMessages.fallback);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _isAdmin;
    final filteredLocations =
        _locations.where((location) {
          if (!location.isActive) return false;
          return _matches(location, _query);
        }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceLg,
            AppTokens.spaceLg,
            AppTokens.spaceLg,
            AppTokens.spaceMd,
          ),
          child: SearchField(
            controller: _searchController,
            hintText: 'Търсене на пункт...',
            onChanged: (value) => setState(() => _query = value),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Пунктове за събиране',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isAdmin)
                TextButton.icon(
                  key: const Key('location-create-button'),
                  onPressed: _creating ? null : _openCreate,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Нов пункт'),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceMd),
        Expanded(child: _buildBody(filteredLocations)),
        const SizedBox(height: AppTokens.spaceLg),
      ],
    );
  }

  Widget _buildBody(List<Location> filteredLocations) {
    final isAdmin = _isAdmin;

    if (_status == _LocationsStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_status == _LocationsStatus.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _errorMessage ?? AuthMessages.fallback,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              OutlinedButton(
                onPressed: _loadLocations,
                child: const Text('Повтори'),
              ),
              if (isAdmin) ...[
                const SizedBox(height: AppTokens.spaceSm),
                TextButton.icon(
                  key: const Key('location-error-create-button'),
                  onPressed: _creating ? null : _openCreate,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Нов пункт'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (filteredLocations.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadLocations,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
          children: [
            const SizedBox(height: 120),
            Center(
              child: Text(
                _query.isEmpty
                    ? 'Няма регистрирани пунктове.'
                    : 'Няма намерени пунктове.',
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            if (isAdmin && _query.isEmpty) ...[
              const SizedBox(height: AppTokens.spaceMd),
              Center(
                child: TextButton.icon(
                  key: const Key('location-empty-create-button'),
                  onPressed: _creating ? null : _openCreate,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Нов пункт'),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLocations,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
        itemCount: filteredLocations.length,
        itemBuilder: (context, index) {
          final location = filteredLocations[index];
          final isMutating = _mutatingLocationIds.contains(location.id);
          return LocationCard(
            location: location,
            onTap: () => _openShifts(context, location),
            trailing:
                isAdmin
                    ? (isMutating
                        ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : PopupMenuButton<String>(
                          tooltip: 'Действия за пункта',
                          key: Key('location-admin-menu-${location.id}'),
                          onSelected: (value) {
                            if (value == 'edit') {
                              _openEdit(location);
                            } else if (value == 'archive') {
                              _archiveLocation(location);
                            }
                          },
                          itemBuilder:
                              (context) => const [
                                PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Text('Редактирай'),
                                ),
                                PopupMenuItem<String>(
                                  value: 'archive',
                                  child: Text('Архивирай'),
                                ),
                              ],
                        ))
                    : null,
          );
        },
      ),
    );
  }
}
