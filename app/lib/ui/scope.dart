/// Dependency injection for the app (spec §1.2 / §2): one [InheritedWidget]
/// exposing [AppDeps] to the widget tree.
///
/// No state-management package is used — controllers are plain
/// `ChangeNotifier` objects reached through this scope (spec §1.2).
///
/// **Layering (M4 §8.1):** `ui/**` may import `package:flutter/*` but never
/// `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/widgets.dart';

import '../bootstrap/app_deps.dart';

/// Exposes the wired [AppDeps] to descendants.
class AppScope extends InheritedWidget {
  /// Creates the scope around [child].
  const AppScope({super.key, required this.deps, required super.child});

  /// The wired ports and configuration.
  final AppDeps deps;

  /// The closest enclosing [AppScope].
  ///
  /// Throws (via the assert) when no [AppScope] is present, which catches a
  /// mis-wired tree during development.
  static AppScope of(BuildContext context) {
    final AppScope? scope =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(
      scope != null,
      'AppScope.of() was called with a context that does not contain an '
      'AppScope. Wrap the subtree in AppScope (see app.dart / T05 wiring).',
    );
    return scope!;
  }

  /// The wired [AppDeps] of the closest enclosing [AppScope].
  static AppDeps depsOf(BuildContext context) => of(context).deps;

  @override
  bool updateShouldNotify(AppScope oldWidget) => deps != oldWidget.deps;
}

/// Convenience accessors: `context.deps` and `context.appScope`.
extension AppScopeContext on BuildContext {
  /// The closest enclosing [AppScope].
  AppScope get appScope => AppScope.of(this);

  /// The wired [AppDeps] of the closest enclosing [AppScope].
  AppDeps get deps => AppScope.of(this).deps;
}
