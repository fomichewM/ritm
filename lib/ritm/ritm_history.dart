// «Ритм» FIX84 — история «Здоровья» сама, без ручных импортов.
//
// Требование автора 16.10: после разрешения «Здоровья» приложение САМО
// забирает историю (до 365 дней) и сразу засевает личную норму —
// Восстановление и Монитор здоровья считаются с первой ночи браслета, без
// «калибровки», если в «Здоровье» есть ≥ 14 ночей. Догрузка — при каждом
// открытии (не чаще раза в 30 мин, с перекрытием 3 дня).
//
// Что реально есть в «Здоровье» (проверено 16.10 по документации WHOOP и
// разбору интеграций): приложение WHOOP пишет пульс покоя (1/сутки), частоту
// дыхания (1/ночь), сон (сон/бодрствование), SpO₂, тренировки; ВСР — НЕ
// пишет (rMSSD ≠ SDNN). Apple Watch пишет пульс покоя, ВСР (SDNN), дыхание,
// сон стадиями. Поэтому: WHOOP → пульс покоя и дыхание нормы (та же шкала,
// что у браслета); Watch → пульс/ВСР через сверку шкал (ritm_seed.dart
// [recSeedHist]); сон любого источника → обычное время подъёма.
//
// Чистая часть — [mergeHealthPoints] (тест test/ritm_fix84_test.dart).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ritm_calc.dart' show isWatchSample, percentile;
import 'ritm_seed.dart';
import 'ritm_watch.dart' show RitmWatchReader;

/// Точка «Здоровья» в виде, удобном для чистой функции.
/// [kind]: 'rhr' | 'sdnn' | 'resp' | 'sleep'; [src]: 'whoop' | 'watch' | 'other'.
typedef HkPoint = ({String kind, double v, DateTime from, DateTime to, String src});

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Источник точки по приложению/устройству.
String hkSourceOf({required String sourceId, required String sourceName, String? deviceModel, String ownBundle = ''}) {
  final id = sourceId.toLowerCase(), n = sourceName.toLowerCase();
  if (id.contains('whoop') || n.contains('whoop')) return 'whoop';
  if (isWatchSample(sourceId: sourceId, sourceName: sourceName, deviceModel: deviceModel, ownBundle: ownBundle)) {
    return 'watch';
  }
  return 'other';
}

/// Дата ночи по концу сна: окончание до 15:00 — утро этого дня, позже — следующий.
String nightDayOf(DateTime end) {
  final e = end.toLocal();
  return e.hour < 15 ? _day(e) : _day(DateTime(e.year, e.month, e.day + 1));
}

/// Влить точки «Здоровья» в засев. Чистая функция: пересчитывает только
/// даты, которые есть в [pts] (догрузка с перекрытием не теряет старое).
RitmSeed mergeHealthPoints(RitmSeed cur, List<HkPoint> pts, {int? syncedAtMs}) {
  final whoopHk = {...cur.whoopHk};
  final watch = {...cur.watch};
  final sdnn = {...cur.watchSdnn};
  final sleep = {...cur.sleep};

  final rhr = <String, Map<String, double>>{'whoop': {}, 'watch': {}};
  final resp = <String, Map<String, List<double>>>{'whoop': {}, 'watch': {}};
  final sd = <String, List<double>>{};
  final asleep = <String, Map<String, List<(int, int)>>>{}; // src → day → интервалы
  for (final p in pts) {
    final at = p.to.toLocal();
    switch (p.kind) {
      case 'rhr':
        if (p.v >= 25 && p.v <= 140 && rhr.containsKey(p.src)) rhr[p.src]![_day(at)] = p.v;
      case 'sdnn':
        // Ночные замеры Watch (до 09:00) — ближе к ночной ВСР браслета.
        if (p.src == 'watch' && p.v > 0 && p.v < 400 && at.hour < 9) (sd[_day(at)] ??= []).add(p.v);
      case 'resp':
        if (p.v >= 5 && p.v <= 40 && resp.containsKey(p.src) && (at.hour < 12)) {
          (resp[p.src]![_day(at)] ??= []).add(p.v);
        }
      case 'sleep':
        final a = p.from.millisecondsSinceEpoch ~/ 1000, b = p.to.millisecondsSinceEpoch ~/ 1000;
        if (b > a && b - a < 16 * 3600) {
          ((asleep[p.src] ??= {})[nightDayOf(p.to)] ??= []).add((a, b));
        }
    }
  }
  SeedNight withV(SeedNight? n, {double? rhr, double? resp}) =>
      SeedNight(rhr: rhr ?? n?.rhr, hrv: n?.hrv, resp: resp ?? n?.resp);
  for (final e in rhr['whoop']!.entries) {
    whoopHk[e.key] = withV(whoopHk[e.key], rhr: e.value);
  }
  for (final e in resp['whoop']!.entries) {
    whoopHk[e.key] = withV(whoopHk[e.key], resp: percentile(e.value, .5));
  }
  for (final e in rhr['watch']!.entries) {
    watch[e.key] = withV(watch[e.key], rhr: e.value);
  }
  for (final e in resp['watch']!.entries) {
    watch[e.key] = withV(watch[e.key], resp: percentile(e.value, .5));
  }
  for (final e in sd.entries) {
    sdnn[e.key] = percentile(e.value, .5)!;
  }
  // Сон: по каждой ночи — самый длинный слитный кусок (разрывы ≤ 90 мин),
  // приоритет WHOOP > Watch > прочие.
  for (final src in const ['other', 'watch', 'whoop']) {
    for (final e in (asleep[src] ?? const <String, List<(int, int)>>{}).entries) {
      final xs = [...e.value]..sort((x, y) => x.$1.compareTo(y.$1));
      var best = (0, 0, 0);
      var on = xs.first.$1, off = xs.first.$2, tst = 0;
      var lastEnd = xs.first.$1;
      void close() {
        if (tst > best.$3) best = (on, off, tst);
      }

      for (final x in xs) {
        if (x.$1 - off > 90 * 60) {
          close();
          on = x.$1;
          off = x.$2;
          tst = 0;
          lastEnd = x.$1;
        }
        final s0 = x.$1 > lastEnd ? x.$1 : lastEnd;
        if (x.$2 > s0) tst += x.$2 - s0;
        if (x.$2 > lastEnd) lastEnd = x.$2;
        if (x.$2 > off) off = x.$2;
      }
      close();
      if (best.$3 >= 3 * 3600) sleep[e.key] = SeedSleep(best.$1, best.$2, best.$3 ~/ 60);
    }
  }
  return cur.copyWith(
    whoopHk: whoopHk,
    watch: watch,
    watchSdnn: sdnn,
    sleep: sleep,
    hkSyncedAt: syncedAtMs,
  );
}

/// Состояние забора истории — для онбординга и «Ещё → Данные».
class HkHistoryState {
  final bool running;
  final int nights;
  final String? error;
  final DateTime? at;
  const HkHistoryState({this.running = false, this.nights = 0, this.error, this.at});
}

class RitmHealthHistory {
  RitmHealthHistory._();

  static const int maxDays = 365;
  static const Duration throttle = Duration(minutes: 30);
  static final state = ValueNotifier<HkHistoryState>(const HkHistoryState());
  static Future<bool>? _running;

  /// Тесты подменяют чтение «Здоровья».
  static Future<List<HkPoint>> Function(DateTime from, DateTime to)? debugRead;

  /// Забрать историю (первый раз — 365 дней, дальше — с перекрытием 3 дня).
  /// true — засев изменился (главная пересчитывает кольца).
  static Future<bool> sync({bool force = false, DateTime? now}) =>
      _running ??= _sync(force: force, now: now).whenComplete(() => _running = null);

  static Future<bool> _sync({required bool force, DateTime? now}) async {
    final n = now ?? DateTime.now();
    final cur = await RitmSeed.load();
    if (!force && debugRead == null && !RitmWatchReader.asked) return false;
    final last = DateTime.fromMillisecondsSinceEpoch(cur.hkSyncedAt);
    if (!force && cur.hkSyncedAt > 0 && n.difference(last) < throttle) return false;
    final oldest = n.subtract(const Duration(days: maxDays));
    final from = cur.hkSyncedAt == 0 || last.isBefore(oldest) ? oldest : last.subtract(const Duration(days: 3));
    state.value = HkHistoryState(running: true, nights: cur.hkNights, at: state.value.at);
    try {
      final pts = <HkPoint>[];
      // Кусками по 60 дней — год сэмплов пульса покоя/ВСР не грузим разом.
      var a = from;
      while (a.isBefore(n)) {
        final b = a.add(const Duration(days: 60)).isBefore(n) ? a.add(const Duration(days: 60)) : n;
        pts.addAll(await (debugRead ?? _read)(a, b));
        a = b;
      }
      final next = mergeHealthPoints(cur, pts, syncedAtMs: n.millisecondsSinceEpoch);
      await RitmSeed.save(next);
      state.value = HkHistoryState(nights: next.hkNights, at: n);
      return pts.isNotEmpty;
    } catch (e) {
      debugPrint('[ritm] health history: $e');
      state.value = HkHistoryState(nights: cur.hkNights, error: '$e', at: state.value.at);
      return false;
    }
  }

  static const _types = [
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.HEART_RATE_VARIABILITY_SDNN,
    HealthDataType.RESPIRATORY_RATE,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_REM,
  ];

  static String? _own;

  static Future<List<HkPoint>> _read(DateTime from, DateTime to) async {
    _own ??= await PackageInfo.fromPlatform().then((p) => p.packageName).catchError((_) => '');
    final pts = await Health().getHealthDataFromTypes(types: _types, startTime: from, endTime: to);
    final out = <HkPoint>[];
    for (final p in pts) {
      // Свои записи (сон «Ритма» в «Здоровье») — не история. В DEBUG на
      // симуляторе засев «Здоровья» пишет само приложение с устройством Watch.
      final own = p.sourceId == _own;
      if (own && !(kDebugMode && (p.deviceModel ?? '').toLowerCase().contains('watch'))) continue;
      final src = own
          ? 'watch'
          : hkSourceOf(sourceId: p.sourceId, sourceName: p.sourceName, deviceModel: p.deviceModel);
      final kind = switch (p.type) {
        HealthDataType.RESTING_HEART_RATE => 'rhr',
        HealthDataType.HEART_RATE_VARIABILITY_SDNN => 'sdnn',
        HealthDataType.RESPIRATORY_RATE => 'resp',
        _ => 'sleep',
      };
      final v = p.value;
      final x = v is NumericHealthValue ? v.numericValue.toDouble() : 0.0;
      out.add((kind: kind, v: x, from: p.dateFrom, to: p.dateTo, src: src));
    }
    return out;
  }
}
