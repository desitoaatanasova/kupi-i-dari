import 'package:flutter/widgets.dart';

import 'session_controller.dart';

/// Provides the single [SessionController] to the widget tree.
///
/// An [InheritedNotifier] rebuilds dependants when the controller notifies, so
/// no additional state-management dependency is needed.
class SessionScope extends InheritedNotifier<SessionController> {
  const SessionScope({
    super.key,
    required SessionController controller,
    required super.child,
  }) : super(notifier: controller);

  static SessionController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(
      scope?.notifier != null,
      'SessionScope was not found in the widget tree.',
    );
    return scope!.notifier!;
  }

  static SessionController? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SessionScope>()?.notifier;
  }
}
