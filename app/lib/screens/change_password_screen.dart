import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../widgets/app_shell.dart';
import '../widgets/primary_button.dart';
import 'start_screen.dart';

/// Mandatory (or voluntary) password change for an authenticated staff user.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  late SessionController _session;
  bool _submitting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.of(context);
  }

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);

    var routed = false;
    try {
      final updated = await _session.changePassword(
        currentPassword: _currentController.text,
        newPassword: _newController.text,
      );
      if (!mounted || updated == null) return;

      if (!updated.user.mustChangePassword) {
        routed = true;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => const AppShell()),
          (route) => route.isFirst,
        );
        return;
      }

      _showMessage(
        'Паролата е сменена, но профилът все още изисква нова парола.',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        _returnToStart();
        return;
      }
      _showMessage(AuthMessages.forException(error));
    } finally {
      if (!routed && mounted) setState(() => _submitting = false);
    }
  }

  void _returnToStart() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const StartScreen()),
      (route) => false,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final mandatory = _session.mustChangePassword;

    return Scaffold(
      appBar: AppBar(title: const Text('Смяна на парола')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  mandatory
                      ? 'Трябва да смените паролата си, преди да продължите.'
                      : 'Сменете паролата си.',
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXl),
                TextFormField(
                  controller: _currentController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Текуща парола'),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Въведете текущата парола.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceLg),
                TextFormField(
                  controller: _newController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Нова парола'),
                  validator: (value) {
                    final password = value ?? '';
                    if (password.length < 8) {
                      return 'Паролата трябва да е поне 8 символа.';
                    }
                    if (password == _currentController.text) {
                      return 'Новата парола трябва да е различна от текущата.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceLg),
                TextFormField(
                  controller: _confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Повторете новата парола',
                  ),
                  validator: (value) {
                    if (value != _newController.text) {
                      return 'Паролите не съвпадат.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceXl),
                PrimaryButton(
                  label: 'Смени паролата',
                  icon: Icons.lock_reset_outlined,
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
