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

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  late SessionController _session;
  bool _submitting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.of(context);
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
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
      final result = await _session.signInStaff(
        phone: phone,
        password: _passwordController.text,
      );
      if (!mounted || result == null) return;
      routed = true;
      _routeAfterSignIn(result.user.mustChangePassword);
    } on ApiException catch (error) {
      if (!mounted) return;
      _showMessage(AuthMessages.forException(error));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Служебен вход')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Влезте със служебния си профил, за да управлявате смени и '
                  'отчети.',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                const Text(
                  'Този вход е само за отговорници и администратори.',
                  style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
                ),
                const SizedBox(height: AppTokens.spaceXl),
                TextFormField(
                  key: const Key('staff-login-phone-field'),
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    hintText: PhoneFormat.example,
                  ),
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
                const SizedBox(height: AppTokens.spaceLg),
                TextFormField(
                  key: const Key('staff-login-password-field'),
                  controller: _passwordController,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Парола'),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Въведете парола.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceXl),
                PrimaryButton(
                  key: const Key('staff-login-submit-button'),
                  label: 'Вход',
                  icon: Icons.login_outlined,
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
