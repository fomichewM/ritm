// «Ритм» B4½: формулы колец (ТЗ v3 §7.1–§7.3) — rMSSD последнего SWS-окна,
// пульс покоя за сон, базовые линии 28 ночей, вес сна 0,15 в Восстановлении,
// Нагрузка весь день по зонам резерва, TRIMP, шкала 0–21, склейка рядов.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_rings.dart';

const t0 = 1790000000; // эпоха, секунды (начало ночи)

/// Ночь: 23:00 → 07:00, DEEP 00:30–01:10 и 04:00–04:20, конец — REM, WAKE 03:00–03:03.
List<HypSeg> night() => const [
  HypSeg(t0, t0 + 1800, 'light'),
  HypSeg(t0 + 1800, t0 + 4200, 'deep'),
  HypSeg(t0 + 4200, t0 + 14400, 'light'),
  HypSeg(t0 + 14400, t0 + 14580, 'wake'),
  HypSeg(t0 + 14580, t0 + 18000, 'rem'),
  HypSeg(t0 + 18000, t0 + 19200, 'deep'),
  HypSeg(t0 + 19200, t0 + 28800, 'rem'),
];

/// rMSSD каждую минуту: 40 мс, но во втором DEEP — 70, в первом — 55.
List<TV> hrvLine() => [
  for (var t = t0 + 300; t <= t0 + 28800; t += 60)
    TV(t, (t - 150 >= t0 + 18000 && t - 150 < t0 + 19200)
        ? 70
        : (t - 150 >= t0 + 1800 && t - 150 < t0 + 4200 ? 55 : 40)),
];

/// Пульс по минутам: сон 50, бодрствование 03:00–03:03 — 80.
List<TV> hrLine() => [
  for (var t = t0; t < t0 + 28800; t += 60)
    TV(t, t >= t0 + 14400 && t < t0 + 14580 ? 80 : 50),
];

void main() {
  group('K4 ВСР: последний эпизод глубокого сна', () {
    test('берётся ПОСЛЕДНИЙ DEEP ≥ 3 мин, а не среднее ночи', () {
      final r = rmssdSwsLast(night(), hrvLine());
      expect(r.sws, isTrue);
      expect(r.v, 70);
      final mean = rmssdNightMean(night(), hrvLine())!;
      expect(mean, lessThan(50)); // справочный оценщик — другой
    });

    test('короткий последний DEEP (< 3 мин) пропускается → предыдущий', () {
      final h = [
        ...night().take(5),
        const HypSeg(t0 + 18000, t0 + 18120, 'deep'), // 2 мин
        const HypSeg(t0 + 18120, t0 + 28800, 'rem'),
      ];
      final r = rmssdSwsLast(h, hrvLine());
      expect(r.sws, isTrue);
      expect(r.v, 55);
    });

    test('куски DEEP с разрывом ≤ 60 с склеиваются в эпизод', () {
      final eps = deepEpisodes(const [
        HypSeg(0, 100, 'deep'),
        HypSeg(100, 140, 'light'),
        HypSeg(140, 300, 'deep'),
      ]);
      expect(eps, [(0, 300)]);
    });

    test('без DEEP — последние 5 мин сна, флаг sws=false', () {
      final h = [for (final s in night()) HypSeg(s.start, s.end, s.stage == 'deep' ? 'light' : s.stage)];
      final r = rmssdSwsLast(h, hrvLine());
      expect(r.sws, isFalse);
      expect(r.v, 40);
    });
  });

  group('K5 пульс покоя', () {
    test('sleep_mean — без минут WAKE; trough30 — минимум 30-мин среднего', () {
      expect(rhrSleepMean(night(), hrLine()), 50);
      final hr = [
        for (final p in hrLine()) TV(p.t, p.t > t0 + 20000 && p.t < t0 + 22000 ? 46 : p.v),
      ];
      expect(rhrTrough30(night(), hr)!, closeTo(46, 0.01));
      expect(rhrSleepMean(night(), hr)!, greaterThan(46));
    });

    test('ночные входы: окно, TST, качество', () {
      final n = nightInputs(hyp: night(), hrMin: hrLine(), hrv: hrvLine());
      expect(n.tstMin, 477);
      expect(n.inBedMin, 480);
      expect(n.observedFrac, 1);
      expect(n.hrValidFrac, closeTo(1, 0.01));
      expect(n.maxGapMin, 0);
      expect(n.rmssdSwsLast, 70);
      expect(n.tooShort, isFalse);
    });
  });

  group('базовые линии 30 ночей', () {
    test('по умолчанию среднее и SD последних 30 (калибровка 15.10); пол σ', () {
      final xs = [for (var i = 0; i < 40; i++) i < 10 ? 100.0 : 50.0 + (i % 3)];
      final b = Baseline.of(xs, floor: 0.3)!;
      expect(b.n, 30); // старые 10 «сотен» вне окна
      expect(b.med, closeTo(51, 1e-9));
      expect(b.sigma, closeTo(math.sqrt(2 / 3), 1e-9));
      final w = Baseline.of([...List.filled(25, 50.0), 80, 80, 80, 80, 80], floor: 0.3)!;
      expect(w.med, 55); // среднее чувствительно к выбросам — так у WHOOP-нормы
    });

    test('robust: медиана и MAD·1,4826 по последним 28; пол σ', () {
      final xs = [for (var i = 0; i < 40; i++) i < 12 ? 100.0 : 50.0 + (i % 3)];
      final b = Baseline.of(xs, floor: 0.3, window: 28, robust: true)!;
      expect(b.n, 28); // старые 12 «сотен» вне окна
      expect(b.med, 51);
      expect(b.sigma, closeTo(1.4826, 1e-9));
      final flat = Baseline.of(List.filled(10, 50.0), floor: 1.0)!;
      expect(flat.sigma, 1.0);
      expect(Baseline.of([1, 2, 3], floor: 1), isNull); // < 4 ночей
    });
  });

  group('§7.2 Восстановление', () {
    final hrvHist = [for (var i = 0; i < 28; i++) 50.0 + (i % 5) - 2];
    final rhrHist = [for (var i = 0; i < 28; i++) 52.0 + (i % 3) - 1];

    test('обычная ночь → центр ≈ 72 % (калиброванное b = 0,939, как WHOOP-медиана Михаила)', () {
      final r = recoveryV3(rmssd: 50, rhr: 52, sleepPct: 85, rmssdHist: hrvHist, rhrHist: rhrHist);
      expect(r.value, 72); // z̄ ≈ 0,02 → 100/(1+e^−(1,076·0,02+0,939)) = 72,3
      final start = recoveryV3(
          rmssd: 50, rhr: 52, sleepPct: 85, rmssdHist: hrvHist, rhrHist: rhrHist, theta: const RingTheta());
      expect(start.value, 59); // стартовые θ ТЗ: 100/(1+e^−0,35) ≈ 58,7
      expect(r.preliminary, isFalse);
    });

    test('вес сна 0,15: плохой сон снижает, z_slp ограничен [−2; +1]', () {
      final good = recoveryV3(rmssd: 50, rhr: 52, sleepPct: 100, rmssdHist: hrvHist, rhrHist: rhrHist);
      final bad = recoveryV3(rmssd: 50, rhr: 52, sleepPct: 55, rmssdHist: hrvHist, rhrHist: rhrHist);
      final s = bad.drivers.firstWhere((d) => d.key == 'sleep');
      expect(s.z, -2.0);
      expect(s.weight, closeTo(0.15 / 0.80, 1e-9)); // без дыхания и темп.: Σw = 0,80
      expect(good.value!, greaterThan(bad.value!));
      final g = good.drivers.firstWhere((d) => d.key == 'sleep');
      expect(g.z, 1.0);
    });

    test('высокая ВСР + низкий пульс → зелёная; наоборот → красная', () {
      final hi = recoveryV3(rmssd: 75, rhr: 48, sleepPct: 95, rmssdHist: hrvHist, rhrHist: rhrHist);
      final lo = recoveryV3(rmssd: 28, rhr: 60, sleepPct: 70, rmssdHist: hrvHist, rhrHist: rhrHist);
      expect(hi.value!, greaterThanOrEqualTo(67));
      expect(lo.value!, lessThan(34));
    });

    test('Сон < 60 % → не выше 66; короткая ночь → нет числа', () {
      final r = recoveryV3(rmssd: 90, rhr: 44, sleepPct: 50, rmssdHist: hrvHist, rhrHist: rhrHist);
      expect(r.value, 66);
      expect(r.cappedBySleep, isTrue);
      expect(
        recoveryV3(rmssd: 50, rhr: 52, rmssdHist: hrvHist, rhrHist: rhrHist, shortNight: true).why,
        'short_night',
      );
    });

    test('калибровка: < 4 ночей — нет числа, 4–13 — предварительное', () {
      final c = recoveryV3(rmssd: 50, rhr: 52, rmssdHist: [50, 51, 49], rhrHist: [52, 52, 52]);
      expect(c.value, isNull);
      expect(c.why, 'calibrating');
      final p = recoveryV3(rmssd: 50, rhr: 52, rmssdHist: [50, 51, 49, 50, 52], rhrHist: [52, 53, 51, 52, 52]);
      expect(p.value, isNotNull);
      expect(p.preliminary, isTrue);
    });

    test('вклады в пунктах ≈ сумма (знаки как у z)', () {
      final r = recoveryV3(rmssd: 60, rhr: 55, sleepPct: 90, resp: 16, respHist: List.filled(10, 14.5),
          rmssdHist: hrvHist, rhrHist: rhrHist);
      final hrv = r.drivers.firstWhere((d) => d.key == 'hrv');
      final rhr = r.drivers.firstWhere((d) => d.key == 'rhr');
      final resp = r.drivers.firstWhere((d) => d.key == 'resp');
      expect(hrv.points, greaterThan(0));
      expect(rhr.points, lessThan(0));
      expect(resp.z, lessThanOrEqualTo(0)); // дыхание — только штраф
      expect(r.drivers.map((d) => d.key), isNot(contains('temp'))); // без settledFraction
    });
  });

  group('§7.3 Нагрузка: весь день по зонам резерва', () {
    List<HrMinute> day({int runMin = 0, double runHr = 160, double rest = 62}) => [
      for (var i = 0; i < 16 * 60; i++)
        HrMinute(t0 + i * 60, i >= 600 && i < 600 + runMin ? runHr : rest, HrSrc.band),
    ];

    test('шкала 0–21: монотонна, предел 21, arctan', () {
      expect(strainScale(0, kRingTheta), 0);
      expect(strainScale(kRingTheta.strainS, kRingTheta), closeTo(10.5, 1e-9)); // I = s → 21·½
      expect(strainScale(1e9, kRingTheta), lessThan(21));
      expect(strainScale(200, kRingTheta), greaterThan(strainScale(100, kRingTheta)));
    });

    test('сидячий день — лёгкая, час бега — умеренная/высокая', () {
      final calm = strainV3(day(), rhr: 52, hrMax: 185);
      final run = strainV3(day(runMin: 60), rhr: 52, hrMax: 185);
      expect(calm.strain, inInclusiveRange(2, 9.9));
      expect(run.strain, inInclusiveRange(10, 17.9));
      expect(run.zoneMin[4] + run.zoneMin[3], 60); // 160 уд/мин = 81 % резерва → Z4
      expect(calm.zoneMin[0], 960); // минуты ниже 40 % считаются (не отсекаются)
      expect(calm.load, greaterThan(0));
    });

    test('Z0 даёт малый, но не нулевой вклад; вес w(v) растёт экспоненциально', () {
      expect(strainWeight(0, kRingTheta), 0);
      expect(strainWeight(0.2, kRingTheta), greaterThan(0));
      expect(strainWeight(0.9, kRingTheta) / strainWeight(0.45, kRingTheta), greaterThan(3));
    });

    test('TRIMP Баннистера — второй оценщик', () {
      final r = strainV3(day(runMin: 30), rhr: 52, hrMax: 185);
      final v = (160 - 52) / (185 - 52);
      final runPart = 30 * v * 0.64 * math.exp(1.92 * v);
      expect(r.trimp, greaterThan(runPart));
      final f = strainV3(day(runMin: 30), rhr: 52, hrMax: 185, female: true);
      expect(f.trimp, isNot(r.trimp));
    });

    test('страховка: 0 при ≥ 20 мин пульса > покой + 30 → флаг', () {
      const th = RingTheta(strainS: 1e12);
      final r = strainV3(day(runMin: 25), rhr: 52, hrMax: 185, theta: th);
      expect(r.suspicious, isTrue);
    });

    test('HRmax: профиль → максимум 90 дней → Танака', () {
      expect(hrMaxFor(profile: 190, observed90: 180, age: 40), 190);
      expect(hrMaxFor(observed90: 181, age: 40), 181);
      expect(hrMaxFor(age: 40), 180);
    });
  });

  group('D7 склейка ряда пульса', () {
    final band = [for (var i = 0; i < 120; i++) TV(t0 + i * 60, 70)];
    SecondWorkout run({double cover = 1, bool cardio = true}) => SecondWorkout(
      from: t0 + 30 * 60,
      to: t0 + 60 * 60,
      cardio: cardio,
      hr: [
        for (var i = 0; i < (30 * cover).round(); i++) ...[
          TV(t0 + 30 * 60 + i * 60 + 5, 150),
          TV(t0 + 30 * 60 + i * 60 + 35, 152),
        ],
      ],
    );

    test('два ряда → один: в беге Watch, иначе браслет; TRIMP = сумма сегментов', () {
      final xs = stitchHr(band, [run()]);
      expect(xs.length, 120); // минуты не дублируются
      expect(xs.where((m) => m.src == HrSrc.watch).length, 30);
      expect(xs[45].hr, 151);
      final whole = strainV3(xs, rhr: 52, hrMax: 185);
      final a = strainV3(xs.where((m) => m.src == HrSrc.band).toList(), rhr: 52, hrMax: 185);
      final b = strainV3(xs.where((m) => m.src == HrSrc.watch).toList(), rhr: 52, hrMax: 185);
      expect(whole.trimp, closeTo(a.trimp + b.trimp, 1e-9));
      expect(whole.load, closeTo(a.load + b.load, 1e-9));
      expect(strainSourceLine(whole.bySrc), 'браслет 1 ч 30 мин + Watch 30 мин');
    });

    test('Watch < 80 % минут или силовая — остаётся браслет', () {
      expect(stitchHr(band, [run(cover: 0.7)]).every((m) => m.src == HrSrc.band), isTrue);
      expect(stitchHr(band, [run(cardio: false)]).every((m) => m.src == HrSrc.band), isTrue);
      expect(isCardioHkType(37), isTrue);
      expect(isCardioHkType(50), isFalse); // силовая
    });

    test('таймлайн: браслет / Watch / не носился', () {
      final xs = stitchHr(band, [run()]);
      final tl = hrTimeline(xs, t0 - 3600, t0 + 3 * 3600);
      expect(tl.first.src, isNull); // час до надевания
      expect(tl.map((s) => s.src).where((s) => s != null).toList(), [HrSrc.band, HrSrc.watch, HrSrc.band]);
      expect(tl.last.src, isNull);
      expect(tl[2].minutes, 30);
    });

    test('гистограмма доли резерва для калибровки', () {
      final xs = stitchHr(band, [run()]);
      final h = vHistogram(xs, rhr: 52, hrMax: 185).split(';').map(int.parse).toList();
      expect(h.length, 24);
      expect(h.reduce((a, b) => a + b), 120);
    });
  });

  test('θ: калибровка 15.10 по CSV WHOOP, JSON туда-обратно, стартовые значения ТЗ', () {
    expect(kRingTheta.recA, 1.076);
    expect(kRingTheta.recB, 0.939);
    expect(kRingTheta.strainK, 3.901);
    expect(kRingTheta.strainS, 65.8);
    expect(kRingTheta.calibrated, isTrue);
    expect(kRingTheta.calibratedAt, '2026-10-15');
    expect(const RingTheta().recA, 1.2);
    expect(const RingTheta().calibrated, isFalse);
    final j = RingTheta.fromJson(const RingTheta(recA: 1.1, strainS: 90, calibratedAt: '2026-11-01').toJson());
    expect(j.recA, 1.1);
    expect(j.strainS, 90);
    expect(j.calibrated, isTrue);
  });
}
