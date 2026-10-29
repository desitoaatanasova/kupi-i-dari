import 'package:flutter/material.dart';

import '../core/api/admin_users_api.dart';
import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/auth/auth_messages.dart';
import '../core/auth/phone_format.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';
import '../widgets/primary_button.dart';

class AdminUserEditorScreen extends StatefulWidget {
  const AdminUserEditorScreen({super.key, this.user, this.adminUsersApi});

  final AppUser? user;

  /// Optional injected API for tests and for callers that already resolved it.
  final AdminUsersApi? adminUsersApi;

  @override
  State<AdminUserEditorScreen> createState() => _AdminUserEditorScreenState();
}

class _AdminUserEditorScreenState extends State<AdminUserEditorScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  UserRole _role = UserRole.responsible;
  bool _submitting = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;
  String? _formError;

  bool get _isEditing => widget.user != null;

  @override
  void initState() {
    super.initState();
    final user = widget.user;
    if (user != null) {
      _firstNameController.text = user.firstName;
      _lastNameController.text = user.lastName;
      _phoneController.text = user.phone;
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final phoneInput = _phoneController.text;
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (firstName.isEmpty) {
      setState(() => _formError = 'Въведете име.');
      return;
    }
    if (firstName.length > 60) {
      setState(() => _formError = 'Името може да е до 60 знака.');
      return;
    }
    if (lastName.isEmpty) {
      setState(() => _formError = 'Въведете фамилия.');
      return;
    }
    if (lastName.length > 60) {
      setState(() => _formError = 'Фамилията може да е до 60 знака.');
      return;
    }
    final phone = PhoneFormat.tryNormalize(phoneInput);
    if (phone == null) {
      setState(() => _formError = 'Въведете валиден телефонен номер.');
      return;
    }
    if (!_isEditing) {
      if (password.length < 8) {
        setState(() => _formError = 'Паролата трябва да е поне 8 символа.');
        return;
      }
      if (password.length > 200) {
        setState(() => _formError = 'Паролата може да е до 200 символа.');
        return;
      }
      if (password != confirmPassword) {
        setState(() => _formError = 'Паролите не съвпадат.');
        return;
      }
    }

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) {
      setState(() => _formError = AuthMessages.forCode('UNAUTHORIZED'));
      return;
    }
    final api = widget.adminUsersApi ?? ApiScope.maybeAdminUsersOf(context);
    if (api == null) {
      setState(() => _formError = AuthMessages.fallback);
      return;
    }

    setState(() {
      _submitting = true;
      _formError = null;
    });

    try {
      final AppUser result;
      if (_isEditing) {
        result = await api.updateUserProfile(
          widget.user!.id,
          token: token,
          firstName: firstName,
          lastName: lastName,
          phone: phone,
        );
      } else {
        result = await api.createStaff(
          token: token,
          firstName: firstName,
          lastName: lastName,
          phone: phone,
          role: _role,
          password: password,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() {
        _submitting = false;
        _formError = AuthMessages.forException(error);
      });
    } catch (_) {
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
        title: Text(_isEditing ? 'Редактиране на потребител' : 'Нов служител'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: [
            TextFormField(
              key: const Key('admin-user-first-name-field'),
              controller: _firstNameController,
              enabled: !_submitting,
              maxLength: 60,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Име'),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            TextFormField(
              key: const Key('admin-user-last-name-field'),
              controller: _lastNameController,
              enabled: !_submitting,
              maxLength: 60,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Фамилия'),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            TextFormField(
              key: const Key('admin-user-phone-field'),
              controller: _phoneController,
              enabled: !_submitting,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Телефон',
                hintText: PhoneFormat.example,
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            if (_isEditing)
              TextFormField(
                key: const Key('admin-user-role-readonly'),
                initialValue: widget.user!.role.label,
                enabled: false,
                decoration: const InputDecoration(labelText: 'Роля'),
              )
            else ...[
              DropdownButtonFormField<UserRole>(
                key: const Key('admin-user-role-field'),
                value: _role,
                decoration: const InputDecoration(labelText: 'Роля'),
                items: const [
                  DropdownMenuItem(
                    value: UserRole.responsible,
                    child: Text('Отговорник'),
                  ),
                  DropdownMenuItem(
                    value: UserRole.admin,
                    child: Text('Администратор'),
                  ),
                ],
                onChanged:
                    _submitting
                        ? null
                        : (value) {
                          if (value != null) {
                            setState(() => _role = value);
                          }
                        },
              ),
              const SizedBox(height: AppTokens.spaceSm),
              const Text(
                'Доброволците се идентифицират сами и не се създават оттук.',
                style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              TextFormField(
                key: const Key('admin-user-password-field'),
                controller: _passwordController,
                enabled: !_submitting,
                obscureText: !_showPassword,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Начална парола',
                  suffixIcon: IconButton(
                    tooltip:
                        _showPassword ? 'Скрий паролата' : 'Покажи паролата',
                    onPressed:
                        _submitting
                            ? null
                            : () =>
                                setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              TextFormField(
                key: const Key('admin-user-confirm-password-field'),
                controller: _confirmPasswordController,
                enabled: !_submitting,
                obscureText: !_showConfirmPassword,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Повторете паролата',
                  suffixIcon: IconButton(
                    tooltip:
                        _showConfirmPassword
                            ? 'Скрий паролата'
                            : 'Покажи паролата',
                    onPressed:
                        _submitting
                            ? null
                            : () => setState(
                              () =>
                                  _showConfirmPassword = !_showConfirmPassword,
                            ),
                    icon: Icon(
                      _showConfirmPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              const Text(
                'Новият служител ще трябва да смени паролата при първия си вход.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
            if (_formError != null) ...[
              const SizedBox(height: AppTokens.spaceLg),
              Text(
                _formError!,
                key: const Key('admin-user-form-error'),
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: AppTokens.spaceXl),
            PrimaryButton(
              key: const Key('admin-user-save-button'),
              label: _isEditing ? 'Запази промените' : 'Създай служител',
              icon: _isEditing ? Icons.save_outlined : Icons.person_add_alt_1,
              busy: _submitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
