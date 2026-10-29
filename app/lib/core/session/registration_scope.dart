import 'package:flutter/widgets.dart';

import 'registration_state_controller.dart';

/// Provides the shared [RegistrationStateController] to the widget tree.
///
/// Mirrors [SessionScope]: an [InheritedNotifier] rebuilds dependants when the
/// controller notifies, so no additional state-management dependency is
/// needed.
class RegistrationScope extends InheritedNotifier<RegistrationStateController> {
  const RegistrationScope({
    super.key,
    required RegistrationStateController controller,
    required super.child,
  }) : super(notifier: controller);

  static RegistrationStateController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RegistrationScope>();
    assert(
      scope?.notifier != null,
      'RegistrationScope was not found in the widget tree.',
    );
    return scope!.notifier!;
  }

  static RegistrationStateController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<RegistrationScope>()
        ?.notifier;
  }
}
