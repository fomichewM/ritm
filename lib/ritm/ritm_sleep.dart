// «Ритм» B4¾ — движок сна (ТЗ v3 §7.4, SLEEP_AI §4).
//
// 1. Оценка сна v2: 4 составляющие (достаточность S, регулярность C,
//    эффективность E, ночной стресс X). Веса подобраны по экспорту WHOOP
//    Михаила (build/B4q_sleep_calibration.md): wS 0,494, wC 0,323, wE 0,15
//    (фикс.), wX 0,033 — на проверочной трети MAE 3,5 п.п., r 0,90.
//    Нет C (меньше 3 ночей) или X (нет стресс-индекса) — веса перенормируются.
// 2. Регулярность: SRI Phillips по окнам сна за 3 суток «полдень–полдень» →
//    C = 10,2 + 0,749·SRI (проверка: MAE 6,0, r 0,76).
// 3. Потребность/долг: та же форма, что в калибровке B4½ (kRingTheta).
// 4. «Сегодня ночью»: отбой = подъём − потребность·цель/эффективность − засыпание.
// 5. Пробуждения: непрерывное бодрствование ≥ 5 мин после засыпания.

import 'dart:math' as math;

import 'ritm_rings.dart' show TV;

/// Веса оценки сна (калибровка 15.10.2026 по 361 ночи WHOOP).
class SleepTheta {
  final double wS, wC, wE, wX;
  final double consA, consB;
  final String calibratedAt;
  const SleepTheta({
    this.wS = .494,
    this.wC = .323,
    this.wE = .15,
    this.wX = .033,
    this.consA = 10.2,
    this.consB = .749,
    this.needBase = 451,
    this.needKs = 1.52,
    this.debtD = .58,
    this.debtG = .511,
    this.debtCap = 180,
    this.calibratedAt = '2026-10-16',
  });

  /// Потребность/долг (§7.4.2): база, мин/балл Нагрузки, затухание и усиление долга.
  final double needBase, needKs, debtD, debtG, debtCap;
}

/// Ночь для расчёта потребности: сон (мин), Нагрузка накануне, дрёма накануне.
typedef NeedNight = ({double? tst, double strainPrev, double napPrev});

/// Потребность и долг на ночь (мин).
typedef NeedResult = ({double need, double debt, double base, double strainAdd, double napCredit});

/// §7.4.2 (форма калибровки B4¾, как `whoop_calibrate.need_sim`):
/// need_t = база + k_s·Нагрузка_{t−1} − дрёма_{t−1} + долг_t, 6–11 ч;
/// долг_t = clamp(d·долг_{t−1} + g·(базовая_{t−1} − сон_{t−1}), 0, 3 ч) — пересып гасит долг.
/// Пропуск ночи (нет сна) — долг продолжается со следующей ночи с прежнего значения.
List<NeedResult> needDebtSeries(List<NeedNight> nights, {SleepTheta theta = kSleepTheta}) {
  final out = <NeedResult>[];
  var debt = 0.0;
  ({double bneed, double tst})? prev;
  for (final n in nights) {
    if (prev != null) {
      debt = (theta.debtD * debt + theta.debtG * (prev.bneed - prev.tst)).clamp(0, theta.debtCap).toDouble();
    }
    final add = theta.needKs * n.strainPrev;
    final bneed = theta.needBase + add - n.napPrev;
    final need = (bneed + debt).clamp(360, 660).toDouble();
    out.add((need: need, debt: debt, base: theta.needBase, strainAdd: add, napCredit: n.napPrev));
    prev = n.tst == null ? null : (bneed: bneed, tst: n.tst!);
  }
  return out;
}

const kSleepTheta = SleepTheta();

/// Балл ночного стресса по доле 5-мин окон сна со стресс-индексом ≥ 2:
/// 100 при < 1 %, линейно до 70 при 5 %, далее до 40 при 15 %.
double stressScore(double frac) {
  final p = frac * 100;
  if (p < 1) return 100;
  if (p <= 5) return 100 - (p - 1) / 4 * 30;
  if (p <= 15) return 70 - (p - 5) / 10 * 30;
  return 40;
}

class SleepScore {
  /// Итог 0–100.
  final double pct;

  /// Составляющие 0–100 (null — нет данных; вес перенормирован).
  final double s;
  final double? c, e, x;
  const SleepScore(this.pct, this.s, this.c, this.e, this.x);

  /// Зона как у WHOOP: ≥ 85 — хорошо, 70–84 — так себе, < 70 — мало.
  String get word => pct >= 85 ? 'Хорошо' : (pct >= 70 ? 'Средне' : 'Мало');
}

/// Оценка сна v2 (§7.4.1, веса — [theta]).
SleepScore? sleepScoreV2({
  required num? tstMin,
  required num? needMin,
  double? consistency,
  num? effPct,
  double? stressFrac,
  SleepTheta theta = kSleepTheta,
}) {
  if (tstMin == null || needMin == null || needMin <= 0) return null;
  final s = math.min(1.0, tstMin / needMin) * 100;
  final e = effPct?.toDouble();
  final x = stressFrac == null ? null : stressScore(stressFrac);
  var w = theta.wS, sum = theta.wS * s;
  if (consistency != null) {
    w += theta.wC;
    sum += theta.wC * consistency;
  }
  if (e != null) {
    w += theta.wE;
    sum += theta.wE * e;
  }
  if (x != null) {
    w += theta.wX;
    sum += theta.wX * x;
  }
  return SleepScore((sum / w).clamp(0, 100).toDouble(), s, consistency, e, x);
}

/// Окно сна (секунды эпохи).
typedef SleepWindow = ({int onset, int wake});

/// Sleep Regularity Index (Phillips 2017) по окнам сна за [days] суток
/// «полдень–полдень», заканчивающихся сутками ночи [last]: 200·P(то же
/// состояние сон/бодрствование через 24 ч) − 100. Нужно ≥ 3 ночей > 3 ч, иначе null.
double? sriOf(List<SleepWindow> windows, SleepWindow last, {int days = 3}) {
  final lastWake = DateTime.fromMillisecondsSinceEpoch(last.wake * 1000);
  final endDay = lastWake.subtract(const Duration(hours: 12));
  final d0 = DateTime(endDay.year, endDay.month, endDay.day - (days - 1), 12);
  final lo = d0.millisecondsSinceEpoch ~/ 1000;
  final hi = lo + days * 86400;
  final ws = [for (final w in windows) if (w.wake > lo && w.onset < hi) w];
  final nights = <int>{
    for (final w in ws)
      if (w.wake - w.onset > 3 * 3600) (w.wake - 12 * 3600 - lo) ~/ 86400,
  };
  if (nights.length < 3) return null;
  final m = List.generate(days, (_) => List<bool>.filled(1440, false));
  for (final w in ws) {
    final a = math.max(0, (w.onset - lo) ~/ 60);
    final b = math.min(days * 1440, (w.wake - lo) ~/ 60);
    for (var t = a; t < b; t++) {
      m[t ~/ 1440][t % 1440] = true;
    }
  }
  var same = 0, tot = 0;
  for (var d = 0; d + 1 < days; d++) {
    for (var t = 0; t < 1440; t++) {
      if (m[d][t] == m[d + 1][t]) same++;
      tot++;
    }
  }
  return 200 * same / tot - 100;
}

/// Регулярность 0–100 (шкала к WHOOP «Sleep consistency %»).
double? consistencyOf(List<SleepWindow> windows, SleepWindow last, {SleepTheta theta = kSleepTheta}) {
  final s = sriOf(windows, last);
  return s == null ? null : (theta.consA + theta.consB * s).clamp(0, 100).toDouble();
}

/// Потребность на следующую ночь: долг после сегодняшней ночи [tstToday] и
/// надбавка за сегодняшнюю Нагрузку [strainToday] (та же форма §7.4.2).
NeedResult nextNeed(NeedResult today, {double? tstToday, required double strainToday, SleepTheta theta = kSleepTheta}) {
  final bneed = today.base + today.strainAdd - today.napCredit;
  final debt = tstToday == null
      ? today.debt
      : (theta.debtD * today.debt + theta.debtG * (bneed - tstToday)).clamp(0, theta.debtCap).toDouble();
  final add = theta.needKs * strainToday;
  final need = (theta.needBase + add + debt).clamp(360, 660).toDouble();
  return (need: need, debt: debt, base: theta.needBase, strainAdd: add, napCredit: 0);
}

/// План на вечер — один для «Мой день», текста главной и экрана «Сон».
typedef TonightPlan = ({DateTime wake, bool alarm, int need, int eff, int latency});

/// «Сегодня ночью»: отбой для цели [target] (1,0 / 0,85 / 0,70) к подъёму [wake].
DateTime bedtimeFor({
  required DateTime wake,
  required int needMin,
  required double target,
  int effPct = 90,
  int latencyMin = 10,
}) {
  final inBed = (needMin * target / (effPct.clamp(60, 100) / 100)).round();
  return wake.subtract(Duration(minutes: inBed + latencyMin));
}

enum Stage { wake, light, deep, rem }

/// Отрезок стадии (секунды эпохи); [stage] null — не наблюдалось.
typedef StageRun = ({int from, int to, Stage? stage});

/// Пробуждения: непрерывное бодрствование ≥ [minMin] мин после засыпания и до
/// последнего сна (утренний подъём не считается). Короткие — отдельно.
({int long, int short, int awakeMin}) awakeningsOf(List<StageRun> runs, {int minMin = 5}) {
  final firstSleep = runs.indexWhere((r) => r.stage != null && r.stage != Stage.wake);
  final lastSleep = runs.lastIndexWhere((r) => r.stage != null && r.stage != Stage.wake);
  if (firstSleep < 0) return (long: 0, short: 0, awakeMin: 0);
  var long = 0, short = 0, awake = 0, cur = 0;
  void close() {
    if (cur == 0) return;
    if (cur >= minMin * 60) {
      long++;
    } else {
      short++;
    }
    awake += cur;
    cur = 0;
  }

  for (var i = firstSleep; i <= lastSleep; i++) {
    final r = runs[i];
    if (r.stage == Stage.wake) {
      cur += r.to - r.from;
    } else {
      close();
    }
  }
  close();
  return (long: long, short: short, awakeMin: (awake / 60).round());
}

/// Минуты по стадиям.
Map<Stage, int> stageMinutes(List<StageRun> runs) {
  final m = {for (final s in Stage.values) s: 0};
  for (final r in runs) {
    final s = r.stage;
    if (s != null) m[s] = m[s]! + r.to - r.from;
  }
  return {for (final e in m.entries) e.key: (e.value / 60).round()};
}

String stageName(Stage s) => switch (s) {
  Stage.wake => 'Бодрствование',
  Stage.light => 'Лёгкий',
  Stage.deep => 'Глубокий',
  Stage.rem => 'Быстрый',
};

/// Ночной стресс по 5-мин окнам: 0–3 (как Монитор стресса). Сдвиг ВСР вниз
/// и пульса вверх от медианы этой же ночи: (ln r̃ − ln r)/0,3 + (HR − H̃)/8.
List<TV> nightStressOf(List<TV> hr, List<TV> rmssd) {
  if (rmssd.length < 6) return const [];
  double med(List<double> x) {
    final s = [...x]..sort();
    return s[s.length ~/ 2];
  }

  final lnBase = med([for (final p in rmssd) if (p.v > 0) math.log(p.v)]);
  final hrBase = hr.isEmpty ? null : med([for (final p in hr) p.v]);
  final out = <TV>[];
  var j = 0;
  for (final p in rmssd) {
    if (p.v <= 0) continue;
    var s = (lnBase - math.log(p.v)) / .3;
    if (hrBase != null) {
      while (j + 1 < hr.length && hr[j + 1].t <= p.t) {
        j++;
      }
      var sum = 0.0, k = 0;
      for (var i = math.max(0, j - 3); i < math.min(hr.length, j + 4); i++) {
        if ((hr[i].t - p.t).abs() <= 150) {
          sum += hr[i].v;
          k++;
        }
      }
      if (k > 0) s += (sum / k - hrBase) / 8;
    }
    out.add(TV(p.t, s.clamp(0, 3).toDouble()));
  }
  return out;
}

/// Доля окон ночного стресса ≥ 2 — вход «Ночной стресс» оценки сна.
double? stressFracOf(List<TV> stress) =>
    stress.isEmpty ? null : stress.where((p) => p.v >= 2).length / stress.length;

/// Сигнал браслета по 5 мин: доля минут с пульсом (0–100 %).
List<TV> signalOf(List<TV> hr, int from, int to) {
  final out = <TV>[];
  var j = 0;
  for (var t = from; t < to; t += 300) {
    var k = 0;
    while (j < hr.length && hr[j].t < t) {
      j++;
    }
    var i = j;
    while (i < hr.length && hr[i].t < t + 300) {
      k++;
      i++;
    }
    out.add(TV(t + 150, math.min(100, k * 20).toDouble()));
  }
  return out;
}
