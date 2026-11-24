// «Ритм» FIX84 — дефекты 0.17.0 (84) на телефоне автора (16.10 23:34):
//  1) «Сон 5:47 из 5:47 — не хватило 0:00. Сегодня лучше лечь в 20:02»;
//  2) кольцо Восстановления «1/4», текст «1 из 14 ночей»;
//  3) Нагрузка 19,6 «Предельная» за обычный день, «тренировка» на пульсе 91;
//  4) засев нормы: CSV WHOOP и история «Здоровья» → Восстановление с 1-й ночи.
// День 16.10 воспроизведён пакетами Edge (lib/ritm/ritm_scenario.dart) и
// прогоняется ТЕМИ ЖЕ функциями, что на телефоне.
//
// Реальный CSV автора: FIX84_WHOOP_CSV=<…/physiological_cycles.csv> (вне
// репозитория — личные данные); без него — фикстура ritm_compare.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ritm/ritm_ai.dart' show ritmTonightPlan;
import 'package:openstrap_edge/ritm/ritm_history.dart';
import 'package:openstrap_edge/ritm/ritm_hk.dart';
import 'package:openstrap_edge/ritm/ritm_home.dart';
import 'package:openstrap_edge/ritm/ritm_rings.dart';
import 'package:openstrap_edge/ritm/ritm_rings_store.dart';
import 'package:openstrap_edge/ritm/ritm_scenario.dart';
import 'package:openstrap_edge/ritm/ritm_scores.dart';
import 'package:openstrap_edge/ritm/ritm_seed.dart';
import 'package:openstrap_edge/ritm/ritm_sleep.dart';
import 'package:openstrap_edge/ritm/ritm_whoop_csv.dart' show dayId;
import 'package:openstrap_edge/ui2/theme.dart' show buildTheme;

final _today = DateTime(2026, 10, 16);
final _now = DateTime(2026, 10, 16, 23, 34);

/// Вес минуты в 0.17.0 (84): вес тренировки на каждой минуте дня.
double _oldWeight(double v) {
  final x = v.clamp(0.0, 1.1);
  return kRingTheta.strainC * (math.exp(kRingTheta.strainK * x) - 1);
}

String _csvText() {
  final env = Platform.environment['FIX84_WHOOP_CSV'];
  if (env != null && File(env).existsSync()) return File(env).readAsStringSync();
  return File('test/fixtures/ritm_compare/physiological_cycles.csv').readAsStringSync();
}

/// Две ночи браслета (вчера и сегодня), как у автора на телефоне.
List<RingDayInputs> _bandDays() => [fix84Inputs(_today, back: 1), fix84Inputs(_today, upTo: _now)];

RitmRingsDay _rings(RitmSeed seed) {
  RitmRingsStore.seedSource = () => seed;
  RitmRingsStore.debugSeed(_bandDays());
  return RitmRingsStore.dayResult(dayId(_today))!;
}

void main() {
  tearDown(() => RitmRingsStore.seedSource = () => RitmSeed.cached);

  group('3) Нагрузка дня', () {
    test('день 16.10: было «Предельная» (> 15), стало как у WHOOP (медиана 8,4)', () {
      final b = fix84Day(_today, upTo: _now);
      final hr = fix84HrSeries(b.heart);
      // Ношение 23 ч 16 мин (как на телефоне): 23:34 минус 18 мин без браслета.
      expect(hr.length, inInclusiveRange(1390, 1400));
      final x = fix84Inputs(_today, upTo: _now);
      final rhr = x.rhrForStrain!;
      // Старое правило: HRmax = максимум спокойного дня (> 120) и вес тренировки
      // на каждой минуте.
      final dayMax = hr.map((p) => p.v).reduce(math.max);
      final oldHrMax = dayMax > 120 ? dayMax : 208 - 0.7 * 37;
      var oldLoad = 0.0;
      for (final p in hr) {
        oldLoad += _oldWeight((p.v - rhr) / math.max(20.0, oldHrMax - rhr));
      }
      final oldStrain = strainScale(oldLoad, kRingTheta);
      expect(oldStrain, greaterThan(15), reason: 'воспроизведение дефекта: $oldStrain');
      // Новое правило.
      final s = x.strain!.strain;
      expect(s, inInclusiveRange(5.0, 11.0), reason: 'нагрузка дня $s');
      expect(strainWord(s), isNot('Предельная'));
      // HRmax — по возрасту (37 → 182), а не максимум спокойного дня.
      expect(x.hrMax, closeTo(182.1, 0.1));
    });

    test('вес минуты: остаток дня B·v^g, тренировка — экспонента, склейка непрерывна', () {
      expect(strainWeight(0, kRingTheta), 0);
      expect(strainWeight(0.2, kRingTheta), closeTo(kRestB * math.pow(0.2, kRestG), 1e-9));
      expect(strainWeight(0.7, kRingTheta), closeTo(_oldWeight(0.7), 1e-9));
      for (var v = 0.30; v <= 0.55; v += 0.005) {
        expect((strainWeight(v + 0.005, kRingTheta) - strainWeight(v, kRingTheta)).abs(), lessThan(0.05));
        expect(strainWeight(v + 0.005, kRingTheta), greaterThanOrEqualTo(strainWeight(v, kRingTheta)));
      }
    });

    test('HRmax: максимум спокойного дня ниже возрастного — не HRmax', () {
      expect(hrMaxFor(observed90: 125, age: 37), closeTo(182.1, 0.01));
      expect(hrMaxFor(observed90: 191, age: 37), 191);
      expect(hrMaxFor(observed90: 260, age: 37), closeTo(182.1, 0.01));
      expect(hrMaxFor(profile: 175, observed90: 191, age: 37), 175);
    });

    test('«тренировка» на среднем пульсе 91 — не тренировка, 120 — тренировка', () {
      // автор: пульс покоя ≈ 50, HRmax по возрасту 182.
      expect(wkMeanOk(91, rhr: 50, hrMax: 182), isFalse);
      expect(wkMeanOk(96, rhr: 50, hrMax: 182), isFalse);
      expect(wkMeanOk(120, rhr: 50, hrMax: 182), isTrue);
      expect(wkMeanOk(null, rhr: 50, hrMax: 182), isTrue);
      // Классификатор по секундам: 22 мин на ~91 с движением — пусто.
      List<WkSec> secs(double hr, int minutes) => [
        for (var i = 0; i < minutes * 60; i += 2)
          WkSec(1000000 + i, hr: (hr + (i % 7) - 3).round(), cls: 2, cadence: 110),
      ];
      expect(detectWorkouts(secs(91, 22), rhr: 50, hrMax: 182), isEmpty);
      expect(detectWorkouts(secs(125, 25), rhr: 50, hrMax: 182), isNotEmpty);
    });
  });

  group('1) Сон и отбой', () {
    test('нет «5:47 из 5:47 — не хватило 0:00» и нет отбоя раньше 21:00', () {
      final r = _rings(const RitmSeed());
      expect(r.inputs.night.tstMin, 347);
      final need = r.need!.need;
      expect(need, greaterThanOrEqualTo(451), reason: 'потребность по базе ТЗ v3 + долг');
      final plan = ritmTonightPlan(r, _now)!;
      final bed = planBedtime(plan);
      expect(bed.hour * 60 + bed.minute, greaterThanOrEqualTo(21 * 60));
      // Подъём — обычный (≈ 06:46–06:55), а не «завтра в то же, что сегодня» в 05:xx.
      expect(plan.wake.hour, inInclusiveRange(6, 8));
      expect(plan.need, lessThanOrEqualTo(r.tonight!.base + r.tonight!.strainAdd + 60.5));
      final text = pulseText(PulseInput(
        sleepPct: 78,
        sleepMin: 347,
        needMin: need.round(),
        bedtimeMinOfDay: bed.hour * 60 + bed.minute,
        calibrating: (have: 1, need: kRecMinNights),
        hour: 23,
        minute: 34,
      ));
      expect(text, isNot(contains('из 5:47')));
      expect(text, isNot(contains('не хватило 0:00')));
      expect(text, contains('не хватило'));
      // 23:34 — отбой уже прошёл: не советуем «лечь в 21:xx».
      expect(text, contains('Ложитесь, как только сможете'));
      expect(text, isNot(contains('20:02')));
    });

    test('утром советуем время отбоя; без потребности — без «из X»', () {
      final morning = pulseText(const PulseInput(
        sleepPct: 78,
        sleepMin: 347,
        needMin: 520,
        bedtimeMinOfDay: 22 * 60 + 5,
        hour: 9,
      ));
      expect(morning, contains('Сегодня лучше лечь в 22:05'));
      final noNeed = pulseText(const PulseInput(sleepPct: 78, sleepMin: 347, hour: 9));
      expect(noNeed, isNot(contains(' из ')));
    });

    test('планировщик: долг гасится не за одну ночь, отбой не раньше 21:00', () {
      const r = (need: 660.0, debt: 180.0, base: 451.0, strainAdd: 30.0, napCredit: 0.0);
      expect(planNeedOf(r), 541);
      final p = (wake: DateTime(2026, 10, 17, 5, 30), alarm: false, need: 600, eff: 85, latency: 10);
      expect(planBedtime(p), DateTime(2026, 10, 16, 21));
    });
  });

  group('2) Восстановление: кольцо и текст — один источник', () {
    test('калибровка: 1 из 4 и в кольце, и в карточке', () {
      final r = _rings(const RitmSeed());
      expect(r.recovery.why, 'calibrating');
      expect(r.recovery.nights, 1);
      final text = pulseText(PulseInput(
        sleepPct: 78,
        sleepMin: 347,
        needMin: 520,
        calibrating: (have: r.recovery.nights, need: kRecMinNights),
        hour: 23,
        minute: 34,
      ));
      expect(text, contains('1 из 4 ночей'));
      expect(text, isNot(contains('14')));
    });
  });

  group('4) Засев нормы', () {
    test('CSV WHOOP (physiological_cycles.csv): Восстановление с первого дня', () {
      final nights = parseWhoopCycles(_csvText());
      expect(nights.length, greaterThanOrEqualTo(30));
      // Экспорт кончается раньше «сегодня» — берём день сразу после экспорта.
      final last = (nights.keys.toList()..sort()).last;
      final day = DateTime.parse(last).add(const Duration(days: 1));
      RitmRingsStore.seedSource = () => RitmSeed(whoop: nights);
      RitmRingsStore.debugSeed([fix84Inputs(day, upTo: day.add(const Duration(hours: 23, minutes: 34)))]);
      final r = RitmRingsStore.dayResult(dayId(day))!;
      expect(r.recovery.value, isNotNull, reason: 'why=${r.recovery.why}');
      expect(r.recovery.nights, 30);
      expect(r.recovery.preliminary, isFalse);
      expect(r.recSeedSrc, 'WHOOP');
      expect(r.recSeedVia, 'экспорт CSV');
      expect(r.norms['rhr'], isNotNull);
    });

    test('«Здоровье» 365 ночей (WHOOP: пульс покоя и дыхание, без ВСР) → цветное кольцо', () async {
      final pts = <HkPoint>[];
      for (var i = 0; i < 365; i++) {
        final d = _today.subtract(Duration(days: i));
        pts.add((kind: 'rhr', v: 50.0 + (i % 5) - 2, from: d.add(const Duration(hours: 9)), to: d.add(const Duration(hours: 9)), src: 'whoop'));
        pts.add((kind: 'resp', v: 14.5, from: d.add(const Duration(hours: 6)), to: d.add(const Duration(hours: 6)), src: 'whoop'));
        if (i > 0) {
          pts.add((kind: 'sleep', v: 0, from: d.subtract(const Duration(minutes: 20)), to: d.add(const Duration(hours: 6, minutes: 55)), src: 'whoop'));
        }
      }
      RitmHealthHistory.debugRead = (a, b) async => [for (final p in pts) if (!p.to.isBefore(a) && p.to.isBefore(b)) p];
      addTearDown(() => RitmHealthHistory.debugRead = null);
      await RitmSeed.save(const RitmSeed());
      expect(await RitmHealthHistory.sync(force: true, now: _now), isTrue);
      final seed = RitmSeed.cached;
      expect(seed.whoopHk.length, 365);
      expect(seed.sleep.length, greaterThanOrEqualTo(360));
      final r = _rings(seed);
      expect(r.recovery.value, isNotNull, reason: 'why=${r.recovery.why}');
      expect(r.recovery.why, isNull);
      // ВСР в норме пока только своя (1 ночь) — число «уточняется», но есть.
      expect(r.recovery.preliminary, isTrue);
      expect(r.recSeedSrc, 'WHOOP');
      expect(r.recSeedVia, '«Здоровье»');
      expect(r.recSeeded, greaterThanOrEqualTo(kRecSettledNights));
      expect(r.usualWake, inInclusiveRange(6 * 60 + 40, 7 * 60 + 5));
      // Повторное открытие через 5 мин — без нового чтения (не чаще раза в 30 мин).
      var reads = 0;
      RitmHealthHistory.debugRead = (a, b) async {
        reads++;
        return const [];
      };
      expect(await RitmHealthHistory.sync(now: _now.add(const Duration(minutes: 5))), isFalse);
      expect(reads, 0);
    });

    test('Apple Watch: ВСР SDNN «сам с собой» — полное Восстановление с первой ночи', () {
      final watch = <String, SeedNight>{};
      final sdnn = <String, double>{};
      for (var i = 0; i <= 60; i++) {
        final d = dayId(_today.subtract(Duration(days: i)));
        watch[d] = SeedNight(rhr: 55.0 + (i % 4) - 1.5);
        sdnn[d] = 40.0 + (i % 6) - 2.5;
      }
      final r = _rings(RitmSeed(watch: watch, watchSdnn: sdnn));
      expect(r.recovery.value, isNotNull, reason: 'why=${r.recovery.why}');
      expect(r.recovery.drivers.map((d) => d.key), contains('hrv'));
      expect(r.recSeedSrc, 'Apple Watch');
    });

    test('«Здоровье» пусто: честная калибровка без абсурдных советов', () {
      final r = _rings(const RitmSeed());
      expect(r.recovery.value, isNull);
      final bed = planBedtime(ritmTonightPlan(r, DateTime(2026, 10, 16, 9, 30))!);
      expect(bed.hour * 60 + bed.minute, greaterThanOrEqualTo(21 * 60));
    });

    test('mergeHealthPoints: источники и даты', () {
      final d = DateTime(2026, 10, 10, 7);
      final s = mergeHealthPoints(const RitmSeed(), [
        (kind: 'rhr', v: 48, from: d, to: d, src: 'whoop'),
        (kind: 'rhr', v: 54, from: d, to: d, src: 'watch'),
        (kind: 'sdnn', v: 42, from: d.subtract(const Duration(hours: 3)), to: d.subtract(const Duration(hours: 3)), src: 'watch'),
        (kind: 'sdnn', v: 99, from: d.add(const Duration(hours: 8)), to: d.add(const Duration(hours: 8)), src: 'watch'),
        (kind: 'rhr', v: 60, from: d, to: d, src: 'other'),
      ]);
      expect(s.whoopHk['2026-10-10']!.rhr, 48);
      expect(s.watch['2026-10-10']!.rhr, 54);
      expect(s.watchSdnn['2026-10-10'], 42); // дневной SDNN (15:00) не берём
      expect(hkSourceOf(sourceId: 'com.whoop.iphone', sourceName: 'WHOOP'), 'whoop');
      expect(hkSourceOf(sourceId: 'com.apple.health.X', sourceName: 'Apple Watch — автор', deviceModel: 'Watch'), 'watch');
      expect(nightDayOf(DateTime(2026, 10, 10, 6, 50)), '2026-10-10');
      expect(nightDayOf(DateTime(2026, 10, 10, 23, 50)), '2026-10-11');
      final back = RitmSeed.fromJson(s.toJson());
      expect(back.whoopHk['2026-10-10']!.rhr, 48);
    });
  });

  group('круг 1 судьи: честность чисел', () {
    test('вклады факторов в сумме = итог − «ночь как обычно»', () {
      final r = recoveryV3(
        rmssd: 40,
        rhr: 54,
        resp: 15.5,
        sleepPct: 76,
        rmssdHist: [for (var i = 0; i < 20; i++) 50.0 + i % 5],
        rhrHist: [for (var i = 0; i < 20; i++) 50.0 + i % 3],
        respHist: [for (var i = 0; i < 20; i++) 14.5 + (i % 3) * .2],
      );
      final base = 100 / (1 + math.exp(-kRingTheta.recB));
      final sum = r.drivers.fold<double>(0, (a, d) => a + d.points);
      expect(sum + base, closeTo(r.value!, 0.51));
    });

    test('норма из 1 ночи не показывается; дыхание WHOOP без общих ночей не засевается', () {
      final nights = parseWhoopCycles(_csvText());
      final keys = nights.keys.toList()..sort();
      final shifted = <String, SeedNight>{
        for (var i = 0; i < 40; i++) dayId(_today.subtract(Duration(days: 40 - i))): nights[keys[keys.length - 40 + i]]!,
      };
      final r = _rings(RitmSeed(whoop: shifted));
      // Пульс покоя/ВСР — с засева (≥ 4 ночей) → «обычно» есть.
      expect(r.norms['rhr'], isNotNull);
      // Дыхание: одна своя ночь, общих с WHOOP нет → нормы нет (не 16,5 WHOOP).
      expect(r.norms['resp'], isNull);
      expect(r.recovery.drivers.map((d) => d.key), isNot(contains('resp')));
      // Новый пользователь: «обычно» из одной прошлой ночи не выдумывается.
      final n = _rings(const RitmSeed());
      expect(n.norms['rhr'], isNull);
      expect(n.norms['hrv'], isNull);
    });

    test('засев Watch: на экране — значения и норма того ряда, с которым сравнивали', () {
      final watch = <String, SeedNight>{
        for (var i = 1; i <= 60; i++) dayId(_today.subtract(Duration(days: i))): SeedNight(rhr: 55.0 + (i % 4) - 1.5),
      };
      watch[dayId(_today)] = const SeedNight(rhr: 54);
      final r = _rings(RitmSeed(watch: watch));
      expect(r.recTonight['rhr'], 54);
      expect(r.norms['rhr'], closeTo(55, 0.6));
    });
  });

  group('круг 2 судьи', () {
    test('HRmax из истории WHOOP (CSV «Max HR») — второй по величине за год', () {
      final nights = parseWhoopCycles(_csvText());
      final last = DateTime.parse((nights.keys.toList()..sort()).last);
      final hy = RitmSeed(whoop: nights).hrMaxYear(last)!;
      expect(hy, inInclusiveRange(170, 205));
      // С ним Нагрузка дня ниже, чем с возрастным 182 (резерв шире).
      final a = fix84Inputs(_today, upTo: _now).strain!.strain;
      final b = fix84Inputs(_today, upTo: _now, observed90: hy).strain!.strain;
      if (hy > 182.1) expect(b, lessThan(a));
    });

    test('карточка называет два заметных фактора', () {
      final t = pulseText(const PulseInput(
        recovery: 51,
        sleepPct: 76,
        sleepMin: 347,
        needMin: 504,
        driver: 'hrv',
        driverSign: -10.2,
        driver2: 'rhr',
        driver2Sign: -7.9,
        hour: 23,
        minute: 34,
      ));
      expect(t, contains('вариабельность пульса'));
      expect(t, contains('Также пульс покоя выше нормы.'));
    });
  });

  group('главная по реальному расчёту', () {
    Future<void> pump(WidgetTester t, RitmHomeSnapshot s) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: RitmHomeScreen(snapshot: s, now: _now)),
      ));
      await t.pump(const Duration(milliseconds: 300));
    }

    RitmHomeSnapshot snap(RitmRingsDay r) => RitmHomeSnapshot(
      d: fix84HomeData(_today, r.inputs),
      days: [dayId(_today)],
      rings: r,
      effPct: r.inputs.eff?.round(),
    );

    testWidgets('новый пользователь: «1 из 4» в кольце и в тексте, без «20:02» и «из 5:47»', (t) async {
      await pump(t, snap(_rings(const RitmSeed())));
      expect(find.text('1/4'), findsOneWidget);
      expect(find.textContaining('1 из 4 ночей'), findsOneWidget);
      expect(find.textContaining('из 14'), findsNothing);
      expect(find.textContaining('5:47 из 5:47'), findsNothing);
      expect(find.textContaining('20:02'), findsNothing);
      expect(find.text('Предельная'), findsNothing);
    });

    testWidgets('после засева (CSV WHOOP): кольцо Восстановления с числом', (t) async {
      final nights = parseWhoopCycles(_csvText());
      // Перенесём ночи CSV на месяц перед «сегодня» (те же значения, свежие даты).
      final keys = nights.keys.toList()..sort();
      final shifted = <String, SeedNight>{
        for (var i = 0; i < 40; i++)
          dayId(_today.subtract(Duration(days: 40 - i))): nights[keys[keys.length - 40 + i]]!,
      };
      await pump(t, snap(_rings(RitmSeed(whoop: shifted))));
      expect(find.text('калибровка'), findsNothing);
      expect(find.textContaining('из 4 ночей'), findsNothing);
      expect(find.textContaining('%'), findsWidgets);
      expect(find.textContaining('норма — экспорт CSV'), findsOneWidget);
    });

    testWidgets('«Здоровье» 365 ночей WHOOP: кольцо сразу с числом, подпись «норма — «Здоровье»»', (t) async {
      final hk = <String, SeedNight>{
        for (var i = 1; i <= 365; i++) dayId(_today.subtract(Duration(days: i))): SeedNight(rhr: 50.0 + (i % 5) - 2, resp: 14.5),
      };
      final r = _rings(RitmSeed(whoopHk: hk));
      expect(r.recovery.value, isNotNull);
      await pump(t, snap(r));
      expect(find.text('калибровка'), findsNothing);
      expect(find.text('${r.recovery.value!.round()}%'), findsWidgets);
      expect(find.textContaining('норма — «Здоровье»'), findsOneWidget);
    });
  });
}
