// «Ритм» — единый стандарт форматов (ТЗ v2 §1.6): десятичная запятая,
// сон «7:32», проценты без пробела, разряды узким пробелом, даты «Вт, 14 окт»,
// часы «07:30»; плюс состояние ночи (§10.1) и рекомендованный отбой (§2.5b).

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ritm/ritm_scores.dart';

void main() {
  group('форматы §1.6', () {
    test('десятичные — запятая', () {
      expect(dec1(14.2), '14,2');
      expect(dec1(9), '9,0');
    });
    test('время сна — «7:32», никогда «7 ч 32 мин»', () {
      expect(hmm(452), '7:32');
      expect(hmm(489), '8:09');
      expect(hmm(45), '0:45');
    });
    test('проценты без пробела', () {
      expect(pct(72), '72%');
      expect(pct(86.6), '87%');
    });
    test('шаги — узкий неразрывный пробел', () {
      expect(thousands(7512), '7\u202F512');
      expect(thousands(980), '980');
      expect(thousands(1234567), '1\u202F234\u202F567');
    });
    test('даты «Вт, 14 окт»', () {
      expect(shortDayRu('2026-10-14'), 'Ср, 14 окт');
      expect(shortDayRu('2026-10-13'), 'Вт, 13 окт');
    });
    test('часы «07:30»', () {
      expect(clock(7 * 60 + 30), '07:30');
      expect(clock(22 * 60 + 5), '22:05');
      expect(clock(-30), '23:30');
    });
    test('знак дельты — типографский минус', () {
      expect(signed(4), '+4');
      expect(signed(-2), '−2');
      expect(signed(.25, decimal: true), '+0,3');
    });
  });

  group('состояние ночи §10.1', () {
    final now = DateTime(2026, 10, 15, 7, 30);
    test('ночь открыта и данные свежие — «идёт сон»', () {
      expect(
        ritmNightPhase(
          hasNight: false,
          recoveryState: 'night_in_progress',
          now: now,
          dataEdge: now.subtract(const Duration(minutes: 4)),
        ),
        NightPhase.asleep,
      );
    });
    test('ночь открыта, данные старше 10 мин — «считаю»', () {
      expect(
        ritmNightPhase(
          hasNight: false,
          recoveryState: 'night_in_progress',
          now: now,
          dataEdge: now.subtract(const Duration(minutes: 25)),
        ),
        NightPhase.computing,
      );
    });
    test('идёт синхронизация — «считаю»', () {
      expect(
        ritmNightPhase(
          hasNight: false,
          recoveryState: 'night_in_progress',
          now: now,
          dataEdge: now,
          syncing: true,
        ),
        NightPhase.computing,
      );
    });
    test('ночь посчитана — готово', () {
      expect(
        ritmNightPhase(hasNight: true, recoveryState: 'final', now: now),
        NightPhase.done,
      );
    });
    test('к полудню ночи нет — «нет данных»', () {
      expect(
        ritmNightPhase(
          hasNight: false,
          recoveryState: null,
          now: DateTime(2026, 10, 15, 12, 30),
          dataEdge: DateTime(2026, 10, 15, 9),
        ),
        NightPhase.none,
      );
    });
    test('прошлый день не «считается»', () {
      expect(
        ritmNightPhase(
          hasNight: false,
          recoveryState: 'night_in_progress',
          now: now,
          isToday: false,
        ),
        NightPhase.none,
      );
    });
  });

  group('отбой §2.5b', () {
    test('подъём − потребность − 15 мин', () {
      expect(
        ritmBedtime(wakeMinOfDay: 7 * 60 + 30, needMin: 485),
        23 * 60 + 10,
      );
      expect(clock(ritmBedtime(wakeMinOfDay: 450, needMin: 489)!), '23:06');
    });
    test('своя латентность засыпания', () {
      expect(
        ritmBedtime(wakeMinOfDay: 7 * 60, needMin: 480, latencyMin: 5),
        22 * 60 + 55,
      );
    });
    test('без будильника или потребности — null', () {
      expect(ritmBedtime(needMin: 480), isNull);
      expect(ritmBedtime(wakeMinOfDay: 420), isNull);
    });
  });
}
