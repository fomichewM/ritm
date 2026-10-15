// «Ритм» B4¾: движок сна = Python калибровки (20 последних ночей экспорта
// WHOOP Михаила), балл стресса, отбой по цели, пробуждения ≥ 5 мин.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_sleep.dart';

int _e(String s) => DateTime.parse(s).millisecondsSinceEpoch ~/ 1000;

void main() {
  // Личные данные WHOOP (выгрузка Михаила) в публичный репозиторий не входят —
  // без них сверка Dart = Python пропускается.
  const sleepFx = 'test/fixtures/ritm_compare/sleep_whoop_inputs.json';
  final private = File(sleepFx).existsSync() ? null : 'личная выгрузка WHOOP не публикуется';
  final fx = private == null ? jsonDecode(File(sleepFx).readAsStringSync()) as Map : const {'windows': [], 'nights': []};
  final windows = <SleepWindow>[
    for (final w in (fx['windows'] as List).cast<List>()) (onset: _e(w[0] as String), wake: _e(w[1] as String)),
  ];

  group('Регулярность и оценка сна: Dart = Python (20 ночей WHOOP)', () {
    test('SRI и регулярность совпадают до 0,1 (секунды окон)', () {
      for (final n in (fx['nights'] as List).cast<Map>()) {
        final last = (onset: _e(n['onset'] as String), wake: _e(n['wake'] as String));
        final sri = sriOf(windows, last);
        expect(sri, isNotNull, reason: n['onset'] as String);
        expect(sri!, closeTo((n['sri'] as num).toDouble(), 0.1), reason: n['onset'] as String);
        expect(consistencyOf(windows, last)!, closeTo((n['cons_expected'] as num).toDouble(), 0.1));
      }
    });

    test('оценка сна v2 (без стресс-индекса — веса перенормированы) = Python до 0,1', () {
      var err = 0.0, k = 0;
      for (final n in (fx['nights'] as List).cast<Map>()) {
        final last = (onset: _e(n['onset'] as String), wake: _e(n['wake'] as String));
        final sc = sleepScoreV2(
          tstMin: n['tst'] as num,
          needMin: n['need'] as num,
          consistency: consistencyOf(windows, last),
          effPct: n['eff'] as num,
        )!;
        expect(sc.pct, closeTo((n['score_expected'] as num).toDouble(), 0.1));
        err += (sc.pct - (n['whoop_perf'] as num)).abs();
        k++;
      }
      // Справочно: к самому WHOOP на этих 20 ночах — в допуске §8.2 (MAE ≤ 5).
      expect(err / k, lessThanOrEqualTo(5));
    });

    test('меньше 3 ночей в окне — регулярности нет', () {
      final w = [(onset: _e('2026-08-08 00:00:00'), wake: _e('2026-08-08 08:00:00'))];
      expect(sriOf(w, w.last), isNull);
    });
  }, skip: private);

  group('Составляющие', () {
    test('балл ночного стресса: 100 / 70 / 40', () {
      expect(stressScore(.005), 100);
      expect(stressScore(.05), closeTo(70, 1e-9));
      expect(stressScore(.10), closeTo(55, 1e-9));
      expect(stressScore(.30), 40);
    });

    test('отбой для цели 100 / 85 / 70 %', () {
      final wake = DateTime(2026, 10, 16, 7, 30);
      expect(bedtimeFor(wake: wake, needMin: 489, target: 1, effPct: 94, latencyMin: 9), DateTime(2026, 10, 15, 22, 41));
      expect(bedtimeFor(wake: wake, needMin: 489, target: .85, effPct: 94, latencyMin: 9), DateTime(2026, 10, 15, 23, 59));
      expect(bedtimeFor(wake: wake, needMin: 489, target: .70, effPct: 94, latencyMin: 9), DateTime(2026, 10, 16, 1, 17));
    });

    test('пробуждения: ≥ 5 мин — пробуждение, короче — отдельно, утро не считается', () {
      final t = _e('2026-10-15 23:00:00');
      StageRun r(int a, int b, Stage? s) => (from: t + a * 60, to: t + b * 60, stage: s);
      final runs = [
        r(0, 9, Stage.wake), // засыпание
        r(9, 120, Stage.light),
        r(120, 128, Stage.wake), // 8 мин — пробуждение
        r(128, 200, Stage.deep),
        r(200, 203, Stage.wake), // 3 мин — короткое
        r(203, 300, Stage.rem),
        r(300, 310, null), // нет данных
        r(310, 450, Stage.light),
        r(450, 470, Stage.wake), // утренний подъём — не пробуждение
      ];
      final a = awakeningsOf(runs);
      expect(a.long, 1);
      expect(a.short, 1);
      expect(a.awakeMin, 11);
      final m = stageMinutes(runs);
      expect(m[Stage.deep], 72);
      expect(m[Stage.wake], 40);
    });
  }, skip: private);

  test('потребность и долг: Dart = Python на 60 последних днях WHOOP (до 0,01 мин)', () {
    final fx = jsonDecode(File('test/fixtures/ritm_compare/need_whoop_60.json').readAsStringSync()) as Map;
    final th = fx['theta'] as Map;
    final theta = SleepTheta(
      needBase: (th['base'] as num).toDouble(),
      needKs: (th['k_s'] as num).toDouble(),
      debtD: (th['d'] as num).toDouble(),
      debtG: (th['g'] as num).toDouble(),
    );
    final nights = [
      for (final n in (fx['nights'] as List).cast<Map>())
        (
          tst: (n['tst'] as num?)?.toDouble(),
          strainPrev: (n['strain_prev'] as num).toDouble(),
          napPrev: (n['nap_prev'] as num).toDouble(),
        ),
    ];
    final got = needDebtSeries(nights, theta: theta);
    final exp = (fx['expected'] as List).cast<Map>();
    for (var i = 0; i < exp.length; i++) {
      expect(got[i].need, closeTo((exp[i]['need'] as num).toDouble(), .01), reason: '$i');
      expect(got[i].debt, closeTo((exp[i]['debt'] as num).toDouble(), .01), reason: '$i');
    }
    // К самому WHOOP после 14 дней разгона — в допуске §8.2 (MAE ≤ 20 мин).
    var e = 0.0, k = 0;
    for (var i = 14; i < exp.length; i++) {
      final w = (fx['nights'] as List)[i] as Map;
      if (w['whoop_need'] == null) continue;
      e += (got[i].need - (w['whoop_need'] as num)).abs();
      k++;
    }
    expect(e / k, lessThanOrEqualTo(20));
  }, skip: File('test/fixtures/ritm_compare/need_whoop_60.json').existsSync() ? null : 'личная выгрузка WHOOP не публикуется');

  test('константы θ сна = калибровка (calibration_theta.json)', () {
    expect(kSleepTheta.needBase, 451);
    expect(kSleepTheta.debtG, .511);
  });

  test('потребность на следующую ночь (демо: 8:57 сегодня → 8:36)', () {
    final n = nextNeed((need: 537, debt: 66.6, base: 451, strainAdd: 19.5, napCredit: 0), tstToday: 452, strainToday: 10.8);
    expect(n.debt, closeTo(48.07, .05));
    expect(n.need, closeTo(515.5, .1));
  });
}
