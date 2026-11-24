// «Ритм» B4: биовозраст §10.7, темп старения, калибровка, Кардиоформа §10.8,
// возраст из даты рождения, облачко (reduce motion), хвосты B3.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart'
    show strainFromPerMinuteHr;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/ritm/ritm_bio_ui.dart';
import 'package:openstrap_edge/ritm/ritm_bioage.dart';
import 'package:openstrap_edge/ritm/ritm_calc.dart';
import 'package:openstrap_edge/ritm/ritm_hk.dart';
import 'package:openstrap_edge/ritm/ritm_orb.dart';
import 'package:openstrap_edge/ritm/ritm_scores.dart';
import 'package:openstrap_edge/ritm/ritm_workout.dart';

/// [n] дней подряд до [end] с одинаковыми значениями.
List<BioDay> flat(
  int n, {
  DateTime? end,
  double sleep = 450,
  double sdOnset = 20,
  double steps = 9000,
  double z13Day = 25,
  double z45Day = 12,
  double strengthDay = 10,
  double rhr = 52,
  double? vo2 = 46,
}) {
  final e = end ?? DateTime(2026, 10, 15);
  return [
    for (var i = 0; i < n; i++)
      () {
        final d = DateTime(e.year, e.month, e.day - (n - 1 - i));
        // Разброс отбоя/подъёма ±sdOnset (чередование даёт SD ≈ sdOnset).
        final on = 23 * 60 + (i.isEven ? sdOnset : -sdOnset);
        return BioDay(
          d,
          sleepMin: sleep,
          onsetMin: on,
          wakeMin: on + sleep + 30,
          steps: steps,
          z13: z13Day,
          z45: z45Day,
          strength: strengthDay,
          rhr: rhr,
          vo2: vo2,
        );
      }(),
  ];
}

void main() {
  group('Возраст из даты рождения', () {
    test('граница дня рождения: накануне — ещё нет, в день — исполнилось', () {
      final b = DateTime(1989, 3, 21);
      expect(ageOn(b, DateTime(2026, 3, 20)), 36);
      expect(ageOn(b, DateTime(2026, 3, 21)), 37);
      expect(ageOn(b, DateTime(2026, 10, 15)), 37);
      expect(ageOn(b, DateTime(2027, 3, 20)), 37);
    });
    test('29 февраля: в невисокосный год — с 1 марта', () {
      final b = DateTime(2000, 2, 29);
      expect(ageOn(b, DateTime(2025, 2, 28)), 24);
      expect(ageOn(b, DateTime(2025, 3, 1)), 25);
    });
    test('возраст с долями: в день рождения целый, через полгода ≈ +0,5', () {
      final b = DateTime(1989, 3, 21);
      expect(ageYears(b, DateTime(2026, 3, 21)), closeTo(37, 1e-9));
      expect(ageYears(b, DateTime(2026, 9, 20)), closeTo(37.5, .01));
    });
    test('дата из профиля «1989-03-21»', () {
      expect(parseBirth('1989-03-21'), DateTime(1989, 3, 21));
      expect(parseBirth(null), isNull);
      expect(birthIso(DateTime(1989, 3, 1)), '1989-03-01');
    });
  });

  group('Таблицы вкладов §10.7', () {
    test('сон', () {
      expect(sleepYears(7.5), 0);
      expect(sleepYears(6), 1.5);
      expect(sleepYears(3), 4); // потолок +4
      expect(sleepYears(10), .5);
    });
    test('режим, шаги, зоны, силовые, пульс покоя', () {
      expect(regularYears(25), -1);
      expect(regularYears(45), 0);
      expect(regularYears(75), 1);
      expect(regularYears(120), 2);
      expect(stepsYears(8000), -1.5);
      expect(stepsYears(6000), 0);
      expect(stepsYears(4000), 1);
      expect(stepsYears(2000), 2);
      expect(z13Years(150), -1.5);
      expect(z13Years(100), 0);
      expect(z13Years(60), 1);
      expect(z45Years(80), -1.5);
      expect(z45Years(40), -.5);
      expect(z45Years(10), 0);
      expect(strengthYears(60), -1);
      expect(strengthYears(45), -.5);
      expect(strengthYears(0), .5);
      expect(rhrYears(55), -1.5);
      expect(rhrYears(60), 0);
      expect(rhrYears(70), 1);
      expect(rhrYears(80), 2.5);
    });
    test('VO₂max по перцентилям ACSM для возраста и пола', () {
      expect(vo2Years(46.2, age: 37), -3); // ≥ p75 (44,6) у мужчин 30–39
      expect(vo2Years(43, age: 37), -1.5);
      expect(vo2Years(39, age: 37), 0);
      expect(vo2Years(30, age: 37), 2);
      expect(vo2Years(40, age: 37, female: true), -3);
    });
  });

  group('Биовозраст §10.7', () {
    final birth = DateTime(1989, 3, 21);

    test('8 вкладов; сумма вкладов = биовозраст − паспорт', () {
      final days = flat(90);
      final r = computeBio(days, birth: birth);
      expect(r.state, BioState.ready);
      expect(r.parts.length, 8);
      expect(r.today.length, 8);
      expect(r.today.every((p) => p.present), isTrue);
      final sum = r.parts.fold<double>(0, (a, b) => a + b) + r.smooth;
      expect(((sum * 10).round()) / 10, r.delta);
      expect(r.bio, closeTo(r.age! + sum, .051));
      // Ровная жизнь — сглаживать нечего.
      expect(r.smooth, 0);
      // Все привычки хорошие: сон 0, режим −1, шаги −1,5, зоны 1–3
      // (175/нед) −1,5, зоны 4–5 (84/нед) −1,5, силовые (70/нед) −1,
      // VO₂max −3, пульс −1,5 → −11 → потолок −10.
      expect(sum, closeTo(-10, .051));
    });

    test('без Watch VO₂max не учитывается, остальные растягиваются ×8/7', () {
      final days = flat(90, vo2: null, z13Day: 15, z45Day: 3, strengthDay: 0);
      final r = computeBio(days, birth: birth);
      final vo2 = r.today[BioKey.vo2.index];
      expect(vo2.present, isFalse);
      expect(r.parts[BioKey.vo2.index], 0);
      // сон 0, режим −1, шаги −1,5, зоны 1–3 105/нед → 0, 4–5 21/нед → 0,
      // силовые 0 → +0,5, пульс −1,5 → −3,5 × 8/7 = −4.
      expect(r.parts[BioKey.steps.index], closeTo(-1.5 * 8 / 7, .051));
      final sum = r.parts.fold<double>(0, (a, b) => a + b) + r.smooth;
      expect(sum, closeTo(-4, .051));
    });

    test('меньше 5 вкладов — числа нет', () {
      final n = bioScaled([
        const BioPart(BioKey.sleep, '', 0),
        const BioPart(BioKey.steps, '', -1.5),
        const BioPart(BioKey.rhr, '', -1.5),
        const BioPart(BioKey.vo2, '', null),
      ]);
      expect(n, isNull);
    });

    test('число меняется не больше чем на 0,1 года в день (EMA)', () {
      final good = flat(60, end: DateTime(2026, 9, 1));
      final bad = flat(
        60,
        end: DateTime(2026, 10, 31),
        sleep: 330,
        steps: 2000,
        rhr: 70,
      );
      final r = computeBio([...good, ...bad], birth: birth);
      final h = r.history.whereType<double>().toList();
      for (var i = 1; i < h.length; i++) {
        // + рост календарного возраста за день.
        expect((h[i] - h[i - 1]).abs(), lessThanOrEqualTo(.1 + 1 / 365 + 1e-9));
      }
    });

    test('3 недели сна < 6 ч — биовозраст растёт', () {
      final base = flat(60, end: DateTime(2026, 9, 24));
      final r0 = computeBio(base, birth: birth);
      final short = flat(21, end: DateTime(2026, 10, 15), sleep: 320);
      final r1 = computeBio([...base, ...short], birth: birth);
      expect(r1.bio! - r1.age!, greaterThan(r0.bio! - r0.age!));
    });

    test('калибровка при < 14 днях с браслетом: «6/14»', () {
      final days = [
        for (final d in flat(30))
          d.day.isBefore(DateTime(2026, 10, 10)) ? BioDay(d.day) : d,
      ];
      final r = computeBio(days, birth: birth);
      expect(r.state, BioState.calibrating);
      expect(r.have, 6);
      expect(r.bio, isNull);
    });

    test('13 дней — ещё калибровка, 14 — число', () {
      expect(computeBio(flat(13), birth: birth).state, BioState.calibrating);
      expect(computeBio(flat(14), birth: birth).state, BioState.ready);
    });

    test('без даты рождения — «укажите дату рождения»', () {
      final r = computeBio(flat(40));
      expect(r.state, BioState.noProfile);
    });

    test('возраст берётся из даты рождения, не числом', () {
      // VO₂max 43: для 37 лет p50–75 (−1,5), для 47 лет ≥ p75 (−3).
      final a = computeBio(flat(40, vo2: 43, steps: 6000), birth: DateTime(1989, 3, 21));
      final b = computeBio(flat(40, vo2: 43, steps: 6000), birth: DateTime(1979, 3, 21));
      expect(b.age! - a.age!, closeTo(10, .01));
      expect(a.delta, closeTo(-8, .051));
      expect(b.delta, closeTo(-9.5, .051));
    });

    test('округлённые вклады складываются ровно в округлённую сумму', () {
      final xs = [-.34, -.33, -.33, 1.26, .07, -2.81, .015, .044];
      final r = roundTenthsKeepingSum(xs);
      final sum = xs.fold<double>(0, (a, b) => a + b);
      expect(
        (r.fold<double>(0, (a, b) => a + b) * 10).round(),
        (sum * 10).round(),
      );
    });

    test('подписи', () {
      expect(bioDeltaText(-2.8), 'на 2,8 года моложе');
      expect(bioDeltaText(1.1), 'на 1,1 года старше');
      expect(bioDeltaText(-3), 'на 3 года моложе');
      expect(bioDeltaText(-5), 'на 5 лет моложе');
      expect(bioDeltaText(0.02), 'как по паспорту');
      expect(bioPartText(-.6), '−0,6 года');
      expect(bioPartText(0), '0');
      expect(bioPartText(1), '+1 год');
      expect(bioZone(-1), -1);
      expect(bioZone(-.9), 0);
      expect(bioZone(1), 1);
    });
  });

  test('вклады + сглаживание = разница с паспортом при меняющейся жизни', () {
    final birth = DateTime(1989, 3, 21);
    final r = computeBio([
      ...flat(80, end: DateTime(2026, 9, 25)),
      ...flat(20, end: DateTime(2026, 10, 15), sleep: 360, steps: 6000),
    ], birth: birth);
    final sum = r.parts.fold<double>(0, (a, b) => a + b) + r.smooth;
    expect((sum * 10).round(), (r.delta! * 10).round());
    expect(r.smooth, isNot(0));
    // Строки — по таблице окна: сон 6 ч → +1,5.
    expect(r.parts[BioKey.sleep.index], closeTo(r.today[0].table!, .051));
  });

  group('Темп старения', () {
    test('ограничен [−1; 3]', () {
      // Аргументы — разница с паспортом сегодня и 28 дней назад.
      expect(paceOf(-3, -3), 1);
      expect(paceOf(-4, -3), -1); // −1 год за 28 дней → сильно меньше −1
      expect(paceOf(-2, -3), 3);
      expect(paceOf(-3 + 0.03, -3), closeTo(1 + .03 / (28 / 365), 1e-9));
    });
    test('медленнее / быстрее, чем неделю назад (порог 0,1x)', () {
      expect(paceTrend(.4, .6), -1);
      expect(paceTrend(.8, .6), 1);
      expect(paceTrend(.65, .6), 0);
      expect(paceTrend(null, .6), 0);
    });
    test('в истории темп всегда в [−1; 3]; ровная жизнь → ≈ 1,0x', () {
      final birth = DateTime(1989, 3, 21);
      final r = computeBio(flat(120), birth: birth);
      expect(r.pace, isNotNull);
      expect(r.pace!, inInclusiveRange(-1, 3));
      expect(r.pace!, closeTo(1, .05));
      final worse = computeBio([
        ...flat(80, end: DateTime(2026, 9, 5)),
        ...flat(40, end: DateTime(2026, 10, 15), sleep: 300, steps: 2000),
      ], birth: birth);
      expect(worse.pace, 3);
      expect(paceText(.6), '0,6x');
      expect(paceText(-1), '−1,0x');
    });
  });

  group('Кардиоформа §10.8 — итоговое слово', () {
    test('«Растёт»: ↑↑ или ↑ и =', () {
      expect(cardioVerdict([1, 1, null]), 'Растёт');
      expect(cardioVerdict([1, 0, null]), 'Растёт');
      expect(cardioVerdict([1, 0, 0]), 'Растёт');
    });
    test('«Снижается»: ↓ хотя бы по двум', () {
      expect(cardioVerdict([-1, -1, null]), 'Снижается');
      expect(cardioVerdict([-1, 1, -1]), 'Снижается');
    });
    test('«Стабильна»: остальное', () {
      expect(cardioVerdict([0, 0, null]), 'Стабильна');
      expect(cardioVerdict([1, -1, null]), 'Стабильна');
      expect(cardioVerdict([-1, 0, 0]), 'Стабильна');
    });
    test('калибровка (< 14 дней) — слова нет', () {
      expect(cardioVerdict([null, null, null]), isNull);
      final t = cardioHrv(List.filled(13, 50.0));
      expect(t.form, isNull);
    });
    test('неделя перетренировки — «Снижается» по рядам', () {
      final hrv = [...List.filled(23, 55.0), ...List.filled(7, 42.0)];
      final rhr = [...List.filled(23, 50.0), ...List.filled(7, 56.0)];
      expect(
        cardioVerdict([cardioHrv(hrv).form, cardioRhr(rhr).form]),
        'Снижается',
      );
    });
    test('дельта — из тех же округлённых чисел, что на плитке (хвост B3 е)', () {
      // 49,4 за неделю и 49,8 за месяц на плитке «49» и «50» → «−1», не «−0,4».
      expect(deltaShown(49 - 50), '↓ −1 к месяцу');
      expect(deltaShown(0), 'как месяц назад');
      expect(deltaToMonth1(.6), '↑ +0,6 к месяцу');
      final t = cardioRhr([...List.filled(23, 52.0), ...List.filled(7, 52.4)]);
      expect(t.delta, 'как месяц назад');
    });
  });

  group('Хвосты B3', () {
    test('(в) отбой от потребности сна с учётом бодрствования ≈ 22:50', () {
      final awake = awakeForNeed(489, 94);
      expect(awake, 31);
      expect(
        clock(ritmBedtime(wakeMinOfDay: 450, needMin: 489, awakeMin: awake)!),
        '22:50',
      );
    });

    test('(г) нагрузка: бег 46 мин при 145 выше велосипеда 47 мин легче', () {
      const prof = Profile(ageYears: 37, sex: 'm', weightKg: 78, heightCm: 180);
      double s(List<double> hr) => strainFromPerMinuteHr(
        hr,
        profile: prof,
        restingHr: 51,
        hrMax: 182,
        quietHrr: .2,
      )!;
      final run = s(List.filled(46, 145.0));
      final bike = s(List.filled(47, 122.0));
      // Та же длительность, выше пульс — нагрузка выше.
      expect(run, greaterThan(bike));
      expect(s(List.filled(46, 145.0)), greaterThan(s(List.filled(46, 135.0))));
      // ignore: avoid_print
      print('нагрузка: бег 46 мин @145 = ${dec1(run)}, велосипед 47 мин @122 = ${dec1(bike)}');
    });

    test('(е) ЭКГ: неясная запись — «Запись неясная — повторите», серая', () {
      final w = watchEcgText('inconclusiveOther', null);
      expect(w.text, 'Запись неясная — повторите');
      expect(ecgUnclear(w.text), isTrue);
      expect(ecgUnclear(bandEcgText('unreadable', null).text), isTrue);
      expect(ecgUnclear('Синусовый ритм · 62'), isFalse);
    });

    test('(а) плитка: «Пульс покоя 55 ↑»', () {
      final hist = [for (var i = 0; i < 30; i++) 52.0 + (i % 3) - 1];
      final r = monitorRow(MonKind.rhr, history: hist, last: 55, prev: 53);
      final text = monitorTileText([r]);
      expect(text, startsWith('Пульс покоя 55'));
    });

    test('зоны пульса тренировки: минуты по доле резерва (§7.3)', () {
      final t0 = DateTime(2026, 10, 15, 7, 40);
      final s = [
        for (var i = 0; i < 120; i++)
          (t0.add(Duration(seconds: 5 * i)), i < 60 ? 120.0 : 150.0),
      ];
      final m = zoneMinutes(s, 180, 60);
      // резерв 120: (120−60)/120 = 50 % → зона 1; (150−60)/120 = 75 % → зона 3; по 5 мин.
      expect(m, [5, 0, 5, 0, 0]);
      expect(hrZone(170, 180, 60), 5); // 92 %
      expect(hrZone(107, 180, 60), 0); // 39 %
      expect(zoneHr(0, 180, 60), 108);
      expect(workoutHrMax(age: 37), 182);
      expect(workoutHrMax(profileMax: 190, age: 37), 190);
    });
  });

  group('Облачко', () {
    Widget orb(MediaQueryData q) => MediaQuery(
      data: q,
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: RitmOrb(color: Color(0xFF35D07F))),
      ),
    );

    testWidgets('обычно — тикер крутится; «Уменьшение движения» — стоит',
        (t) async {
      ritmOrbStillInTests = false;
      addTearDown(() {
        ritmOrbStillInTests = true;
        ritmReduceMotion = () => false;
      });
      ritmReduceMotion = () => false;
      await t.pumpWidget(orb(const MediaQueryData(size: Size(393, 852))));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.hasRunningAnimations, isTrue);
      // Android / тесты: disableAnimations.
      await t.pumpWidget(
        orb(const MediaQueryData(size: Size(393, 852), disableAnimations: true)),
      );
      await t.pump(const Duration(milliseconds: 100));
      expect(t.hasRunningAnimations, isFalse);
      // iOS: «Уменьшение движения» приходит как reduceMotion.
      ritmReduceMotion = () => true;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(orb(const MediaQueryData(size: Size(393, 852))));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.hasRunningAnimations, isFalse);
      expect(find.byType(RitmOrb), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('герой: число, «БИОВОЗРАСТ · ОЦЕНКА», разница', (t) async {
      final r = computeBio(
        [
          ...List.generate(
            90,
            (i) => BioDay(
              DateTime(2026, 7, 18).add(Duration(days: i)),
              sleepMin: 450,
              onsetMin: 23 * 60 + (i.isEven ? 50.0 : -50.0),
              wakeMin: 7 * 60 + (i.isEven ? 50.0 : -50.0),
              steps: 7000,
              z13: 15,
              z45: 5,
              strength: 8,
              rhr: 52,
              vo2: 46.2,
            ),
          ),
        ],
        birth: DateTime(1989, 3, 21),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [BioHero(r: r), PaceCard(r: r, onMore: () {})],
              ),
            ),
          ),
        ),
      );
      expect(find.text('БИОВОЗРАСТ · ОЦЕНКА'), findsOneWidget);
      expect(find.textContaining('моложе'), findsOneWidget);
      expect(find.text('ТЕМП СТАРЕНИЯ'), findsOneWidget);
      // Ни одной латинской буквы в подписях (кроме «x» темпа).
      final latin = RegExp(r'[A-Za-wyz]');
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        final s = w.data ?? '';
        expect(latin.hasMatch(s), isFalse, reason: s);
      }
    });

    testWidgets('калибровка: «—» и «нужно 14 дней · 6/14»', (t) async {
      const r = BioResult(state: BioState.calibrating, have: 6);
      await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: BioHero(r: r))),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.text('нужно 14 дней · 6/14'), findsOneWidget);
    });
  });

  test('демо-шкала шагов: браслет и Watch в пределах 5 % (хвост B3 б)', () {
    const band = 10520, watch = 10860;
    expect((watch - band).abs() / watch, lessThan(.05));
    // Шаги ≈ дистанции: бег 7,24 км (шаг ≈ 0,95 м) + ходьба 27 мин.
    final est = 7240 / .95 + 27 * 105;
    expect((watch - est).abs() / watch, lessThan(.06));
    expect(math.max(band, watch), lessThan(12000));
  });
}
