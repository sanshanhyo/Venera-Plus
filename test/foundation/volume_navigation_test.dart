import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/volume_navigation.dart';

void main() {
  const channel = MethodChannel('venera/volume');
  var subscriptions = 0;
  var maxSubscriptions = 0;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
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
    debugDefaultTargetPlatformOverride = null;
  });

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
    expect(subscriptions, 0);
  }

  testWidgets('only the innermost active page owns one native listener', (
    tester,
  ) async {
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

  testWidgets('root dialogs suspend nested pages and reader takes ownership', (
    tester,
  ) async {
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
    await tester.pumpAndSettle();
    await emit(tester, 2);
    expect(directoryNext, 1);
    showDialog<void>(
      context: directoryContext,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    expect(subscriptions, 0);
    await emit(tester, 2);
    expect(directoryNext, 1);
    root.currentState!.pop();
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    await emit(tester, 2);
    expect([directoryNext, readerNext], [2, 1]);
    nested.currentState!.pop();
    await tester.pumpAndSettle();
    await emit(tester, 2);
    expect([directoryNext, readerNext], [3, 1]);
    expect(maxSubscriptions, 1);
    await clear(tester);
  });

  testWidgets(
    'hidden pages, editing, disabled settings and background release keys',
    (tester) async {
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
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(subscriptions, 0);
      await emit(tester, 2);
      expect(next, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await emit(tester, 2);
      expect(next, 2);
      await clear(tester);
      focus.dispose();
    },
  );
}
