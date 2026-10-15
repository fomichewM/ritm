import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_scores.dart';

void main() {
  group('ritmRecovery (RITM2_PROPOSAL 2.2)', () {
    test('типичная ночь Edge 50 → 61, жёлтый', () {
      expect(ritmRecovery(50), 61);
      expect(recoveryZone(ritmRecovery(50)), RitmZone.yellow);
    });
    test('монотонна и в пределах 0–100', () {
      var prev = -1;
      for (var s = 0; s <= 100; s += 5) {
        final r = ritmRecovery(s)!;
        expect(r, inInclusiveRange(0, 100));
        expect(r, greaterThanOrEqualTo(prev));
        prev = r;
      }
    });
    test('ночь лучше ~60% своих → зелёный; хуже ~15% → красный', () {
      // σ(z̄)≈0,65: 60-й перцентиль z̄≈0,165 → s_edge≈54; 15-й z̄≈−0,67 → s≈34.
      expect(recoveryZone(ritmRecovery(54.2)), RitmZone.green);
      expect(recoveryZone(ritmRecovery(33.8)), RitmZone.red);
    });
    test('короткий сон (<60%) не даёт зелёного', () {
      expect(ritmRecovery(90), greaterThan(66));
      expect(ritmRecovery(90, sleepPct: 55), 66);
      expect(ritmRecovery(90, sleepPct: 60), greaterThan(66));
      expect(ritmRecovery(20, sleepPct: 40), ritmRecovery(20));
    });
    test('null на входе — null', () {
      expect(ritmRecovery(null), isNull);
    });
  });

  group('Сон%', () {
    test('доля от потребности с потолком 100', () {
      expect(ritmSleepPct(432, 485), 89);
      expect(ritmSleepPct(600, 480), 100);
      expect(ritmSleepPct(400, null), isNull);
      expect(ritmSleepPct(400, 0), isNull);
    });
    test('пороги 85/70', () {
      expect(sleepZone(85), RitmZone.green);
      expect(sleepZone(84), RitmZone.yellow);
      expect(sleepZone(70), RitmZone.yellow);
      expect(sleepZone(69), RitmZone.red);
    });
  });

  group('Восстановление: пороги 67/34 и слова', () {
    test('границы', () {
      expect(recoveryZone(67), RitmZone.green);
      expect(recoveryZone(66), RitmZone.yellow);
      expect(recoveryZone(34), RitmZone.yellow);
      expect(recoveryZone(33), RitmZone.red);
      expect(recoveryWord(RitmZone.green), 'Готов');
      expect(recoveryWord(RitmZone.yellow), 'Умеренно');
      expect(recoveryWord(RitmZone.red), 'Отдых');
    });
  });

  group('Нагрузка 0–21', () {
    test('уровни', () {
      expect(strainWord(0), 'Лёгкая');
      expect(strainWord(9.9), 'Лёгкая');
      expect(strainWord(10), 'Умеренная');
      expect(strainWord(14), 'Высокая');
      expect(strainWord(18), 'Предельная');
    });
    test('цель по зоне восстановления', () {
      expect(strainTargetFor(RitmZone.green), (lo: 14.0, hi: 18.0));
      expect(strainTargetFor(RitmZone.yellow), (lo: 10.0, hi: 14.0));
      expect(strainTargetFor(RitmZone.red), (lo: 4.0, hi: 8.0));
      expect(strainTargetFor(null), isNull);
    });
  });

  group('серия дней ношения', () {
    final today = DateTime(2026, 10, 14, 9);
    test('считает подряд до сегодня', () {
      expect(
        wearStreak([
          '2026-10-14',
          '2026-10-13',
          '2026-10-12',
          '2026-10-10',
        ], today),
        3,
      );
    });
    test('сегодня ещё не пришло — считает от вчера', () {
      expect(wearStreak(['2026-10-13', '2026-10-12'], today), 2);
    });
    test('разрыв — 0', () {
      expect(wearStreak(['2026-10-11'], today), 0);
    });
    test('через границу месяца', () {
      expect(
        wearStreak(['2026-10-01', '2026-09-30'], DateTime(2026, 10, 1)),
        2,
      );
    });
  });

  group('причины словами', () {
    test('калибровка', () {
      expect(
        ritmWhy('need_baseline:have=5,need=14', fallback: '-'),
        'Изучаем вашу норму — ещё 9 ночей с браслетом.',
      );
      expect(
        ritmWhy('need_baseline:have=1,need=3', fallback: '-', days: true),
        'Изучаем вашу норму — ещё 2 дня ношения.',
      );
    });
    test('нет входа', () {
      expect(
        ritmWhy('need_input:name=age', fallback: '-'),
        contains('возраст'),
      );
    });
    test('английский текст не показываем', () {
      expect(
        ritmWhy('Some English reason.', fallback: 'нет данных'),
        'нет данных',
      );
    });
  });

  group('Пульс дня', () {
    test('зелёный день + сон', () {
      final t = pulseText(
        const PulseInput(
          recovery: 78,
          sleepPct: 92,
          sleepMin: 445,
          needMin: 485,
          strain: 6.2,
          driver: 'hrv',
          driverSign: 1,
          hour: 9,
        ),
      );
      expect(t, contains('Восстановление 78%'));
      expect(t, contains('14–18'));
      expect(t, contains('Сон 7:25'));
      expect(t.contains(RegExp('[A-Za-z]')), isFalse);
    });
    test('недосып и отбой', () {
      final t = pulseText(
        const PulseInput(
          recovery: 40,
          sleepPct: 70,
          sleepMin: 340,
          needMin: 485,
          bedtimeMinOfDay: 22 * 60 + 15,
          hour: 8,
        ),
      );
      expect(t, contains('не хватило 2:25'));
      expect(t, contains('22:15'));
    });
    test('калибровка', () {
      final t = pulseText(
        const PulseInput(
          calibrating: (have: 5, need: 14),
          sleepMin: 420,
          hour: 8,
        ),
      );
      expect(t, contains('5 из 14'));
    });
    test('заголовок по времени суток', () {
      expect(
        pulseTitle(const PulseInput(name: 'Михаил', hour: 8)),
        'Доброе утро, Михаил!',
      );
      expect(pulseTitle(const PulseInput(hour: 20)), 'Добрый вечер!');
    });
    test('итог прошлого дня: причина → следствие', () {
      final t = pulseText(
        const PulseInput(
          recovery: 52,
          sleepPct: 75,
          sleepMin: 372,
          needMin: 497,
          strain: 13.6,
          driver: 'rhr',
          driverSign: -0.7,
          isToday: false,
        ),
      );
      expect(
        t,
        contains(
          'Сон 6:12 при потребности 8:17 и пульс покоя выше нормы — отсюда восстановление 52%',
        ),
      );
      expect(t, contains('в рекомендованном коридоре 10–14'));
    });
    test('склонения', () {
      expect(plural(1, 'ночь', 'ночи', 'ночей'), 'ночь');
      expect(plural(3, 'ночь', 'ночи', 'ночей'), 'ночи');
      expect(plural(11, 'ночь', 'ночи', 'ночей'), 'ночей');
      expect(plural(22, 'ночь', 'ночи', 'ночей'), 'ночи');
    });
  });
}
