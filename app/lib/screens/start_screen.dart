import 'package:flutter/material.dart';

import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../widgets/app_shell.dart';
import '../widgets/primary_button.dart';
import 'change_password_screen.dart';
import 'login_screen.dart';
import 'registration_screen.dart';
import 'volunteer_identification_screen.dart';

class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final user = session.user;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
                  boxShadow: AppTokens.cardShadow,
                ),
                child: const Icon(
                  Icons.volunteer_activism,
                  color: Colors.white,
                  size: 48,
                ),
              ),
              const SizedBox(height: AppTokens.spaceLg),
              const Text(
                'Купи и Дари',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              const Text(
                'Даряване, което стига до хората.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
              ),
              const Spacer(),
              if (session.notice != null) ...[
                _NoticeBanner(
                  message: session.notice!,
                  onDismiss: session.clearNotice,
                ),
                const SizedBox(height: AppTokens.spaceMd),
              ],
              if (session.isAuthenticated) ...[
                _SessionCard(
                  name: user?.fullName ?? '',
                  role: user?.role.label ?? '',
                ),
                const SizedBox(height: AppTokens.spaceLg),
                PrimaryButton(
                  label: 'Продължи',
                  icon: Icons.arrow_forward_outlined,
                  onPressed:
                      () => _push(
                        context,
                        session.mustChangePassword
                            ? const ChangePasswordScreen()
                            : const AppShell(),
                      ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextButton(
                  onPressed: session.signOut,
                  child: const Text('Изход'),
                ),
              ] else ...[
                PrimaryButton(
                  label: 'Вход',
                  icon: Icons.login_outlined,
                  onPressed:
                      () =>
                          _push(context, const VolunteerIdentificationScreen()),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                PrimaryButton(
                  label: 'Регистрация',
                  icon: Icons.person_add_outlined,
                  onPressed: () => _push(context, const RegistrationScreen()),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextButton(
                  onPressed: () => _push(context, const LoginScreen()),
                  child: const Text('Служебен вход'),
                ),
              ],
              const SizedBox(height: AppTokens.spaceSm),
              TextButton(
                onPressed:
                    () => _push(
                      context,
                      session.mustChangePassword
                          ? const ChangePasswordScreen()
                          : const AppShell(),
                    ),
                child: const Text('Разгледай демо съдържанието'),
              ),
              const SizedBox(height: AppTokens.spaceLg),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.name, required this.role});

  final String name;
  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_circle_outlined, color: AppColors.primary),
          const SizedBox(width: AppTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  role,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.secondary, size: 20),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Затвори',
          ),
        ],
      ),
    );
  }
}
