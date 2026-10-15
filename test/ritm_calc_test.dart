// «Ритм» B1′: алгоритмы Монитора здоровья (§10.4), Кардиоформы (§10.8),
// сверки браслет / Apple Watch (§10.9) и источника «Watch» в Здоровье.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ritm/ritm_calc.dart';

/// 30 ночей пульса покоя: 50…54 по кругу (p10≈50, p90≈54).
final _rhr30 = [for (var i = 0; i < 30; i++) 50.0 + i % 5];
final _hrv30 = [for (var i = 0; i < 30; i++) 40.0 + (i % 11) * 2];

void main() {
  group('перцентили', () {
    test('p10 / медиана / p90 с интерполяцией', () {
      final xs = [for (var i = 1; i <= 11; i++) i.toDouble()];
      expect(percentile(xs, .5), 6);
      expect(percentile(xs, .1), 2);
      expect(percentile(xs, .9), 10);
      expect(percentile(const [], .5), isNull);
    });
  });

  group('Монитор здоровья (§10.4)', () {
    test('пульс покоя: порог p90 по 30 ночам, в норме', () {
      final r = monitorRow(MonKind.rhr, history: _rhr30, last: 52);
      expect(r.status, MonStatus.ok);
      expect(r.value, '52');
      expect(r.note, 'норма до 54');
      expect(r.preliminary, isFalse);
    });

    test('пульс покоя выше p90 — жёлтый, две ночи подряд — красный', () {
      expect(
        monitorRow(MonKind.rhr, history: _rhr30, last: 58, prev: 52).status,
        MonStatus.warn,
      );
      expect(
        monitorRow(MonKind.rhr, history: _rhr30, last: 58, prev: 57).status,
        MonStatus.alert,
      );
    });

    test('ВСР ниже p10 — жёлтый, две ночи — красный', () {
      expect(
        monitorRow(MonKind.hrv, history: _hrv30, last: 35, prev: 50).status,
        MonStatus.warn,
      );
      expect(
        monitorRow(MonKind.hrv, history: _hrv30, last: 35, prev: 36).status,
        MonStatus.alert,
      );
    });

    test('дыхание: > медиана+1,5 жёлтый, > +2 красный', () {
      final h = [for (var i = 0; i < 20; i++) 14.0];
      expect(
        monitorRow(MonKind.resp, history: h, last: 15.4).status,
        MonStatus.ok,
      );
      expect(
        monitorRow(MonKind.resp, history: h, last: 15.7).status,
        MonStatus.warn,
      );
      expect(
        monitorRow(MonKind.resp, history: h, last: 16.3).status,
        MonStatus.alert,
      );
      expect(monitorRow(MonKind.resp, history: h, last: 15.7).value, '15,7');
    });

    test('температура: +0,3…+0,5 жёлтый, > +0,5 красный', () {
      expect(
        monitorRow(MonKind.temp, history: _rhr30, last: .2).status,
        MonStatus.ok,
      );
      expect(
        monitorRow(MonKind.temp, history: _rhr30, last: .4).status,
        MonStatus.warn,
      );
      expect(
        monitorRow(MonKind.temp, history: _rhr30, last: .7).status,
        MonStatus.alert,
      );
      expect(monitorRow(MonKind.temp, history: _rhr30, last: .4).value, '+0,4');
    });

    test('меньше 7 ночей — калибровка «нужно 7 ночей · 3/7»', () {
      final r = monitorRow(MonKind.rhr, history: const [51, 52, 50], last: 53);
      expect(r.status, MonStatus.calibrating);
      expect(r.note, 'нужно 7 ночей · 3/7');
      expect(r.value, '53');
    });

    test('7–13 ночей — коридор с пометкой «предварительно»', () {
      final r = monitorRow(
        MonKind.rhr,
        history: _rhr30.sublist(0, 9),
        last: 52,
      );
      expect(r.preliminary, isTrue);
      expect(r.note, endsWith('предварительно'));
    });

    test(
      'SpO₂ без Watch — «нет источника», с данными — пороги 95/93',
      () {
        expect(
          monitorRow(MonKind.spo2, history: const [], hasSource: false).note,
          'нет источника: нужны Apple Watch',
        );
        expect(
          monitorRow(MonKind.spo2, history: const [], last: 96).status,
          MonStatus.ok,
        );
        expect(
          monitorRow(MonKind.spo2, history: const [], last: 94).status,
          MonStatus.warn,
        );
        expect(
          monitorRow(MonKind.spo2, history: const [], last: 91).status,
          MonStatus.alert,
        );
      },
    );

    test('итог: все в норме / одно отклонение / два и больше', () {
      final ok = monitorRow(MonKind.rhr, history: _rhr30, last: 52);
      final ok2 = monitorRow(MonKind.hrv, history: _hrv30, last: 50);
      final warn = monitorRow(MonKind.rhr, history: _rhr30, last: 58, prev: 52);
      final warn2 = monitorRow(
        MonKind.hrv,
        history: _hrv30,
        last: 35,
        prev: 50,
      );
      final none = monitorRow(
        MonKind.spo2,
        history: const [],
        hasSource: false,
      );
      expect(monitorSummary([ok, ok2, none]).text, 'В норме · 2 из 2');
      expect(monitorSummary([warn, ok2]).text, '1 вне нормы: пульс покоя 58');
      expect(monitorSummary([warn, warn2]).status, MonStatus.alert);
      expect(illnessRadar([ok, ok2]), isNull);
      expect(illnessRadar([warn]), contains('пульс покоя выше нормы'));
    });

    test('итог при калибровке — «Изучаем норму · N/7»', () {
      final r = monitorRow(MonKind.rhr, history: const [51, 52, 50], last: 53);
      expect(monitorSummary([r]).text, 'Изучаем норму · 3/7');
    });
  });

  group('Кардиоформа (§10.8)', () {
    test('меньше 14 дней — калибровка (нет тренда)', () {
      expect(cardioHrv(_hrv30.sublist(0, 10)).form, isNull);
      expect(cardioVerdict([null, null]), isNull);
    });

    test('ВСР растёт: последние 7 дней выше месяца', () {
      final xs = [
        for (var i = 0; i < 23; i++) 45.0,
        for (var i = 0; i < 7; i++) 55.0,
      ];
      final t = cardioHrv(xs);
      expect(t.form, 1);
      expect(t.delta, startsWith('↑ +'));
    });

    test('пульс покоя: Δ ≤ −1 → форма ↑, ≥ +1 → ↓', () {
      final down = [
        for (var i = 0; i < 23; i++) 54.0,
        for (var i = 0; i < 7; i++) 51.0,
      ];
      final up = [
        for (var i = 0; i < 23; i++) 50.0,
        for (var i = 0; i < 7; i++) 53.0,
      ];
      expect(cardioRhr(down).form, 1);
      expect(cardioRhr(up).form, -1);
      expect(cardioRhr(_rhr30).form, 0);
    });

    test('итоговое слово', () {
      expect(cardioVerdict([1, 1]), 'Растёт');
      expect(cardioVerdict([1, 0]), 'Растёт');
      expect(cardioVerdict([-1, -1]), 'Снижается');
      expect(cardioVerdict([1, -1]), 'Стабильна');
      expect(cardioVerdict([-1, 0]), 'Стабильна');
    });
  });

  group('Сверка браслет / Watch (§10.9)', () {
    test('пульс покоя: ≤3 совпадают, 4–6 расходятся, >6 проверьте', () {
      expect(reconcileRhr(51, 52), Agree.match);
      expect(reconcileRhr(51, 54), Agree.match);
      expect(reconcileRhr(51, 55), Agree.differ);
      expect(reconcileRhr(51, 57), Agree.differ);
      expect(reconcileRhr(51, 58), Agree.check);
    });

    test('сон: ≤20 мин совпадают, 21–45 расходятся, >45 проверьте', () {
      expect(reconcileSleep(452, 441), Agree.match);
      expect(reconcileSleep(452, 420), Agree.differ);
      expect(reconcileSleep(452, 400), Agree.check);
      expect(agreeWord(Agree.check, sleep: true), 'проверьте браслет');
    });

    test('строка-итог для «Здоровья»', () {
      expect(reconcileSummary(), 'Watch не носился ночью');
      expect(
        reconcileSummary(rhr: Agree.match, sleep: Agree.match),
        'Браслет и Watch совпадают',
      );
      expect(
        reconcileSummary(rhr: Agree.differ, sleep: Agree.match),
        '1 показатель расходится',
      );
      expect(
        reconcileSummary(rhr: Agree.check),
        'Расходятся — проверьте браслет',
      );
    });
  });

  group('Источник «Apple Watch» в Здоровье', () {
    test('Watch по модели устройства или имени источника', () {
      expect(
        isWatchSample(
          sourceId: 'com.apple.health.X',
          sourceName: 'Apple Watch Михаила',
          deviceModel: 'Watch',
        ),
        isTrue,
      );
      expect(
        isWatchSample(
          sourceId: 'com.apple.health.Y',
          sourceName: 'iPhone',
          deviceModel: 'iPhone',
        ),
        isFalse,
      );
      // Свои записи («Ритм» пишет в Здоровье) — никогда не Watch.
      expect(
        isWatchSample(
          sourceId: 'com.oporagroup.ritm',
          sourceName: 'Ритм',
          deviceModel: 'Watch',
          ownBundle: 'com.oporagroup.ritm',
        ),
        isFalse,
      );
    });

    test('минуты сна Watch: пересечения стадий сливаются', () {
      DateTime t(int h, int m) => DateTime(2026, 10, 15, h, m);
      final mins = watchSleepMinutes([
        (from: t(0, 0), to: t(2, 0)),
        (from: t(1, 30), to: t(3, 0)), // пересекается
        (from: t(4, 0), to: t(6, 30)), // после пробуждения 3:00–4:00
      ]);
      expect(mins, 180 + 150);
      expect(watchSleepMinutes(const []), 0);
    });
  });
}
