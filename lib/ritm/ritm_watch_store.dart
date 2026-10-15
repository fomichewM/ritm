// «Ритм» — клиент Swift-канала `ritm/health` (RitmHealthKit.swift) и общий
// кэш данных Apple Watch для экранов (сборка B3).
//
// Один снимок на всё приложение: «Здоровье», «Мой день», «Мои показатели»,
// «Источники и сверка», экран тренировки слушают [RitmWatchStore.data].
// Демо (DEBUG + RITM_DEMO) берёт данные Watch ТОЖЕ из канала: перед первым
// чтением Swift засевает «Здоровье» симулятора тестовыми записями Watch.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../state/prefs.dart';
import 'ritm_demo.dart' show kRitmDemo, ritmDemoNow;
import 'ritm_hk.dart';

/// Типы чтения, которые можно выключить в «Источниках» (ключ → подпись).
const kRitmReadKinds = <String, String>{
  'workouts': 'Тренировки',
  'vo2': 'VO₂max',
  'spo2': 'SpO₂ ночью',
  'temp': 'Температура запястья',
  'ecg': 'ЭКГ Watch',
  'steps': 'Шаги',
  'sleep': 'Сон',
  'rhr': 'Пульс покоя',
};

/// В тестах канал фоновой доставки не трогаем.
bool kRitmDemoBg = const bool.fromEnvironment('FLUTTER_TEST');

class RitmHealthKitChannel {
  static const _ch = MethodChannel('ritm/health');

  /// Последнее событие фоновой доставки (тип HealthKit, время) — D5/D6.
  static final changed = ValueNotifier<(String, DateTime)?>(null);
  static bool _listening = false;

  /// B4½ D5: включить фоновую доставку «Здоровья» и слушать `changed`:
  /// новая запись (сон, тренировка, пульс покоя, ВСР, SpO₂, VO₂max, ЭКГ,
  /// шаги раз в час) → перечитать снимок Watch; главная пересчитает кольца.
  static Future<bool> startBackgroundDelivery() async {
    if (!_listening) {
      _listening = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'changed') {
          final t = (call.arguments is Map ? (call.arguments as Map)['type'] : null)?.toString() ?? '';
          await RitmWatchStore.load(force: true);
          changed.value = (t, DateTime.now());
          return true;
        }
        return null;
      });
    }
    try {
      return await _ch.invokeMethod<bool>('startBackgroundDelivery') ?? false;
    } catch (e) {
      debugPrint('[ritm] hk background: $e');
      return false;
    }
  }

  static Future<bool> requestAuthorization() async {
    try {
      return await _ch.invokeMethod<bool>('requestAuthorization') ?? false;
    } catch (e) {
      debugPrint('[ritm] hk auth: $e');
      return false;
    }
  }

  /// Дата рождения и пол из «Здоровья» (HKCharacteristic, B4).
  /// null — «Здоровье» недоступно или пользователь их не указал/не дал.
  static Future<({DateTime? birth, String? sex})?> characteristics() async {
    try {
      final m = await _ch.invokeMethod<Map>('characteristics');
      if (m == null) return null;
      final b = DateTime.tryParse('${m['dob'] ?? ''}');
      final sx = m['sex']?.toString();
      return (
        birth: b == null ? null : DateTime(b.year, b.month, b.day),
        sex: sx == null || sx.isEmpty ? null : sx,
      );
    } catch (e) {
      debugPrint('[ritm] hk characteristics: $e');
      return null;
    }
  }

  static Future<int> readTypeCount() async {
    try {
      return (await _ch.invokeMethod<List>('readTypes'))?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<Object?> snapshotRaw({DateTime? now}) async {
    try {
      return await _ch.invokeMethod<Object?>('snapshot', {
        'nowMs': (now ?? DateTime.now()).millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('[ritm] hk snapshot: $e');
      return null;
    }
  }

  /// Тренировки Watch в окне — для правила записи §10.11.
  static Future<List<HkWorkout>> watchWorkoutsIn(
    DateTime from,
    DateTime to, {
    String own = '',
  }) async {
    try {
      final raw = await _ch.invokeMethod<List>('workoutsIn', {
        'fromMs': from.millisecondsSinceEpoch,
        'toMs': to.millisecondsSinceEpoch,
      });
      return [
        for (final w in HkWorkout.list(raw))
          if (w.src.isWatch(own: own, allowSeed: kDebugMode)) w,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// DEBUG: засеять «Здоровье» симулятора тестовыми записями Watch.
  static Future<Map?> debugSeed({DateTime? now}) async {
    if (!kDebugMode) return null;
    try {
      return await _ch.invokeMethod<Map>('debugSeed', {
        'nowMs': (now ?? DateTime.now()).millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('[ritm] hk seed: $e');
      return null;
    }
  }
}

class RitmWatchStore {
  RitmWatchStore._();

  static final data = ValueNotifier<WatchData?>(null);
  static HkSnapshot? lastRaw;
  static Map? seedResult;
  static String _own = '';
  static Future<void>? _loading;
  static DateTime? _loadedAt;

  static const _askedKey = 'ritm.hk.asked';
  static const _presentKey = 'ritm.watch.present';

  static bool get asked => Prefs.getBool(_askedKey, false);

  /// Watch встречался в «Здоровье» (для правила калорий §10.11).
  static bool get watchPresent => Prefs.getBool(_presentKey, false);

  static String readKey(String k) => 'ritm.read.hk.$k';
  static bool reads(String k) => Prefs.getBool(readKey(k), true);
  static Set<String> get off => {
    for (final k in kRitmReadKinds.keys)
      if (!reads(k)) k,
  };

  static Future<void> setRead(String k, bool on) async {
    Prefs.setBool(readKey(k), on);
    await load(force: true);
  }

  static Future<bool> requestAccess() async {
    final ok = await RitmHealthKitChannel.requestAuthorization();
    Prefs.setBool(_askedKey, true);
    // После выдачи доступа — заново: наблюдатели, поставленные до него, iOS остановила.
    unawaited(RitmHealthKitChannel.startBackgroundDelivery());
    await load(force: true);
    return ok;
  }

  /// Загрузить снимок (не чаще раза в минуту, если не [force]).
  static Future<void> load({bool force = false}) {
    if (asked && !RitmHealthKitChannel._listening && !kRitmDemoBg) {
      unawaited(RitmHealthKitChannel.startBackgroundDelivery());
    }
    final at = _loadedAt;
    if (!force &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 1)) {
      return Future.value();
    }
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  static Future<void> _load() async {
    if (_own.isEmpty) {
      try {
        _own = (await PackageInfo.fromPlatform()).packageName;
      } catch (_) {}
    }
    final now = ritmDemoNow() ?? DateTime.now();
    if (kRitmDemo) {
      // Демо: данные Watch — только через канал. Засеваем «Здоровье»
      // симулятора (один раз в день) и дальше читаем как на телефоне.
      if (seedResult?['ok'] != true) {
        seedResult = await RitmHealthKitChannel.debugSeed(now: now);
        debugPrint('[ritm] hk seed: $seedResult');
      }
      Prefs.setBool(_askedKey, true);
    } else if (!asked) {
      return;
    }
    final raw = await RitmHealthKitChannel.snapshotRaw(now: now);
    if (raw == null) return;
    final snap = HkSnapshot.parse(raw, now: now);
    lastRaw = snap;
    final w = WatchData.from(
      snap,
      own: _own,
      allowSeed: kDebugMode,
      off: off,
    );
    if (w.any) Prefs.setBool(_presentKey, true);
    _loadedAt = DateTime.now();
    data.value = w;
  }
}
