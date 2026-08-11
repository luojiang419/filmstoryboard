import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Handles the shared Ctrl+B shortcut for page-level collapsible panels.
class CollapsiblePanelShortcutScope extends StatefulWidget {
  const CollapsiblePanelShortcutScope({super.key, required this.child});

  final Widget child;

  @override
  State<CollapsiblePanelShortcutScope> createState() =>
      _CollapsiblePanelShortcutScopeState();
}

class _CollapsiblePanelShortcutScopeState
    extends State<CollapsiblePanelShortcutScope> {
  final Map<Object, _PanelRegistration> _registrations = {};

  void register(
    Object token, {
    required bool expanded,
    required ValueChanged<bool> onExpandedChanged,
  }) {
    _registrations[token] = _PanelRegistration(
      expanded: expanded,
      onExpandedChanged: onExpandedChanged,
    );
  }

  void unregister(Object token) {
    _registrations.remove(token);
  }

  void _toggleRegisteredPanels() {
    if (_registrations.isEmpty) {
      return;
    }
    final expand = !_registrations.values.every(
      (registration) => registration.expanded,
    );
    for (final registration in [..._registrations.values]) {
      if (registration.expanded != expand) {
        registration.onExpandedChanged(expand);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            _toggleRegisteredPanels,
      },
      child: Focus(
        autofocus: true,
        child: _CollapsiblePanelRegistry(state: this, child: widget.child),
      ),
    );
  }
}

class CollapsiblePanelRegistration extends StatefulWidget {
  const CollapsiblePanelRegistration({
    super.key,
    required this.expanded,
    required this.onExpandedChanged,
    required this.child,
  });

  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final Widget child;

  @override
  State<CollapsiblePanelRegistration> createState() =>
      _CollapsiblePanelRegistrationState();
}

class _CollapsiblePanelRegistrationState
    extends State<CollapsiblePanelRegistration> {
  List<_CollapsiblePanelShortcutScopeState> _scopes = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextScopes = <_CollapsiblePanelShortcutScopeState>[];
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is _CollapsiblePanelRegistry) {
        nextScopes.add(widget.state);
      }
      return true;
    });
    if (!_sameScopes(_scopes, nextScopes)) {
      for (final scope in _scopes) {
        scope.unregister(this);
      }
      _scopes = nextScopes;
    }
    _register();
  }

  @override
  void didUpdateWidget(CollapsiblePanelRegistration oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  @override
  void dispose() {
    for (final scope in _scopes) {
      scope.unregister(this);
    }
    super.dispose();
  }

  void _register() {
    for (final scope in _scopes) {
      scope.register(
        this,
        expanded: widget.expanded,
        onExpandedChanged: widget.onExpandedChanged,
      );
    }
  }

  bool _sameScopes(
    List<_CollapsiblePanelShortcutScopeState> first,
    List<_CollapsiblePanelShortcutScopeState> second,
  ) {
    if (first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index++) {
      if (!identical(first[index], second[index])) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _CollapsiblePanelRegistry extends InheritedWidget {
  const _CollapsiblePanelRegistry({required this.state, required super.child});

  final _CollapsiblePanelShortcutScopeState state;

  @override
  bool updateShouldNotify(_CollapsiblePanelRegistry oldWidget) =>
      !identical(state, oldWidget.state);
}

class _PanelRegistration {
  const _PanelRegistration({
    required this.expanded,
    required this.onExpandedChanged,
  });

  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
}
