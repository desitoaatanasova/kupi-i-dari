import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/auth/auth_messages.dart';
import '../core/auth/phone_format.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';
import '../widgets/app_shell.dart';
import '../widgets/primary_button.dart';
import 'change_password_screen.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();

  late SessionController _session;
  UserRole _role = UserRole.volunteer;
  bool _submitting = false;
  String? _formError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.of(context);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    final phone = PhoneFormat.tryNormalize(_phoneController.text);
    if (phone == null) return;
    if (_role != UserRole.volunteer) {
      setState(() {
        _formError = 'Публичната регистрация е само за доброволци.';
      });
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _formError = null;
    });

    var routed = false;
    try {
      final result = await _session.registerVolunteer(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        phone: phone,
        role: _role,
      );
      if (!mounted || result == null) return;
      routed = true;
      _routeAfterRegistration(result.user.mustChangePassword);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _formError = _messageFor(error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _formError = AuthMessages.fallback);
    } finally {
      if (!routed && mounted) setState(() => _submitting = false);
    }
  }

  String _messageFor(ApiException error) {
    if (error.code == 'INVALID_CREDENTIALS') {
      return AuthMessages.invalidVolunteerCredentials;
    }
    return AuthMessages.forException(error);
  }

  void _routeAfterRegistration(bool mustChangePassword) {
    final route =
        mustChangePassword
            ? MaterialPageRoute<void>(
              builder: (_) => const ChangePasswordScreen(),
            )
            : MaterialPageRoute<void>(builder: (_) => const AppShell());
    Navigator.of(context).pushAndRemoveUntil(route, (route) => route.isFirst);
  }

  String? _validateName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return 'Попълнете полето.';
    if (trimmed.length > 60) return 'Може да е до 60 знака.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Регистрация')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Създайте профил на доброволец. След регистрацията ще влезете '
                  'автоматично и ще можете да се записвате за смени.',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXl),
                TextFormField(
                  key: const Key('registration-first-name-field'),
                  controller: _firstNameController,
                  enabled: !_submitting,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  maxLength: 60,
                  autofillHints: const [AutofillHints.givenName],
                  decoration: const InputDecoration(labelText: 'Име'),
                  validator: _validateName,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextFormField(
                  key: const Key('registration-last-name-field'),
                  controller: _lastNameController,
                  enabled: !_submitting,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  maxLength: 60,
                  autofillHints: const [AutofillHints.familyName],
                  decoration: const InputDecoration(labelText: 'Фамилия'),
                  validator: _validateName,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextFormField(
                  key: const Key('registration-phone-field'),
                  controller: _phoneController,
                  enabled: !_submitting,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    hintText: PhoneFormat.example,
                  ),
                  onFieldSubmitted: (_) => _submit(),
                  validator: (value) {
                    final phone = value?.trim() ?? '';
                    if (phone.isEmpty) {
                      return 'Въведете телефонен номер.';
                    }
                    if (!PhoneFormat.isValid(phone)) {
                      return 'Въведете валиден телефонен номер.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceXl),
                const Text(
                  'Роля',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSecondary,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      RadioListTile<UserRole>(
                        key: const Key('registration-role-volunteer'),
                        value: UserRole.volunteer,
                        groupValue: _role,
                        onChanged:
                            _submitting
                                ? null
                                : (value) {
                                  if (value != null) {
                                    setState(() => _role = value);
                                  }
                                },
                        title: const Text('Доброволец'),
                        subtitle: const Text('Публична регистрация'),
                      ),
                      const Divider(height: 1),
                      const ListTile(
                        key: Key('registration-role-responsible'),
                        enabled: false,
                        leading: Icon(Icons.lock_outline),
                        title: Text('Отговорник'),
                        subtitle: Text('Профилът се създава от администратор.'),
                      ),
                      const Divider(height: 1),
                      const ListTile(
                        key: Key('registration-role-admin'),
                        enabled: false,
                        leading: Icon(Icons.lock_outline),
                        title: Text('Администратор'),
                        subtitle: Text('Профилът се създава от администратор.'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                const Text(
                  'Служебните профили с парола се създават само от администратор.',
                  style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
                ),
                if (_formError != null) ...[
                  const SizedBox(height: AppTokens.spaceLg),
                  Text(
                    _formError!,
                    key: const Key('registration-form-error'),
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: AppTokens.spaceXl),
                PrimaryButton(
                  key: const Key('registration-submit-button'),
                  label: 'Регистрирай се',
                  icon: Icons.person_add_alt_1,
                  busy: _submitting,
                  onPressed: _submitting ? null : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
