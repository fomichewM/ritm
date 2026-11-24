// «Ритм» FIX84 — сценарии РЕАЛЬНОГО расчёта для проверки и скриншотов.
//
// В отличие от демо (ritm_demo.dart — готовые числа), здесь главная строится
// теми же функциями, что на телефоне: пакет дня Edge → [ringInputsFromBundle]
// → [RitmRingsStore.dayResult] (+ засев нормы из CSV WHOOP / «Здоровья»).
//
// День — воспроизведение 16.10 у автора (скрин feedback/final84_home_2334.jpg):
// сон 5:47 (00:41–06:46), ношение 23 ч 16 мин (не носился 0:18), «тренировки»
// 16:07–16:29 (пульс ≈ 91) и 21:02–21:23, Edge без нормы отдаёт потребность =
// сну (need_min 347) и readiness «need_baseline: have=1, need=14».
//
// Сценарии (только DEBUG + RITM_DEMO=true, --dart-define=RITM_SCENARIO=…):
//   new        — новый пользователь: 1 прошлая ночь браслета, «Здоровье» пусто;
//   csv        — то же + импорт physiological_cycles.csv (путь RITM_SCENARIO_CSV);
//   health365  — то же + история «Здоровья» симулятора (365 ночей, засев Swift).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/metric.dart';
import '../ui2/screens/health_screen.dart' show HealthData;
import '../ui2/screens/home_screen.dart' show HomeData;
import 'ritm_demo.dart' show kRitmDemo;
import 'ritm_history.dart' show RitmHealthHistory;
import 'ritm_hk.dart' show wkMeanOk;
import 'ritm_home.dart' show RitmHomeSnapshot, RitmSuggestion;
import 'ritm_rings.dart' show TV;
import 'ritm_rings_store.dart';
import 'ritm_seed.dart';
import 'ritm_watch_store.dart' show RitmHealthKitChannel;
import 'ritm_whoop_csv.dart' show dayId;

const String kRitmScenarioName = String.fromEnvironment('RITM_SCENARIO');
const String _kCsv = String.fromEnvironment('RITM_SCENARIO_CSV');

/// Сценарий включён (только DEBUG + RITM_DEMO + RITM_SCENARIO).
bool get kRitmScenario => kRitmDemo && kRitmScenarioName.isNotEmpty;

/// Снимок главной «сегодня» по реальному расчёту (null — ещё готовится).
RitmHomeSnapshot? ritmScenarioSnap;

/// Сколько раз пересобран снимок (главная слушает и перечитывает).
final ritmScenarioRev = ValueNotifier<int>(0);

/// «Сейчас» сценария — 23:34, как на скрине автора.
DateTime ritmScenarioNow([DateTime? base]) {
  final n = base ?? DateTime.now();
  return DateTime(n.year, n.month, n.day, 23, 34);
}

/// Пакет дня Edge (sleep / heart / hrv), как отдают getDaySleep / getDayHeart /
/// getDayHrv. [today] — полночь дня; [upTo] — до какого момента есть пульс.
/// [onsetMin]/[wakeMin] — минуты от полуночи; [tstMin] — минут сна.
({Map<String, dynamic> sleep, Map<String, dynamic> heart, Map<String, dynamic> hrv}) fix84Day(
  DateTime today, {
  DateTime? upTo,
  int onsetMin = 41,
  int wakeMin = 6 * 60 + 46,
  int tstMin = 347,
  int seed = 1610,
  bool workouts = true,
  double rhr = 52,
  double rmssd = 47,
}) {
  final rnd = math.Random(seed);
  double g(double sd) {
    // Гаусс Бокса — Мюллера (детерминированно по seed).
    final u1 = math.max(1e-9, rnd.nextDouble()), u2 = rnd.nextDouble();
    return sd * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  final t0 = today.millisecondsSinceEpoch ~/ 1000;
  int at(int m) => t0 + m * 60;
  final end = upTo == null ? t0 + 86400 : math.min(t0 + 86400, upTo.millisecondsSinceEpoch ~/ 1000);

  // Гипнограмма: циклы ≈ 90 мин, бодрствование распределено так, чтобы сна
  // было ровно [tstMin] минут в окне [onset, wake].
  final inBed = wakeMin - onsetMin;
  final awake = math.max(0, inBed - tstMin);
  final hyp = <Map<String, dynamic>>[];
  var m = onsetMin;
  var awakeLeft = awake;
  var cycle = 0;
  while (m < wakeMin) {
    final parts = <(String, int)>[
      ('light', 25),
      ('deep', cycle < 2 ? 30 : 12),
      ('light', 15),
      ('rem', cycle < 2 ? 12 : 25),
    ];
    for (final p in parts) {
      if (m >= wakeMin) break;
      final len = math.min(p.$2, wakeMin - m);
      hyp.add({'t': at(m), 'stage': p.$1});
      m += len;
    }
    if (m < wakeMin && awakeLeft > 0) {
      final w = math.min(awakeLeft, math.min(8, wakeMin - m));
      hyp.add({'t': at(m), 'stage': 'wake'});
      m += w;
      awakeLeft -= w;
    }
    cycle++;
  }
  hyp.add({'t': at(wakeMin), 'stage': 'wake'});
  // Сколько сна вышло (до коррекции округлений).
  var asleep = 0, deep = 0, rem = 0, light = 0, wk = 0;
  for (var i = 0; i + 1 < hyp.length; i++) {
    final d = ((hyp[i + 1]['t'] as int) - (hyp[i]['t'] as int)) ~/ 60;
    switch (hyp[i]['stage']) {
      case 'deep':
        deep += d;
        asleep += d;
      case 'rem':
        rem += d;
        asleep += d;
      case 'light':
        light += d;
        asleep += d;
      default:
        wk += d;
    }
  }
  String stageAt(int t) {
    var s = 'wake';
    for (final p in hyp) {
      if ((p['t'] as int) > t) break;
      s = p['stage'] as String;
    }
    return t >= at(wakeMin) || t < at(onsetMin) ? 'out' : s;
  }

  // Пульс по минутам: сон ≈ rhr, день 70–76 с короткими прогулками, две
  // «тренировки» на пульсе ≈ 91–96, не носился 22:20–22:38.
  final hr = <Map<String, dynamic>>[];
  var walk = 0;
  for (var t = t0; t < end; t += 60) {
    final mm = (t - t0) ~/ 60;
    if (mm >= 22 * 60 + 20 && mm < 22 * 60 + 38) continue;
    final st = stageAt(t);
    double v;
    if (st != 'out') {
      v = switch (st) {
        'deep' => rhr - 3 + g(1.5),
        'rem' => rhr + 3 + g(2.5),
        'wake' => rhr + 9 + g(4),
        _ => rhr + g(2),
      };
    } else if (workouts && mm >= 16 * 60 + 7 && mm < 16 * 60 + 29) {
      v = 91 + g(7);
    } else if (workouts && mm >= 21 * 60 + 2 && mm < 21 * 60 + 23) {
      v = 96 + g(8);
    } else {
      if (walk == 0 && rnd.nextDouble() < 0.008) walk = 5 + rnd.nextInt(10);
      v = walk > 0 ? 98 + g(8) : 70 + g(5);
      if (walk > 0) walk--;
    }
    hr.add({'t': t, 'v': double.parse(v.clamp(38, 190).toStringAsFixed(1))});
  }
  // ВСР: 5-мин окна во сне (t — конец окна); в глубоком выше.
  final hrv = <Map<String, dynamic>>[];
  for (var t = at(onsetMin) + 300; t <= at(wakeMin); t += 300) {
    final st = stageAt(t - 150);
    if (st == 'wake' || st == 'out') continue;
    final v = st == 'deep' ? rmssd + 8 + g(5) : rmssd + g(6);
    hrv.add({'t': t, 'v': double.parse(math.max(12, v).toStringAsFixed(1))});
  }
  return (
    sleep: {
      'hypnogram': hyp,
      'duration_min': asleep,
      // Edge без нормы: потребность = сну (так на телефоне «5:47 из 5:47»).
      'need_min': asleep,
      'efficiency': asleep / math.max(1, inBed),
      'onset_ts': at(onsetMin),
      'wake_ts': at(wakeMin),
      'light_min': light,
      'deep_min': deep,
      'rem_min': rem,
      'awake_min': wk,
      'resp': {'value': 14.6},
    },
    heart: {'hr': hr, 'resting_hr': rhr},
    hrv: {'timeline': hrv},
  );
}

/// Кольца дня [today] по сценарию: [prevNights] прошлых ночей браслета + сегодня.
RingDayInputs fix84Inputs(DateTime today, {DateTime? upTo, int back = 0, int age = 37, double? observed90}) {
  final d = DateTime(today.year, today.month, today.day - back);
  final b = back == 0
      ? fix84Day(d, upTo: upTo)
      : fix84Day(d, onsetMin: 30 + back * 7, wakeMin: 6 * 60 + 50 + back * 5, tstMin: 395, seed: 1600 + back);
  return ringInputsFromBundle(day: dayId(d), sleep: b.sleep, heart: b.heart, hrv: b.hrv, age: age, observed90: observed90);
}

/// Edge-часть главной для дня сценария (как на телефоне без нормы).
HomeData fix84HomeData(DateTime today, RingDayInputs x) => HomeData(
  name: 'Михаил',
  dayId: dayId(today),
  readiness: const Metric(note: 'need_baseline:have=1,need=14'),
  sleepMin: Metric(value: x.night.tstMin, unit: 'min', confidence: .9, tier: MetricTier.high),
  sleepNeedMin: Metric(value: x.night.tstMin, unit: 'min', confidence: .9, tier: MetricTier.high),
  rhr: Metric(value: x.night.rhrSleepMean ?? 52, confidence: .9, tier: MetricTier.high),
  steps: const Metric(value: 7420, confidence: .9, tier: MetricTier.high),
  strain: Metric(value: x.strain?.strain ?? 0, confidence: .9, tier: MetricTier.high),
);

/// Пересобрать снимок сценария (DEBUG). health365 — сперва засев «Здоровья»
/// симулятора и забор истории тем же кодом, что на телефоне.
Future<void> prepareRitmScenario() => _prepared ??= _prepare();
Future<void>? _prepared;

Future<void> _prepare() async {
  if (!kRitmScenario) return;
  final now = ritmScenarioNow();
  final today = DateTime(now.year, now.month, now.day);
  var seed = const RitmSeed();
  switch (kRitmScenarioName) {
    case 'csv':
      try {
        seed = RitmSeed(whoop: parseWhoopCycles(await File(_kCsv).readAsString()));
      } catch (e) {
        debugPrint('[ritm] scenario csv: $e');
      }
    case 'watch365':
      // Apple Watch в «Здоровье»: пульс покоя, ВСР (SDNN), дыхание, сон —
      // точки отдаются в чтение истории (слияние, засев, кольца — как на
      // телефоне; запись ВСР в «Здоровье» симулятора требует окна iOS).
      RitmHealthHistory.debugRead = (a, b) async => [
        for (var i = 0; i <= 365; i++)
          if (DateTime(today.year, today.month, today.day - i, 7) case final d
              when !d.isBefore(a) && d.isBefore(b)) ...[
            (kind: 'rhr', v: 55.0 + 2 * math.sin(i / 9) + ((i * 37) % 5 - 2) * .6, from: d, to: d, src: 'watch'),
            (kind: 'sdnn', v: 42.0 + 6 * math.cos(i / 7) + ((i * 13) % 7 - 3), from: d.subtract(const Duration(hours: 3)), to: d.subtract(const Duration(hours: 3)), src: 'watch'),
            (kind: 'resp', v: 15.0 + (i % 3) * .2, from: d.subtract(const Duration(hours: 2)), to: d.subtract(const Duration(hours: 2)), src: 'watch'),
            if (i > 0)
              (kind: 'sleep', v: 0.0, from: d.subtract(Duration(hours: 7, minutes: 20 - i % 5 * 4)), to: d.subtract(Duration(minutes: 15 - i % 7 * 5)), src: 'watch'),
          ],
      ];
      await RitmHealthHistory.sync(force: true, now: now);
      RitmHealthHistory.debugRead = null;
      seed = RitmSeed.cached;
    case 'health365':
      final r = await RitmHealthKitChannel.debugSeedHistory(now: now, nights: 365);
      debugPrint('[ritm] scenario hk seed: $r');
      await RitmHealthHistory.sync(force: true, now: now);
      seed = RitmSeed.cached;
  }
  await RitmSeed.save(seed);
  RitmRingsStore.seedSource = () => seed;
  // HRmax — как в RitmRingsStore.ensure: максимум за год из истории WHOOP (CSV).
  final obs = seed.hrMaxYear(now);
  RitmRingsStore.debugSeed([
    fix84Inputs(today, back: 1, observed90: obs),
    fix84Inputs(today, upTo: now, observed90: obs),
  ]);
  final rings = RitmRingsStore.dayResult(dayId(today));
  final x = rings!.inputs;
  final y = fix84Inputs(today, back: 1, observed90: obs);
  // Монитор здоровья — та же модель, что на телефоне: ряды браслета (2 ночи)
  // + засев (CSV / «Здоровье»).
  int ts(DateTime d) => DateTime(d.year, d.month, d.day, 7).millisecondsSinceEpoch ~/ 1000;
  final yd = today.subtract(const Duration(days: 1));
  final health = HealthData(
    today: {
      'daily': {
        'resting_hr': {'value': x.night.rhrSleepMean, 'confidence': .9, 'tier': 'high'},
      },
      'hrv': {'rmssd': x.night.rmssdSwsLast, 'confidence': .9, 'tier': 'high'},
      'resp': {'value': x.resp, 'confidence': .9, 'tier': 'high'},
    },
    charts: {
      'resting_hr': [(t: ts(yd), v: y.night.rhrSleepMean!), (t: ts(today), v: x.night.rhrSleepMean!)],
      'hrv': [(t: ts(yd), v: y.night.rmssdSwsLast!), (t: ts(today), v: x.night.rmssdSwsLast!)],
      'resp_rate': [(t: ts(yd), v: y.resp!), (t: ts(today), v: x.resp!)],
    },
    daysWithData: 2,
  );
  ritmScenarioSnap = RitmHomeSnapshot(
    d: fix84HomeData(today, x),
    days: [dayId(today), dayId(today.subtract(const Duration(days: 1)))],
    battery: (pct: 82, charging: false),
    rings: rings,
    health: health,
    effPct: x.eff?.round(),
    dataEdge: now.subtract(const Duration(minutes: 3)),
    // Edge-находка 16:07–16:29 со средним 91 — главная её больше не показывает
    // (порог среднего пульса тренировки, FIX84); 21:02–21:23 тоже.
    suggestions: [
      for (final s in [
        RitmSuggestion(
          start: today.add(const Duration(hours: 16, minutes: 7)),
          end: today.add(const Duration(hours: 16, minutes: 29)),
          avgHr: 91,
        ),
        RitmSuggestion(
          start: today.add(const Duration(hours: 21, minutes: 2)),
          end: today.add(const Duration(hours: 21, minutes: 23)),
          avgHr: 96,
        ),
      ])
        if (wkMeanOk(s.avgHr, rhr: x.night.rhrSleepMean ?? 52, hrMax: x.hrMax ?? 182)) s,
    ],
  );
  ritmScenarioRev.value++;
  debugPrint('[ritm] scenario $kRitmScenarioName: rec=${rings.recovery.value} '
      'why=${rings.recovery.why} nights=${rings.recovery.nights} strain=${x.strain?.strain} '
      'seed=${seed.hkNights}/${seed.whoop.length} src=${rings.recSeedSrc} hrMax=${x.hrMax}');
}

/// Тестам: пульс дня как ряд [TV].
List<TV> fix84HrSeries(Map<String, dynamic> heart) => TV.parse(heart['hr']);
