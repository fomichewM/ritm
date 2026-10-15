// «Ритм» — чтение Apple Watch через «Здоровье» для сверки с браслетом
// (ТЗ v2 §8.1, §10.9). B1′: через плагин `health`; B3: основной путь — Swift-канал
// `ritm/health` (ritm_watch_store.dart), этот читатель — запасной.

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../state/prefs.dart';
import 'ritm_calc.dart';
import 'ritm_hk.dart' show WatchData;
import 'ritm_seed.dart';

/// Что Watch записал за последнюю ночь.
class WatchNight {
  /// Пульс покоя Watch за ночь/утро (последнее значение).
  final int? rhr;

  /// Минуты сна Watch за ночь (сумма стадий, без бодрствования).
  final int? sleepMin;

  /// Самая свежая запись Watch из прочитанных.
  final DateTime? lastSample;

  /// Сколько записей Watch нашлось (для статуса доступа).
  final int samples;
  const WatchNight({
    this.rhr,
    this.sleepMin,
    this.lastSample,
    this.samples = 0,
  });

  bool get any => samples > 0;

  /// Ночь Watch из данных Swift-канала.
  factory WatchNight.of(WatchData w) => WatchNight(
    rhr: w.rhr,
    sleepMin: w.sleepMin,
    lastSample: w.lastSample,
    samples: w.samples,
  );
}

class RitmWatchReader {
  RitmWatchReader({Health? health}) : _h = health ?? Health();
  final Health _h;

  static const _asked = 'ritm.health.read_asked';
  static const readRhrKey = 'ritm.read.rhr';
  static const readSleepKey = 'ritm.read.sleep';

  /// Типы, которые «Ритм» читает для сверки (B1′).
  static const types = [
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_REM,
    HealthDataType.HEART_RATE,
    HealthDataType.WORKOUT,
    HealthDataType.STEPS,
    HealthDataType.HEART_RATE_VARIABILITY_SDNN,
  ];

  static bool get asked => Prefs.getBool(_asked, false);
  static bool get readRhr => Prefs.getBool(readRhrKey, true);
  static bool get readSleep => Prefs.getBool(readSleepKey, true);

  /// Запросить доступ на чтение (системное окно iOS). iOS не сообщает,
  /// выдано ли чтение, поэтому успех проверяем по найденным записям.
  Future<bool> requestAccess() async {
    try {
      final ok = await _h.requestAuthorization(
        types,
        permissions: [for (final _ in types) HealthDataAccess.READ],
      );
      Prefs.setBool(_asked, true);
      return ok;
    } catch (e) {
      debugPrint('[ritm] health read request: $e');
      return false;
    }
  }

  /// Ночь: с 18:00 вчера до 12:00 сегодня (или до сейчас).
  Future<WatchNight> lastNight({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final from = DateTime(n.year, n.month, n.day - 1, 18);
    final to = n;
    String own = '';
    try {
      own = (await PackageInfo.fromPlatform()).packageName;
    } catch (_) {}
    List<HealthDataPoint> pts;
    try {
      pts = await _h.getHealthDataFromTypes(
        types: [
          if (readRhr) HealthDataType.RESTING_HEART_RATE,
          if (readSleep) ...[
            HealthDataType.SLEEP_ASLEEP,
            HealthDataType.SLEEP_LIGHT,
            HealthDataType.SLEEP_DEEP,
            HealthDataType.SLEEP_REM,
          ],
        ],
        startTime: from,
        endTime: to,
      );
      // Свежесть Watch — по пульсу за последние 6 часов (лёгкий запрос).
      pts = [
        ...pts,
        ...await _h.getHealthDataFromTypes(
          types: const [HealthDataType.HEART_RATE],
          startTime: n.subtract(const Duration(hours: 6)),
          endTime: to,
        ),
      ];
    } catch (e) {
      debugPrint('[ritm] health read: $e');
      return const WatchNight();
    }
    final watch = [
      for (final p in pts)
        if (isWatchSample(
          sourceId: p.sourceId,
          sourceName: p.sourceName,
          deviceModel: p.deviceModel,
          ownBundle: own,
        ))
          p,
    ];
    if (watch.isEmpty) return const WatchNight();
    int? rhr;
    DateTime? rhrAt;
    final asleep = <({DateTime from, DateTime to})>[];
    DateTime? last;
    for (final p in watch) {
      if (last == null || p.dateTo.isAfter(last)) last = p.dateTo;
      switch (p.type) {
        case HealthDataType.RESTING_HEART_RATE:
          final v = p.value;
          if (v is NumericHealthValue &&
              (rhrAt == null || p.dateTo.isAfter(rhrAt))) {
            rhr = v.numericValue.round();
            rhrAt = p.dateTo;
          }
        case HealthDataType.SLEEP_ASLEEP ||
            HealthDataType.SLEEP_LIGHT ||
            HealthDataType.SLEEP_DEEP ||
            HealthDataType.SLEEP_REM:
          asleep.add((from: p.dateFrom, to: p.dateTo));
        default:
          break;
      }
    }
    final mins = watchSleepMinutes(asleep);
    return WatchNight(
      rhr: rhr,
      sleepMin: mins > 0 ? mins : null,
      lastSample: last,
      samples: watch.length,
    );
  }
}


/// Засев нормы из «Здоровья» (B2): пульс покоя и ВСР (SDNN) от Apple Watch
/// за [days] дней, по датам. SDNN хранится сырым — в шкалу браслета его
/// переводит [RitmSeed.values] по ночам, где есть оба числа.
extension RitmWatchSeed on RitmWatchReader {
  Future<RitmSeed> seedFromHealth(RitmSeed cur, {int days = 60, DateTime? now}) async {
    final n = now ?? DateTime.now();
    String own = '';
    try {
      own = (await PackageInfo.fromPlatform()).packageName;
    } catch (_) {}
    List<HealthDataPoint> pts;
    try {
      pts = await Health().getHealthDataFromTypes(
        types: const [
          HealthDataType.RESTING_HEART_RATE,
          HealthDataType.HEART_RATE_VARIABILITY_SDNN,
        ],
        startTime: n.subtract(Duration(days: days)),
        endTime: n,
      );
    } catch (e) {
      debugPrint('[ritm] health seed: $e');
      return cur;
    }
    String day(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final rhr = <String, double>{};
    final sdnn = <String, List<double>>{};
    for (final p in pts) {
      if (!isWatchSample(
        sourceId: p.sourceId,
        sourceName: p.sourceName,
        deviceModel: p.deviceModel,
        ownBundle: own,
      )) {
        continue;
      }
      final v = p.value;
      if (v is! NumericHealthValue) continue;
      final x = v.numericValue.toDouble();
      final at = p.dateTo.toLocal();
      if (p.type == HealthDataType.RESTING_HEART_RATE && x >= 25 && x <= 140) {
        rhr[day(at)] = x;
      } else if (p.type == HealthDataType.HEART_RATE_VARIABILITY_SDNN &&
          x > 0 &&
          x < 400 &&
          at.hour < 9) {
        // Ночные замеры (до 09:00) — ближе к ночной ВСР браслета.
        (sdnn[day(at)] ??= []).add(x);
      }
    }
    return cur.copyWith(
      watch: {for (final e in rhr.entries) e.key: SeedNight(rhr: e.value)},
      watchSdnn: {
        for (final e in sdnn.entries) e.key: percentile(e.value, .5)!,
      },
    );
  }
}
