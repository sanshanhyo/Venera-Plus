import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'volume_listener.dart';

/// Gives Android volume keys to the visible page, releasing them for normal
/// volume adjustment while a dialog, text field, or another page is active.
class VolumePageScope extends StatefulWidget {
  const VolumePageScope({
    super.key,
    this.enabled = true,
    this.active = true,
    required this.onPrevious,
    required this.onNext,
    required this.child,
  });

  final bool enabled;
  final bool active;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Widget child;

  @override
  State<VolumePageScope> createState() => _VolumePageScopeState();
}

class _VolumePageScopeState extends State<VolumePageScope> {
  final _routes = <ModalRoute<dynamic>>[];
  bool _tickerEnabled = false;
  bool _attached = true;

  bool get canHandle =>
      mounted &&
      _attached &&
      widget.enabled &&
      widget.active &&
      _tickerEnabled &&
      _routes.every((route) => route.isCurrent);

  @override
  void initState() {
    super.initState();
    _VolumeNavigation.instance.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _routes.clear();
    final ownRoute = ModalRoute.of(context);
    if (ownRoute != null) _routes.add(ownRoute);
    // A root dialog can cover a page inside the main nested Navigator without
    // changing that page's own route. Include the enclosing route of each
    // ancestor Navigator as well.
    context.visitAncestorElements((element) {
      if (element.widget is Navigator) {
        final parentRoute = ModalRoute.of(element);
        if (parentRoute != null && !_routes.contains(parentRoute)) {
          _routes.add(parentRoute);
        }
      }
      return true;
    });
    _VolumeNavigation.instance.refresh();
  }

  @override
  void didUpdateWidget(VolumePageScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _VolumeNavigation.instance.refresh();
  }

  @override
  void activate() {
    super.activate();
    _attached = true;
    _VolumeNavigation.instance.refresh();
  }

  @override
  void deactivate() {
    _attached = false;
    _VolumeNavigation.instance.refresh();
    super.deactivate();
  }

  @override
  void dispose() {
    _VolumeNavigation.instance.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Install once on each Navigator that can cover a volume-controlled page.
class VolumeNavigationObserver extends NavigatorObserver {
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _VolumeNavigation.instance.refresh();
  }
}

class _VolumeNavigation with WidgetsBindingObserver {
  static final instance = _VolumeNavigation();

  final _scopes = <_VolumePageScopeState>[];
  VolumeListener? _listener;
  bool _syncing = false;
  bool _scheduled = false;
  AppLifecycleState? _lifecycle;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _editing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.mounted &&
        (context.widget is EditableText ||
            context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  _VolumePageScopeState? get _owner {
    if (!_supported ||
        (_lifecycle != null && _lifecycle != AppLifecycleState.resumed) ||
        _editing) {
      return null;
    }
    for (final scope in _scopes.reversed) {
      if (scope.canHandle) return scope;
    }
    return null;
  }

  void add(_VolumePageScopeState scope) {
    if (_scopes.isEmpty) {
      _lifecycle = WidgetsBinding.instance.lifecycleState;
      WidgetsBinding.instance.addObserver(this);
      FocusManager.instance.addListener(refresh);
    }
    _scopes.add(scope);
    refresh();
  }

  void remove(_VolumePageScopeState scope) {
    _scopes.remove(scope);
    if (_scopes.isEmpty) {
      WidgetsBinding.instance.removeObserver(this);
      FocusManager.instance.removeListener(refresh);
    }
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    refresh();
  }

  void refresh() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      unawaited(_syncListener());
    });
  }

  // Serialize cancel/relisten: cancelling an old EventChannel subscription
  // after opening its replacement would otherwise cancel the new native sink.
  Future<void> _syncListener() async {
    if (_syncing) return;
    _syncing = true;
    try {
      while (true) {
        final needed = _owner != null;
        if (needed == (_listener != null)) return;
        if (needed) {
          _listener = VolumeListener(
            onUp: () => _owner?.widget.onPrevious(),
            onDown: () => _owner?.widget.onNext(),
          )..listen();
        } else {
          final previous = _listener;
          _listener = null;
          await previous?.cancel();
        }
      }
    } finally {
      _syncing = false;
    }
  }
}
