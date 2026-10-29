import 'package:flutter/material.dart';

import '../core/api/admin_users_api.dart';
import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/admin_user_page.dart';
import '../models/app_user.dart';
import '../widgets/primary_button.dart';
import '../widgets/user_card.dart';
import 'admin_user_editor_screen.dart';

enum _UsersStatus { loading, success, error }

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key, this.adminUsersApi});

  final AdminUsersApi? adminUsersApi;

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  static const int _pageSize = 20;

  _UsersStatus _status = _UsersStatus.loading;
  AdminUserPage? _pageData;
  String? _errorMessage;
  bool _loaded = false;

  UserRole? _roleFilter;
  bool? _activeFilter;
  int _currentPage = 1;

  /// Incremented whenever the visible list request or a confirmed mutation
  /// changes the authoritative list generation.
  int _loadRevision = 0;
  int _filterRevision = 0;

  final Set<int> _mutatingIds = <int>{};
  bool _creating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  bool get _isAdmin {
    final session = SessionScope.maybeOf(context);
    if (session == null || !session.isAuthenticated) return false;
    return session.role == UserRole.admin;
  }

  AdminUsersApi? _resolveApi() {
    final injected = widget.adminUsersApi;
    if (injected != null) return injected;
    return ApiScope.maybeAdminUsersOf(context);
  }

  Future<void> _load({int? requestedPage}) async {
    if (!mounted) return;

    final session = SessionScope.maybeOf(context);
    if (!_isAdmin) {
      setState(() {
        _status = _UsersStatus.error;
        _pageData = null;
        _errorMessage = AuthMessages.forCode('FORBIDDEN');
      });
      return;
    }

    final api = _resolveApi();
    if (api == null) {
      setState(() {
        _status = _UsersStatus.error;
        _pageData = null;
        _errorMessage = AuthMessages.fallback;
      });
      return;
    }

    final token = session?.session?.token;
    if (token == null || token.isEmpty) {
      session?.handleUnauthorized();
      if (!mounted) return;
      setState(() {
        _status = _UsersStatus.error;
        _pageData = null;
        _errorMessage = AuthMessages.forCode('UNAUTHORIZED');
      });
      return;
    }

    var pageToLoad = requestedPage ?? _currentPage;
    if (pageToLoad < 1) pageToLoad = 1;

    final revision = ++_loadRevision;
    setState(() {
      _status = _UsersStatus.loading;
      _errorMessage = null;
    });

    try {
      final result = await api.listUserPage(
        token: token,
        role: _roleFilter,
        isActive: _activeFilter,
        page: pageToLoad,
        pageSize: _pageSize,
      );
      if (!mounted || revision != _loadRevision) return;

      if (result.totalPages == 0 && pageToLoad != 1) {
        setState(() => _currentPage = 1);
        await _load();
        return;
      }
      if (result.totalPages > 0 && pageToLoad > result.totalPages) {
        setState(() => _currentPage = result.totalPages);
        await _load();
        return;
      }

      setState(() {
        _currentPage = result.page;
        _pageData = result;
        _status = _UsersStatus.success;
        _errorMessage = null;
      });
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _status = _UsersStatus.error;
        _pageData = null;
        _errorMessage = AuthMessages.forException(error);
      });
    } catch (_) {
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _status = _UsersStatus.error;
        _pageData = null;
        _errorMessage = AuthMessages.fallback;
      });
    }
  }

  Future<void> _onRefresh() => _load();

  void _changeRole(UserRole? role) {
    if (_roleFilter == role) return;
    _filterRevision++;
    setState(() {
      _roleFilter = role;
      _currentPage = 1;
    });
    _load();
  }

  void _changeActive(bool? active) {
    if (_activeFilter == active) return;
    _filterRevision++;
    setState(() {
      _activeFilter = active;
      _currentPage = 1;
    });
    _load();
  }

  void _goToPage(int page) {
    if (page < 1 || page == _currentPage) return;
    setState(() => _currentPage = page);
    _load(requestedPage: page);
  }

  Future<void> _openCreate() async {
    if (_creating || !_isAdmin || !mounted) return;

    final api = _resolveApi();
    if (api == null) {
      _showMessage(AuthMessages.fallback);
      return;
    }

    setState(() => _creating = true);
    AppUser? result;
    try {
      result = await Navigator.of(context).push<AppUser>(
        MaterialPageRoute<AppUser>(
          builder: (_) => AdminUserEditorScreen(adminUsersApi: api),
        ),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
    if (result == null || !mounted) return;

    final created = result;
    final matchesRole = _roleFilter == null || _roleFilter == created.role;
    final matchesActive =
        _activeFilter == null || _activeFilter == created.isActive;

    if (!matchesRole || !matchesActive) {
      _filterRevision++;
      setState(() {
        _roleFilter = null;
        _activeFilter = null;
      });
    }
    setState(() => _currentPage = 1);

    _showMessage('Потребителят е създаден успешно.');
    await _loadLastPageAfterCreate();
  }

  Future<void> _loadLastPageAfterCreate() async {
    final filterRevision = _filterRevision;
    final role = _roleFilter;
    final active = _activeFilter;

    await _load(requestedPage: 1);
    if (!mounted ||
        filterRevision != _filterRevision ||
        role != _roleFilter ||
        active != _activeFilter ||
        _status != _UsersStatus.success) {
      return;
    }

    final page = _pageData;
    if (page == null || page.totalPages <= 1) return;
    await _load(requestedPage: page.totalPages);
  }

  Future<void> _openEdit(AppUser user) async {
    if (_mutatingIds.contains(user.id) || !_isAdmin || !mounted) return;

    final api = _resolveApi();
    if (api == null) {
      _showMessage(AuthMessages.fallback);
      return;
    }

    setState(() => _mutatingIds.add(user.id));
    AppUser? result;
    try {
      result = await Navigator.of(context).push<AppUser>(
        MaterialPageRoute<AppUser>(
          builder: (_) => AdminUserEditorScreen(user: user, adminUsersApi: api),
        ),
      );
    } finally {
      if (mounted) setState(() => _mutatingIds.remove(user.id));
    }
    if (result == null || !mounted) return;

    final updated = result;
    final session = SessionScope.maybeOf(context);
    if (session != null && session.user?.id == updated.id) {
      try {
        await session.refreshUser();
      } catch (_) {
        // The profile update itself succeeded; a failed profile refresh must
        // not be reported as a failed update.
      }
    }
    if (!mounted) return;

    setState(() {
      _loadRevision++;
      final current = _pageData;
      if (current != null) {
        _pageData = current.replaceUser(updated);
      }
    });
    _showMessage('Потребителят е обновен успешно.');
  }

  Future<void> _toggleStatus(AppUser user, bool activate) async {
    if (_mutatingIds.contains(user.id) || !_isAdmin) return;

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null || token.isEmpty) {
      session?.handleUnauthorized();
      return;
    }

    if (!activate) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('Деактивиране'),
              content: Text(
                'Сигурни ли сте, че искате да деактивирате ${user.fullName}?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Отказ'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Деактивирай'),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
    }

    final api = _resolveApi();
    if (api == null) {
      _showMessage(AuthMessages.fallback);
      return;
    }

    final revisionAtStart = _loadRevision;
    final roleAtStart = _roleFilter;
    final activeAtStart = _activeFilter;

    setState(() => _mutatingIds.add(user.id));
    try {
      final updated = await api.setUserStatus(
        user.id,
        token: token,
        isActive: activate,
      );
      if (!mounted) return;

      if (revisionAtStart != _loadRevision ||
          roleAtStart != _roleFilter ||
          activeAtStart != _activeFilter) {
        await _load();
        if (!mounted) return;
        _showMessage(_statusSuccessMessage(activate));
        return;
      }

      final current = _pageData;
      if (current == null ||
          !current.users.any((item) => item.id == updated.id)) {
        await _load();
        if (!mounted) return;
        _showMessage(_statusSuccessMessage(activate));
        return;
      }

      final matchesRole = roleAtStart == null || roleAtStart == updated.role;
      final matchesActive =
          activeAtStart == null || activeAtStart == updated.isActive;

      if (matchesRole && matchesActive) {
        setState(() {
          _loadRevision++;
          _pageData = current.replaceUser(updated);
        });
      } else {
        final removed = current.removeUser(updated.id);
        if (removed.users.isEmpty && (removed.page > 1 || removed.total > 0)) {
          setState(() {
            _currentPage = removed.page > 1 ? removed.page - 1 : 1;
          });
          await _load();
        } else {
          setState(() {
            _loadRevision++;
            _pageData = removed;
            _currentPage = removed.page;
          });
        }
      }

      if (!mounted) return;
      _showMessage(_statusSuccessMessage(activate));
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      if (!mounted) return;
      _showMessage(AuthMessages.forException(error));
    } catch (_) {
      if (!mounted) return;
      _showMessage(AuthMessages.fallback);
    } finally {
      if (mounted) setState(() => _mutatingIds.remove(user.id));
    }
  }

  String _statusSuccessMessage(bool activate) {
    return activate
        ? 'Потребителят е активиран.'
        : 'Потребителят е деактивиран.';
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.maybeOf(context);
    if (session == null ||
        !session.isAuthenticated ||
        session.role != UserRole.admin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Потребители')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Text(
              AuthMessages.forCode('FORBIDDEN'),
              key: const Key('admin-users-forbidden'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final page = _pageData;
    final canPrev = page != null && page.page > 1;
    final canNext =
        page != null && page.totalPages > 0 && page.page < page.totalPages;
    final currentUserId = session.user?.id;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppTokens.spaceMd,
                runSpacing: AppTokens.spaceSm,
                children: [
                  const Text(
                    'Потребители',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  PrimaryButton(
                    key: const Key('admin-user-create-button'),
                    label: 'Нов служител',
                    icon: Icons.person_add_alt_1,
                    expanded: false,
                    busy: _creating,
                    onPressed: _creating ? null : _openCreate,
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.spaceLg),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceSm,
                children: [
                  ChoiceChip(
                    key: const Key('admin-users-role-all'),
                    label: const Text('Всички роли'),
                    selected: _roleFilter == null,
                    onSelected: (_) => _changeRole(null),
                  ),
                  ChoiceChip(
                    key: const Key('admin-users-role-volunteer'),
                    label: const Text('Доброволец'),
                    selected: _roleFilter == UserRole.volunteer,
                    onSelected: (_) => _changeRole(UserRole.volunteer),
                  ),
                  ChoiceChip(
                    key: const Key('admin-users-role-responsible'),
                    label: const Text('Отговорник'),
                    selected: _roleFilter == UserRole.responsible,
                    onSelected: (_) => _changeRole(UserRole.responsible),
                  ),
                  ChoiceChip(
                    key: const Key('admin-users-role-admin'),
                    label: const Text('Администратор'),
                    selected: _roleFilter == UserRole.admin,
                    onSelected: (_) => _changeRole(UserRole.admin),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.spaceSm),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceSm,
                children: [
                  ChoiceChip(
                    key: const Key('admin-users-active-all'),
                    label: const Text('Всички'),
                    selected: _activeFilter == null,
                    onSelected: (_) => _changeActive(null),
                  ),
                  ChoiceChip(
                    key: const Key('admin-users-active-true'),
                    label: const Text('Активни'),
                    selected: _activeFilter == true,
                    onSelected: (_) => _changeActive(true),
                  ),
                  ChoiceChip(
                    key: const Key('admin-users-active-false'),
                    label: const Text('Деактивирани'),
                    selected: _activeFilter == false,
                    onSelected: (_) => _changeActive(false),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.spaceLg),
              if (_status == _UsersStatus.loading)
                const Center(
                  key: Key('admin-users-loading'),
                  child: Padding(
                    padding: EdgeInsets.all(AppTokens.spaceXl),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_status == _UsersStatus.error)
                Column(
                  key: const Key('admin-users-error'),
                  children: [
                    Text(
                      _errorMessage ?? AuthMessages.fallback,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.error),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),
                    OutlinedButton(
                      key: const Key('admin-users-retry'),
                      onPressed: _load,
                      child: const Text('Повтори'),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                    TextButton.icon(
                      key: const Key('admin-users-error-create'),
                      onPressed: _creating ? null : _openCreate,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Нов служител'),
                    ),
                  ],
                )
              else if (page == null || page.users.isEmpty)
                Column(
                  key: const Key('admin-users-empty'),
                  children: [
                    const Text('Няма намерени потребители.'),
                    const SizedBox(height: AppTokens.spaceMd),
                    TextButton.icon(
                      key: const Key('admin-users-empty-create'),
                      onPressed: _creating ? null : _openCreate,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Нов служител'),
                    ),
                  ],
                )
              else ...[
                Text(
                  'Общо потребители: ${page.total}',
                  key: const Key('admin-users-total'),
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  'Страница ${page.page} от '
                  '${page.totalPages == 0 ? 1 : page.totalPages}',
                  key: const Key('admin-users-page-info'),
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                for (final user in page.users)
                  UserCard(
                    key: Key('admin-user-card-${user.id}'),
                    user: user,
                    isCurrentUser: user.id == currentUserId,
                    onEdit:
                        _mutatingIds.contains(user.id)
                            ? null
                            : () => _openEdit(user),
                    onActivate:
                        user.isActive || _mutatingIds.contains(user.id)
                            ? null
                            : () => _toggleStatus(user, true),
                    onDeactivate:
                        !user.isActive || _mutatingIds.contains(user.id)
                            ? null
                            : () => _toggleStatus(user, false),
                  ),
                const SizedBox(height: AppTokens.spaceLg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      key: const Key('admin-users-prev'),
                      onPressed:
                          canPrev ? () => _goToPage(page.page - 1) : null,
                      child: const Text('Предишна'),
                    ),
                    TextButton(
                      key: const Key('admin-users-next'),
                      onPressed:
                          canNext ? () => _goToPage(page.page + 1) : null,
                      child: const Text('Следваща'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
