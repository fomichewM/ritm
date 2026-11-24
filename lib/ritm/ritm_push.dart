// «Ритм» B6 — пуши чата команды: токен APNs → сервер, тап по пушу → чат.
//
// Натив — RitmPush в ios/Runner/AppDelegate.swift (канал `ritm/push`).
// Разрешение спрашиваем только после входа в «Сообщество» и согласия.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ritm_community_api.dart';
import 'ritm_demo.dart' show kRitmDemo;

/// Команда, чат которой надо открыть (тап по пушу). Слушают оболочка и «Сообщество».
final ritmPushOpen = ValueNotifier<int?>(null);

class RitmPushBridge {
  RitmPushBridge._();

  static const _ch = MethodChannel('ritm/push');
  static bool _wired = false;
  static String? _sentToken;

  /// Подключить канал (один раз) и, если вошли и согласились, — попросить токен.
  static Future<void> ensure(RitmCommunity c) async {
    if (kRitmDemo || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!_wired) {
      _wired = true;
      _ch.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'token':
            await _send(c, call.arguments as String?);
          case 'open':
            ritmPushOpen.value = (call.arguments as num?)?.toInt();
        }
        return null;
      });
      try {
        final pending = await _ch.invokeMethod<int>('pendingOpen');
        if (pending != null) ritmPushOpen.value = pending;
      } catch (_) {}
    }
    if (c.stage != RStage.ready) return;
    try {
      await _ch.invokeMethod<bool>('register');
      await _send(c, await _ch.invokeMethod<String>('token'));
    } catch (_) {}
  }

  static Future<void> _send(RitmCommunity c, String? token) async {
    if (token == null || token == _sentToken || c.stage != RStage.ready) return;
    try {
      final sandbox = await _ch.invokeMethod<bool>('sandbox') ?? false;
      await c.api.putDevice(token, sandbox: sandbox);
      _sentToken = token;
    } catch (_) {}
  }
}
