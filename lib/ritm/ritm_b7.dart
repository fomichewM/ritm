// «Ритм» B7 — «Друзья с 4.0 и Garmin» (ТЗ v3 §B7, MULTIDEVICE §4.3 A+B):
//   • запись трансляции пульса (BLE HRS: Garmin «Трансляция пульса» или
//     нагрудный датчик) в `external_hr` → Нагрузка дня (склейка D7);
//   • D9 ручной VO₂max (подпись «введено») — для биовозраста без Watch;
//   • K17 «Дыхание ночью» (CVHR) — за переключателем, по умолчанию выкл.,
//     текст по юридическому разбору строителя (build/B6_legal.md §5, не заключение юриста): «ночь непохожа на ваши», не диагноз.
// Без I/O в чистых функциях — их проверяет test/ritm_b7_test.dart.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ble/hrs_link.dart';
import '../data/db.dart' show LocalDb;
import '../state/prefs.dart';
import 'ritm_rings.dart' show TV;
import 'ritm_rings_store.dart' show RitmRingsStore;

// ───────────────────────── трансляция пульса ─────────────────────────

/// Пишет каждое показание датчика пульса (HrsLink) в `external_hr` пачками
/// раз в 30 с; отдаёт ряд дня для Нагрузки. Запускается один раз при старте.
class RitmHrsRecorder {
  static bool _on = false;
  static final List<Map<String, Object?>> _buf = [];
  static Timer? _flush;
  static int? _lastSec;

  /// Последнее показание (уд/мин, секунда) — для карточки «Датчик пульса».
  static final live = ValueNotifier<(int, int)?>(null);

  static void start() {
    if (_on) return;
    _on = true;
    RitmRingsStore.broadcastSource = dayRange;
    HrsLink.instance.reading.addListener(_onReading);
  }

  static void _onReading() {
    final r = HrsLink.instance.reading.value;
    final bpm = r?.bpm;
    if (r == null || bpm == null || bpm < 30 || bpm > 230) return;
    final sec = r.atSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (sec == _lastSec) return;
    _lastSec = sec;
    live.value = (bpm, sec);
    _buf.add({'ts': sec, 'source': 'hrs:${HrsLink.instance.deviceId ?? 'sensor'}', 'hr': bpm});
    if (_buf.length >= 120) {
      unawaited(flush());
    } else {
      // Таймер — только когда есть что писать (в тестах и без датчика его нет).
      _flush ??= Timer(const Duration(seconds: 30), () {
        _flush = null;
        unawaited(flush());
      });
    }
  }

  static Future<void> flush() async {
    if (_buf.isEmpty) return;
    final rows = [..._buf];
    _buf.clear();
    try {
      await LocalDb.appendExternalHr(rows);
    } catch (e) {
      debugPrint('[ritm] hrs flush: $e');
    }
  }

  static Future<List<TV>> dayRange(int fromSec, int toSec) async {
    await flush();
    final rows = await LocalDb.externalHrRange(fromSec, toSec);
    return [
      for (final r in rows)
        if (r['ts'] is num && r['hr'] is num) TV((r['ts'] as num).toInt(), (r['hr'] as num).toDouble()),
    ];
  }

  /// Минут с трансляцией за окно (для карточки «сегодня … мин»).
  static int minutes(List<TV> xs) => {for (final p in xs) p.t ~/ 60}.length;

  @visibleForTesting
  static void debugStop() {
    _flush?.cancel();
    _on = false;
    HrsLink.instance.reading.removeListener(_onReading);
  }
}

// ───────────────────────── D9: ручной VO₂max ─────────────────────────

class RitmVo2Manual {
  static const _kV = 'ritm.vo2.manual';
  static const _kAt = 'ritm.vo2.manual_at';
  static final changed = ValueNotifier<int>(0);

  /// Значение и дата ввода (null — не вводили).
  static (double, DateTime)? get value {
    final v = double.tryParse(Prefs.getString(_kV, ''));
    final at = DateTime.tryParse(Prefs.getString(_kAt, ''));
    if (v == null || at == null) return null;
    return (v, at);
  }

  /// Проверка ввода: 15–90 мл/кг/мин (взрослые; иначе — опечатка).
  static String? validate(String raw) {
    final v = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (v == null) return 'Введите число, например 44 или 44,5';
    if (v < 15 || v > 90) return 'VO₂max взрослого — от 15 до 90 мл/кг/мин';
    return null;
  }

  static void set(double v, {DateTime? at}) {
    Prefs.setString(_kV, v.toStringAsFixed(1));
    Prefs.setString(_kAt, (at ?? DateTime.now()).toIso8601String());
    changed.value++;
  }

  static void clear() {
    Prefs.setString(_kV, '');
    Prefs.setString(_kAt, '');
    changed.value++;
  }
}

// ───────────────────────── K17: дыхание ночью (CVHR) ─────────────────────────

/// Текст по юридическому разбору строителя (B6_legal.md §5; юрист-человек не смотрел). Нельзя: «апноэ»,
/// «нарушение», «риск заболевания», проценты вероятности.
const kRitmCvhrText =
    'Ночью ритм дыхания и пульса заметно отличался от ваших обычных ночей. Это не диагноз. '
    'Если это повторяется и вы чувствуете дневную сонливость или храп — обсудите это с врачом.';

class RitmCvhrPrefs {
  static const _k = 'ritm.cvhr.on';
  static bool get on => Prefs.getBool(_k, false);
  static void set(bool v) => Prefs.setBool(_k, v);
}

/// Ночь: циклы «замедление–ускорение» пульса в час (CVHR) и часы анализа.
class CvhrNightRow {
  final String day;
  final double perHour;
  final double hours;
  const CvhrNightRow(this.day, this.perHour, this.hours);
}

enum CvhrState { learning, usual, unlike }

class CvhrVerdict {
  final CvhrState state;

  /// Ночей в норме (≥ 4 ч анализа) — для «учится: N из 14».
  final int nights;

  /// Ваш обычный верх (75-й перцентиль) и две последние ночи.
  final double? usualHigh;
  final List<double> last;
  const CvhrVerdict(this.state, {this.nights = 0, this.usualHigh, this.last = const []});
}

/// Минимум ночей для нормы и порог «непохожести».
const int kCvhrMinNights = 14;

/// «Ночь непохожа на ваши»: ДВЕ последние ночи подряд (соседние даты, обе
/// ≥ 4 ч анализа) выше вашего обычного верха — p75 предыдущих (до 30) ночей
/// ×1,25 и не меньше чем на 2 цикла/ч. Сравнение только с собой — без норм
/// и без диагнозов. [rows] — от старых к новым.
CvhrVerdict cvhrVerdict(List<CvhrNightRow> rows) {
  final ok = [for (final r in rows) if (r.hours >= 4 && r.perHour.isFinite) r];
  if (ok.length < kCvhrMinNights + 2) return CvhrVerdict(CvhrState.learning, nights: math.max(0, ok.length - 2));
  final last2 = ok.sublist(ok.length - 2);
  final base = ok.sublist(math.max(0, ok.length - 32), ok.length - 2).map((r) => r.perHour).toList()..sort();
  final p75 = _pct(base, .75);
  final high = math.max(p75 * 1.25, p75 + 2);
  final d1 = DateTime.tryParse(last2[0].day), d2 = DateTime.tryParse(last2[1].day);
  final adjacent = d1 != null && d2 != null && d2.difference(d1).inDays == 1;
  final unlike = adjacent && last2.every((r) => r.perHour > high);
  return CvhrVerdict(
    unlike ? CvhrState.unlike : CvhrState.usual,
    nights: base.length,
    usualHigh: p75,
    last: [for (final r in last2) r.perHour],
  );
}

double _pct(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  final i = (sorted.length - 1) * q;
  final lo = i.floor(), hi = i.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}

/// Ряд CVHR за [days] дней из пакета дня (`getDayLungs` → `cvhr`).
Future<List<CvhrNightRow>> loadCvhrRows(dynamic repo, List<String> days) async {
  final out = <CvhrNightRow>[];
  for (final d in days) {
    try {
      final m = (await repo.getDayLungs(d) as Map)['cvhr'];
      if (m is! Map) continue;
      final ph = (m['cvhr_per_hour'] as num?)?.toDouble();
      final h = (m['analyzed_hours'] as num?)?.toDouble();
      if (ph == null || h == null) continue;
      out.add(CvhrNightRow(d, ph, h));
    } catch (_) {}
  }
  return out;
}
