import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/auth/auth_messages.dart';
import '../core/auth/phone_format.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../widgets/app_shell.dart';
import '../widgets/primary_button.dart';
import 'change_password_screen.dart';
import 'registration_screen.dart';

/// Passwordless volunteer login: first name + last name + phone.
///
/// This never creates an account. New volunteers register first.
class VolunteerIdentificationScreen extends StatefulWidget {
  const VolunteerIdentificationScreen({super.key});

  @override
  State<VolunteerIdentificationScreen> createState() =>
      _VolunteerIdentificationScreenState();
}

class _VolunteerIdentificationScreenState
    extends State<VolunteerIdentificationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();

  late SessionController _session;
  bool _submitting = false;

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

    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);

    var routed = false;
    try {
      final result = await _session.signInVolunteer(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        phone: phone,
      );
      if (!mounted || result == null) return;
      routed = true;
      _routeAfterSignIn(result.user.mustChangePassword);
    } on ApiException catch (error) {
      if (!mounted) return;
      _showMessage(
        error.code == 'INVALID_CREDENTIALS'
            ? AuthMessages.invalidVolunteerCredentials
            : AuthMessages.forException(error),
      );
    } catch (_) {
      if (!mounted) return;
      _showMessage(AuthMessages.fallback);
    } finally {
      if (!routed && mounted) setState(() => _submitting = false);
    }
  }

  void _routeAfterSignIn(bool mustChangePassword) {
    final route =
        mustChangePassword
            ? MaterialPageRoute<void>(
              builder: (_) => const ChangePasswordScreen(),
            )
            : MaterialPageRoute<void>(builder: (_) => const AppShell());
    Navigator.of(context).pushAndRemoveUntil(route, (route) => route.isFirst);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
      appBar: AppBar(title: const Text('Вход за доброволци')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Въведете име, фамилия и телефон на своя профил. Влизането е '
                  'възможно само за вече регистриран доброволец.',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXl),
                TextFormField(
                  key: const Key('volunteer-login-first-name-field'),
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
                  key: const Key('volunteer-login-last-name-field'),
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
                  key: const Key('volunteer-login-phone-field'),
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
                PrimaryButton(
                  key: const Key('volunteer-login-submit-button'),
                  label: 'Влез',
                  icon: Icons.login_outlined,
                  busy: _submitting,
                  onPressed: _submitting ? null : _submit,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextButton(
                  onPressed:
                      _submitting
                          ? null
                          : () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const RegistrationScreen(),
                              ),
                            );
                          },
                  child: const Text('Нямате профил? Регистрирайте се'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
