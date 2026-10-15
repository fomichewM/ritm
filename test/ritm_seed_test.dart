// «Ритм» B2: засев нормы Монитора здоровья — CSV WHOOP и «Здоровье»
// (ТЗ v2 §14 B2, §10.4: «коридоры совпадают с перцентилями из экспорта CSV,
// тест на фикстуре 30 ночей»), CUSUM пульса покоя.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_calc.dart';
import 'package:openstrap_edge/ritm/ritm_health.dart';
import 'package:openstrap_edge/ritm/ritm_seed.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart' show HealthData;

/// Фикстура: 30 ночей экспорта WHOOP «physiological_cycles.csv» (колонки —
/// как в реальном экспорте, часть полей в кавычках).
String _fixture({DateTime? end}) {
  final e = end ?? DateTime(2026, 10, 14);
  final b = StringBuffer(
    'Cycle start time,Cycle end time,Cycle timezone,Recovery score %,'
    'Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),'
    'Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),'
    'Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm)\n',
  );
  String two(int v) => v.toString().padLeft(2, '0');
  for (var i = 29; i >= 0; i--) {
    final wake = DateTime(e.year, e.month, e.day - i, 7, 10);
    final onset = wake.subtract(const Duration(hours: 8, minutes: 5));
    String ts(DateTime d) =>
        '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:00';
    final rhr = 50 + (i * 7 % 9); // 50…58
    final hrv = 40 + (i * 5 % 17); // 40…56
    final resp = 13.5 + (i % 5) * .2;
    b.writeln(
      '${ts(onset)},${ts(wake)},"UTC+05:00",${60 + i % 30},$rhr,$hrv,33.9,96.1,'
      '"${(8 + i % 9).toStringAsFixed(1)}",2100,171,64,${ts(onset)},${ts(wake)},88,'
      '${resp.toStringAsFixed(1)}',
    );
  }
  return b.toString();
}

/// Перцентиль «как в таблице» — независимая реализация (линейная интерполяция
/// по сортированному ряду, как PERCENTILE.INC в Excel/Numbers).
double _pinc(List<double> xs, double p) {
  final s = [...xs]..sort();
  final h = (s.length - 1) * p;
  final lo = h.floor();
  return s[lo] + (h - lo) * (s[(lo + 1).clamp(0, s.length - 1)] - s[lo]);
}

void main() {
  test('CSV WHOOP: 30 ночей по дате пробуждения, кавычки, колонки по названию', () {
    final n = parseWhoopCycles(_fixture());
    expect(n.length, 30);
    expect(n.keys.last, '2026-10-14');
    expect(n['2026-10-14']!.rhr, 50);
    expect(n['2026-10-14']!.hrv, 40);
    expect(n['2026-10-14']!.resp, closeTo(13.5, 1e-9));
    expect(parseWhoopCycles('a,b\n1,2'), isEmpty);
  });

  test('коридоры по фикстуре 30 ночей совпадают с перцентилями экспорта', () {
    final n = parseWhoopCycles(_fixture());
    final days = n.keys.toList()..sort();
    final rhr = [for (final d in days) n[d]!.rhr!];
    final hrv = [for (final d in days) n[d]!.hrv!];
    final resp = [for (final d in days) n[d]!.resp!];
    // Последняя ночь — проверяемая, история — 29 предыдущих.
    final r = monitorRow(MonKind.rhr, history: rhr.sublist(0, 29), last: rhr.last);
    final h = monitorRow(MonKind.hrv, history: hrv.sublist(0, 29), last: hrv.last);
    final p = monitorRow(MonKind.resp, history: resp.sublist(0, 29), last: resp.last);
    expect(r.note, 'норма до ${_pinc(rhr.sublist(0, 29), .9).round()}');
    expect(h.note, 'норма от ${_pinc(hrv.sublist(0, 29), .1).round()}');
    expect(
      p.note,
      'норма до ${(_pinc(resp.sublist(0, 29), .5) + 1.5).toStringAsFixed(1).replaceAll('.', ',')}',
    );
    expect(percentile(rhr, .9), closeTo(_pinc(rhr, .9), 1e-9));
  });

  test('SDNN Watch → шкала rMSSD только после сверки по ≥ 3 ночам', () {
    final band = {'a': 50.0, 'b': 60.0, 'c': 40.0};
    expect(sdnnToRmssd(band, {'a': 25.0, 'b': 30.0}), isNull);
    expect(sdnnToRmssd(band, {'a': 25.0, 'b': 30.0, 'c': 20.0}), closeTo(2, 1e-9));
    final seed = RitmSeed(watchSdnn: {'a': 25, 'b': 30, 'c': 20, 'd': 30});
    expect(seed.values('hrv', bandRmssd: band)['d'], closeTo(60, 1e-9));
    expect(const RitmSeed(watchSdnn: {'d': 30}).values('hrv', bandRmssd: band), isEmpty);
  });

  test('слияние: ночь браслета важнее засева, засев закрывает пропуски', () {
    final m = mergeSeed([null, 52, null], ['d1', 'd2', 'd3'], {'d1': 60, 'd2': 70});
    expect(m.series, [60, 52, null]);
    expect(m.seeded, 1);
    // Приоритет внутри засева: WHOOP > Watch.
    final s = RitmSeed(
      whoop: {'x': const SeedNight(rhr: 50)},
      watch: {'x': const SeedNight(rhr: 58), 'y': const SeedNight(rhr: 57)},
    );
    expect(s.values('rhr'), {'x': 50, 'y': 57});
  });

  test('Монитор здоровья: 3 своих ночи + 27 ночей WHOOP → коридор, не калибровка', () {
    final now = DateTime.now();
    final pts = [
      for (var i = 2; i >= 0; i--)
        (
          t: DateTime(now.year, now.month, now.day - i, 12).millisecondsSinceEpoch ~/ 1000,
          v: 52.0,
        ),
    ];
    final d = HealthData(
      today: {
        'daily': {'resting_hr': {'value': 52, 'confidence': .9, 'tier': 'HIGH'}},
        'hrv': {'rmssd': 48, 'confidence': .9, 'tier': 'HIGH'},
      },
      charts: {'resting_hr': pts, 'hrv': [for (final p in pts) (t: p.t, v: 48.0)]},
      daysWithData: 3,
    );
    final bare = RitmHealthModel.from(d, now: now);
    expect(bare.rows.first.status, MonStatus.calibrating);
    final seeded = RitmHealthModel.from(
      d,
      now: now,
      seed: RitmSeed(whoop: parseWhoopCycles(_fixture(end: now.subtract(const Duration(days: 3))))),
    );
    final rhr = seeded.rows.first;
    expect(rhr.measured, isTrue, reason: rhr.note);
    expect(rhr.note, contains('с историей WHOOP'));
    expect(seeded.summary.text, startsWith('В норме'));
  });

  test('CUSUM: медленный рост пульса покоя 6 ночей подряд → красный', () {
    final hist = [for (var i = 0; i < 20; i++) 50.0 + (i % 3)];
    expect(cusumHigh(hist, [51, 50, 52, 51]), isFalse);
    expect(cusumHigh(hist, [53, 54, 54, 55, 55, 56]), isTrue);
    final row = monitorRow(
      MonKind.rhr,
      history: hist,
      last: 53,
      prev: 53,
      recent: [53, 53, 54, 53, 54, 53],
    );
    expect(row.status, MonStatus.alert);
    expect(cusumHigh(hist.sublist(0, 5), [60, 60]), isFalse); // мало истории
  });
}
