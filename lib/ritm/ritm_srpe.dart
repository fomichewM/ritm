// «Ритм» K7 — силовые «как тяжело 1–10» (sRPE, Foster).
//
// Пульс плохо видит силовую: сердце отдыхает между подходами, а мышцы
// работают. WHOOP закрывает это закрытой «мышечной нагрузкой» (Muscular
// Load); у нас — честный ввод «как тяжело было» после силовой.
//
// Нагрузка силовой = max(пульсовая часть; q · RPE · минуты). В Нагрузку дня
// добавляется только РАЗНИЦА сверх пульса — без двойного счёта.
//
// Шкала q подобрана по силовым тренировкам WHOOP из калибровочного экспорта с мышечной нагрузкой
// (Weightlifting/Powerlifting, 02–08.2026; build/whoop_srpe_calibrate.py,
// CALIBRATION.md §2б) при ДОПУЩЕНИИ «типичная силовая = 6 из 10» — оценок
// RPE в экспорте WHOOP нет. Проверочная треть: MAE Нагрузки силовой
// 2,56 → 0,61.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../state/prefs.dart';
import 'ritm_rings.dart' show HrMinute, RingTheta, kRingTheta, strainWeight;

/// Весовые минуты Нагрузки на единицу sRPE (RPE × минуты).
const double kSrpeQ = 0.276;

class SrpeSession {
  final int from, to, rpe;
  const SrpeSession(this.from, this.to, this.rpe);
  int get minutes => ((to - from) / 60).round();
}

/// Слово к оценке (шкала Борга CR-10, по-простому).
String rpeWord(int r) => switch (r) {
  <= 2 => 'очень легко',
  <= 4 => 'умеренно',
  <= 6 => 'тяжело',
  <= 8 => 'очень тяжело',
  _ => 'на пределе',
};

/// Пульсовая нагрузка внутри окна [from; to) — весовые минуты.
double hrLoadIn(List<HrMinute> xs, int from, int to, {required double rhr, required double hrMax, RingTheta theta = kRingTheta}) {
  final hrr = hrMax - rhr < 20 ? 20.0 : hrMax - rhr;
  var l = 0.0;
  for (final m in xs) {
    if (m.t < from || m.t >= to) continue;
    l += strainWeight((m.hr - rhr) / hrr, theta);
  }
  return l;
}

/// Добавка к нагрузке дня: Σ max(0, q·RPE·мин − пульсовая часть тренировки).
double srpeExtra(
  List<HrMinute> xs,
  List<SrpeSession> ss, {
  required double rhr,
  required double hrMax,
  RingTheta theta = kRingTheta,
}) {
  var e = 0.0;
  for (final s in ss) {
    final want = kSrpeQ * s.rpe * s.minutes;
    final have = hrLoadIn(xs, s.from, s.to, rhr: rhr, hrMax: hrMax, theta: theta);
    if (want > have) e += want - have;
  }
  return e;
}

/// Оценки «как тяжело» по силовым (локально, ключ — начало тренировки).
class RitmRpe {
  static const _k = 'ritm.rpe.v1';
  static final changed = ValueNotifier<int>(0);

  static Map<String, List<int>> _all() {
    try {
      final m = jsonDecode(Prefs.getString(_k, '{}')) as Map;
      return {
        for (final e in m.entries)
          if (e.value is List && (e.value as List).length == 2)
            e.key.toString(): [for (final x in e.value as List) (x as num).toInt()],
      };
    } catch (_) {
      return {};
    }
  }

  /// Оценка тренировки, начавшейся в [fromSec] (±2 мин), или null.
  static int? of(int fromSec) {
    for (final e in _all().entries) {
      final s = int.tryParse(e.key);
      if (s != null && (s - fromSec).abs() <= 120) return e.value[1];
    }
    return null;
  }

  static void set(int fromSec, int toSec, int? rpe) {
    final m = _all()..removeWhere((k, _) => ((int.tryParse(k) ?? 0) - fromSec).abs() <= 120);
    if (rpe != null) m['$fromSec'] = [toSec, rpe.clamp(1, 10)];
    // Храним полгода — дальше кольца не пересчитываются.
    final old = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 183 * 86400;
    m.removeWhere((k, _) => (int.tryParse(k) ?? 0) < old);
    Prefs.setString(_k, jsonEncode(m));
    changed.value++;
  }

  /// Оценённые силовые, начавшиеся в окне [from; to).
  static List<SrpeSession> range(int from, int to) => [
    for (final e in _all().entries)
      if ((int.tryParse(e.key) ?? -1) >= from && (int.tryParse(e.key) ?? -1) < to)
        SrpeSession(int.parse(e.key), e.value[0], e.value[1]),
  ];
}
