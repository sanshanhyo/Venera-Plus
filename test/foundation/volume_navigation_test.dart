import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/volume_navigation.dart';

void main() {
  const channel = MethodChannel('venera/volume');
  var subscriptions = 0;
  var maxSubscriptions = 0;

  setUp(() {
    subscriptions = 0;
    maxSubscriptions = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listen') {
            subscriptions++;
            if (subscriptions > maxSubscriptions) {
              maxSubscriptions = subscriptions;
            }
          } else if (call.method == 'cancel') {
            subscriptions--;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    VolumePageScope.debugPlatformSupportedOverride = null;
  });

  Future<void> withSimulatedPlatform(
    WidgetTester tester,
    Future<void> Function() body, {
    bool simulateAndroid = true,
  }) async {
    VolumePageScope.debugPlatformSupportedOverride = simulateAndroid
        ? true
        : null;
    try {
      await body();
    } finally {
      // Dispose before the mock channel is removed, including failed cases.
      // Otherwise a delayed cancellation can leak into the next test.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.binding.defaultBinaryMessenger.platformMessagesFinished;
      VolumePageScope.debugPlatformSupportedOverride = null;
    }
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.binding.defaultBinaryMessenger.platformMessagesFinished;
    await tester.pump();
  }

  Future<void> emit(WidgetTester tester, int event) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> clear(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.binding.defaultBinaryMessenger.platformMessagesFinished;
    expect(subscriptions, 0);
  }

  testWidgets(
    'Android styling on a non-Android host does not open a native channel',
    (tester) async {
      await withSimulatedPlatform(tester, () async {
        var next = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            navigatorObservers: [VolumeNavigationObserver()],
            home: VolumePageScope(
              onPrevious: () {},
              onNext: () => next++,
              child: const SizedBox(),
            ),
          ),
        );
        await settle(tester);
        expect(subscriptions, 0);
        await emit(tester, 2);
        expect(next, 0);
        await clear(tester);
      }, simulateAndroid: false);
    },
    skip: Platform.isAndroid,
  );

  testWidgets('only the innermost active page owns one native listener', (
    tester,
  ) async {
    await withSimulatedPlatform(tester, () async {
      var outer = 0;
      var innerPrevious = 0;
      var innerNext = 0;
      var showInner = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [VolumeNavigationObserver()],
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return VolumePageScope(
                onPrevious: () => outer++,
                onNext: () => outer++,
                child: showInner
                    ? VolumePageScope(
                        onPrevious: () => innerPrevious++,
                        onNext: () => innerNext++,
                        child: const SizedBox(),
                      )
                    : const SizedBox(),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await emit(tester, 1);
      await emit(tester, 2);
      expect([outer, innerPrevious, innerNext], [0, 1, 1]);
      expect(subscriptions, 1);
      rebuild(() => showInner = false);
      await tester.pump();
      await emit(tester, 2);
      expect(outer, 1);
      expect(maxSubscriptions, 1);
      await clear(tester);
    });
  });

  testWidgets('root dialogs suspend nested pages and reader takes ownership', (
    tester,
  ) async {
    await withSimulatedPlatform(tester, () async {
      final root = GlobalKey<NavigatorState>();
      final nested = GlobalKey<NavigatorState>();
      var directoryNext = 0;
      var readerNext = 0;
      late BuildContext directoryContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: root,
          navigatorObservers: [VolumeNavigationObserver()],
          home: Navigator(
            key: nested,
            observers: [VolumeNavigationObserver()],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) {
                directoryContext = context;
                return VolumePageScope(
                  onPrevious: () {},
                  onNext: () => directoryNext++,
                  child: const Scaffold(body: Text('directory')),
                );
              },
            ),
          ),
        ),
      );
      await settle(tester);
      await emit(tester, 2);
      expect(directoryNext, 1);
      showDialog<void>(
        context: directoryContext,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await settle(tester);
      expect(subscriptions, 0);
      await emit(tester, 2);
      expect(directoryNext, 1);
      root.currentState!.pop();
      await settle(tester);
      expect(subscriptions, 1, reason: 'closing the root dialog restores keys');
      await emit(tester, 2);
      expect(directoryNext, 2);
      nested.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => VolumePageScope(
            onPrevious: () {},
            onNext: () => readerNext++,
            child: const Scaffold(body: Text('reader')),
          ),
        ),
      );
      await settle(tester);
      await emit(tester, 2);
      expect([directoryNext, readerNext], [2, 1]);
      nested.currentState!.pop();
      await settle(tester);
      await emit(tester, 2);
      expect([directoryNext, readerNext], [3, 1]);
      expect(maxSubscriptions, 1);
      await clear(tester);
    });
  });

  testWidgets(
    'hidden pages, editing, disabled settings and background release keys',
    (tester) async {
      await withSimulatedPlatform(tester, () async {
        var enabled = true;
        var active = true;
        var tickers = true;
        var next = 0;
        final focus = FocusNode();
        late StateSetter rebuild;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [VolumeNavigationObserver()],
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return TickerMode(
                  enabled: tickers,
                  child: VolumePageScope(
                    enabled: enabled,
                    active: active,
                    onPrevious: () {},
                    onNext: () => next++,
                    child: Scaffold(body: TextField(focusNode: focus)),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await emit(tester, 2);
        expect(next, 1);
        for (final change in <VoidCallback>[
          () => enabled = false,
          () => active = false,
          () => tickers = false,
        ]) {
          rebuild(change);
          await tester.pumpAndSettle();
          expect(subscriptions, 0);
          await emit(tester, 2);
          expect(next, 1);
          rebuild(() => enabled = active = tickers = true);
          await tester.pumpAndSettle();
          expect(subscriptions, 1);
        }
        focus.requestFocus();
        await tester.pumpAndSettle();
        expect(subscriptions, 0);
        await emit(tester, 2);
        expect(next, 1);
        focus.unfocus();
        await tester.pumpAndSettle();
        expect(subscriptions, 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(subscriptions, 0);
        await emit(tester, 2);
        expect(next, 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await emit(tester, 2);
        expect(next, 2);
        await clear(tester);
        focus.dispose();
      });
    },
  );
}
