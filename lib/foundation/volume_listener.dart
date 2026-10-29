import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class VolumeListener {
  static const channel = EventChannel('venera/volume');

  void Function()? onUp;

  void Function()? onDown;

  VolumeListener({this.onUp, this.onDown});

  StreamSubscription<dynamic>? stream;

  void listen() {
    stream ??= channel.receiveBroadcastStream().listen(
      onEvent,
      onError: (Object error) {
        debugPrint('Volume key listener failed: $error');
      },
    );
  }

  void onEvent(dynamic event) {
    if (event == 1) {
      onUp?.call();
    } else if (event == 2) {
      onDown?.call();
    }
  }

  Future<void> cancel() async {
    final previous = stream;
    stream = null;
    await previous?.cancel();
  }
}
