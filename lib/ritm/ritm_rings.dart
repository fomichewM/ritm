// «Ритм» B4½ — движок трёх колец по ТЗ v3 §7.1–§7.3 (чистые функции).
//
// Входы — то, что уже лежит в дневном пакете Edge (`derived_day`):
//   • `hypnogram`     — [{start, end, stage}] эпохи секунды, стадии
//                       light / deep / rem / wake / unobserved;
//   • `hrv_timeline`  — скользящий rMSSD по 5-мин окнам очищенных NN {t, v},
//                       t — КОНЕЦ окна (эпоха, секунды);
//   • `hr_curve`      — пульс по минутам за весь день {t, v}, t — начало минуты.
// Поэтому кольца считаются в слое «Ритма», а движок Edge не трогаем: бамп
// analytics не меняет наши формулы, сверка §8 ловит, если поменял входы.
//
//   ВСР (K4)   rmssd_sws_last  — rMSSD последнего эпизода DEEP ≥ 3 мин
//                                (эпизоды DEEP с разрывом ≤ 60 с склеиваются);
//                                нет DEEP — последние 5 мин сна (флаг swsFound=false)
//              rmssd_night_mean — среднее 5-мин окон за сон (справочно)
//   Пульс (K5) rhr_sleep_mean   — среднее по минутам сна (без WAKE) — в кольцо
//              rhr_trough30     — минимум скользящего 30-мин среднего (справочно)
//   Восстановление §7.2 — z к среднему и SD 30 предыдущих ночей (калибровка
//              15.10 по 361 дню WHOOP: медиана/MAD не проходит допуск), веса
//              0,45 ВСР · 0,20 пульс · 0,10 дыхание · 0,15 сон · 0,10 темп.,
//              логистика R = 100/(1+e^−(a·z̄+b)), θ = {a, b}.
//   Нагрузка §7.3 — ВЕСЬ день по долям резерва пульса (Карвонен),
//              I = Σ c·(e^(k·v)−1)·Δt, Strain = 21·(2/π)·arctan(I/s), θ = {s, k}.
//   Склейка D7 — внутри HKWorkout бег/ходьба/вело/поход — пульс Watch
//              (≥ 80 % минут с замером), иначе браслет; дыры не считаются.
//
// Тест: test/ritm_rings_test.dart.

import 'dart:math' as math;

// ── θ: параметры калибровки (§8.3, не больше 6) ──────────────────────────────

/// Константы колец. Пока CSV WHOOP Михаила нет — стартовые значения ТЗ v3
/// (`calibratedAt` пусто → в «Как считается» пишем «не сверено с WHOOP»).
class RingTheta {
  /// Восстановление: R = 100/(1+e^−(a·z̄+b)).
  final double recA, recB;

  /// Нагрузка: w(v) = c·(e^(k·v)−1), Strain = 21·(2/π)·arctan(I/s).
  final double strainK, strainC, strainS;

  /// Потребность/долг (B4¾): k_s мин/балл нагрузки, d — гашение долга.
  final double needKs, debtD;

  /// Дата калибровки по CSV WHOOP ('' — не калибровано), окно, MAE.
  final String calibratedAt;
  final int windowDays;
  final double? recMae, strainMae;

  const RingTheta({
    this.recA = 1.2,
    this.recB = 0.35,
    this.strainK = 3.2,
    this.strainC = 0.15,
    this.strainS = 80,
    this.needKs = 2.1,
    this.debtD = 0.85,
    this.needBase,
    this.calibratedAt = '',
    this.windowDays = 0,
    this.recMae,
    this.strainMae,
  });

  /// Личная базовая потребность сна, мин (калибровка; null — медиана 28 ночей).
  final double? needBase;

  bool get calibrated => calibratedAt.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'rec_a': recA,
    'rec_b': recB,
    'strain_k': strainK,
    'strain_c': strainC,
    'strain_s': strainS,
    'need_ks': needKs,
    'debt_d': debtD,
    if (needBase != null) 'need_base': needBase,
    'calibrated_at': calibratedAt,
    'window_days': windowDays,
    if (recMae != null) 'rec_mae': recMae,
    if (strainMae != null) 'strain_mae': strainMae,
  };

  static RingTheta fromJson(Map m) {
    double d(String k, double def) => (m[k] as num?)?.toDouble() ?? def;
    return RingTheta(
      recA: d('rec_a', 1.2),
      recB: d('rec_b', 0.35),
      strainK: d('strain_k', 3.2),
      strainC: d('strain_c', 0.15),
      strainS: d('strain_s', 80),
      needKs: d('need_ks', 2.1),
      debtD: d('debt_d', 0.85),
      needBase: (m['need_base'] as num?)?.toDouble(),
      calibratedAt: '${m['calibrated_at'] ?? ''}',
      windowDays: (m['window_days'] as num?)?.toInt() ?? 0,
      recMae: (m['rec_mae'] as num?)?.toDouble(),
      strainMae: (m['strain_mae'] as num?)?.toDouble(),
    );
  }
}

/// Действующие θ. Меняются только `tool/ritm_calibrate.py` по CSV WHOOP
/// (калибровочная треть по времени) — с датой, окном и MAE.
///
/// 15.10.2026 — `build/whoop_calibrate.py` по экспорту WHOOP Михаила
/// 10.08.2025–09.08.2026 (361 день; ⅔ калибровка, ⅓ проверка; отчёт
/// build/CALIBRATION.md). Проверочная треть: Восстановление MAE 8,0 п.п.,
/// зона 80 %, r 0,86; Нагрузка тренировки (без силовых) MAE 1,7, r 0,91;
/// потребность MAE 16 мин, долг 16 мин. Входы — WHOOP («вход → выход»):
/// точность НАШИХ входов проверит сверка по дням с пересечением.
const RingTheta kRingTheta = RingTheta(
  recA: 1.076,
  recB: 0.939,
  strainK: 3.901,
  strainS: 65.8,
  needKs: 1.52,
  debtD: 0.58,
  needBase: 451,
  calibratedAt: '2026-10-15',
  windowDays: 361,
  recMae: 8.0,
  strainMae: 1.7,
);

// ── входы ────────────────────────────────────────────────────────────────────

/// Отрезок гипнограммы (эпоха, секунды).
class HypSeg {
  final int start, end;
  final String stage;
  const HypSeg(this.start, this.end, this.stage);
  int get sec => end - start;
  bool get asleep => stage == 'light' || stage == 'deep' || stage == 'rem';

  static List<HypSeg> parse(Object? raw) {
    if (raw is! List) return const [];
    final out = <HypSeg>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final s = (e['start'] as num?)?.toInt(), en = (e['end'] as num?)?.toInt();
      if (s == null || en == null || en <= s) continue;
      out.add(HypSeg(s, en, '${e['stage'] ?? ''}'));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }
}

/// Точка ряда (эпоха, секунды; значение).
class TV {
  final int t;
  final double v;
  const TV(this.t, this.v);

  static List<TV> parse(Object? raw) {
    if (raw is! List) return const [];
    final out = <TV>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final t = (e['t'] as num?)?.toInt(), v = (e['v'] as num?)?.toDouble();
      if (t == null || v == null || v.isNaN) continue;
      out.add(TV(t, v));
    }
    out.sort((a, b) => a.t.compareTo(b.t));
    return out;
  }
}

// ── K4/K5: ночные оценщики ───────────────────────────────────────────────────

/// Ночные входы колец + качество ночи (пишутся в «Экспорт для сверки»).
class NightInputs {
  final double? rhrSleepMean, rhrTrough30;
  final double? rmssdSwsLast, rmssdNightMean;

  /// Найден ли эпизод DEEP ≥ 3 мин (иначе ВСР — последние 5 мин сна).
  final bool swsFound;

  /// Доля окна ночи, когда браслет «видел» (не `unobserved`).
  final double observedFrac;

  /// Доля минут окна ночи с пульсом.
  final double hrValidFrac;

  /// Окон rMSSD внутри сна.
  final int rrWindows;
  final int? onsetTs, wakeTs;
  final int tstMin, inBedMin;

  /// Самая длинная дыра пульса внутри окна ночи, мин.
  final int maxGapMin;

  const NightInputs({
    this.rhrSleepMean,
    this.rhrTrough30,
    this.rmssdSwsLast,
    this.rmssdNightMean,
    this.swsFound = false,
    this.observedFrac = 0,
    this.hrValidFrac = 0,
    this.rrWindows = 0,
    this.onsetTs,
    this.wakeTs,
    this.tstMin = 0,
    this.inBedMin = 0,
    this.maxGapMin = 0,
  });

  /// Наблюдали меньше 3 ч — Восстановление не считаем («—»).
  bool get tooShort => observedFrac * inBedMin < 180;
}

bool _inSleep(List<HypSeg> hyp, int t) {
  for (final s in hyp) {
    if (t < s.start) return false;
    if (t < s.end) return s.asleep;
  }
  return false;
}

/// Эпизоды DEEP: соседние куски с разрывом ≤ [mergeGapSec] склеиваются.
List<(int, int)> deepEpisodes(List<HypSeg> hyp, {int mergeGapSec = 60}) {
  final out = <(int, int)>[];
  for (final s in hyp) {
    if (s.stage != 'deep') continue;
    if (out.isNotEmpty && s.start - out.last.$2 <= mergeGapSec) {
      out[out.length - 1] = (out.last.$1, s.end);
    } else {
      out.add((s.start, s.end));
    }
  }
  return out;
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

double? _mean(Iterable<double> xs) {
  var n = 0, sum = 0.0;
  for (final x in xs) {
    n++;
    sum += x;
  }
  return n == 0 ? null : sum / n;
}

/// rMSSD последнего эпизода глубокого сна ≥ [minDeepSec] (§7.1, как WHOOP).
///
/// Окно точки `hrv_timeline` — [t−300, t]; берём точки, чей центр (t−150)
/// внутри эпизода, значение — медиана. Нет подходящего эпизода → последние
/// 5 мин сна (последняя точка, центр которой во сне), `swsFound = false`.
({double? v, bool sws}) rmssdSwsLast(
  List<HypSeg> hyp,
  List<TV> hrv, {
  int minDeepSec = 180,
}) {
  if (hrv.isEmpty || hyp.isEmpty) return (v: null, sws: false);
  final eps = deepEpisodes(hyp).where((e) => e.$2 - e.$1 >= minDeepSec).toList();
  for (final e in eps.reversed) {
    final inEp = [
      for (final p in hrv)
        if (p.t - 150 >= e.$1 && p.t - 150 < e.$2) p.v,
    ];
    if (inEp.isNotEmpty) return (v: _median(inEp), sws: true);
  }
  for (final p in hrv.reversed) {
    if (_inSleep(hyp, p.t - 150)) return (v: p.v, sws: false);
  }
  return (v: null, sws: false);
}

/// Среднее 5-мин окон rMSSD, центр которых во сне (справочно).
double? rmssdNightMean(List<HypSeg> hyp, List<TV> hrv) =>
    _mean([for (final p in hrv) if (_inSleep(hyp, p.t - 150)) p.v]);

/// Пульс покоя за сон: среднее минут, середина которых во сне (без WAKE).
double? rhrSleepMean(List<HypSeg> hyp, List<TV> hrMin) =>
    _mean([for (final p in hrMin) if (_inSleep(hyp, p.t + 30)) p.v]);

/// Минимум скользящего 30-мин среднего по минутам сна (≥ 25 минут в окне).
double? rhrTrough30(List<HypSeg> hyp, List<TV> hrMin) {
  final xs = [for (final p in hrMin) if (_inSleep(hyp, p.t + 30)) p];
  double? best;
  var lo = 0;
  var sum = 0.0;
  for (var i = 0; i < xs.length; i++) {
    sum += xs[i].v;
    while (xs[i].t - xs[lo].t >= 30 * 60) {
      sum -= xs[lo].v;
      lo++;
    }
    final n = i - lo + 1;
    if (n >= 25) {
      final m = sum / n;
      if (best == null || m < best) best = m;
    }
  }
  return best;
}

/// Все ночные входы и флаги качества из пакета дня.
NightInputs nightInputs({
  required List<HypSeg> hyp,
  required List<TV> hrMin,
  required List<TV> hrv,
}) {
  if (hyp.isEmpty) return const NightInputs();
  final on = hyp.first.start, off = hyp.last.end;
  var observed = 0, asleep = 0;
  for (final s in hyp) {
    if (s.stage != 'unobserved') observed += s.sec;
    if (s.asleep) asleep += s.sec;
  }
  final win = math.max(1, off - on);
  final inWin = [for (final p in hrMin) if (p.t + 30 >= on && p.t + 30 < off) p];
  final winMin = (win / 60).ceil();
  var gap = 0;
  var prev = on;
  for (final p in inWin) {
    gap = math.max(gap, ((p.t - prev) / 60).floor());
    prev = p.t + 60;
  }
  gap = math.max(gap, ((off - prev) / 60).floor());
  final sws = rmssdSwsLast(hyp, hrv);
  return NightInputs(
    rhrSleepMean: rhrSleepMean(hyp, hrMin),
    rhrTrough30: rhrTrough30(hyp, hrMin),
    rmssdSwsLast: sws.v,
    rmssdNightMean: rmssdNightMean(hyp, hrv),
    swsFound: sws.sws,
    observedFrac: observed / win,
    hrValidFrac: winMin == 0 ? 0 : math.min(1, inWin.length / winMin),
    rrWindows: [for (final p in hrv) if (_inSleep(hyp, p.t - 150)) p].length,
    onsetTs: on,
    wakeTs: off,
    tstMin: (asleep / 60).round(),
    inBedMin: (win / 60).round(),
    maxGapMin: gap,
  );
}

// ── базовые линии 30 ночей ───────────────────────────────────────────────────

/// Норма к предыдущим ночам. По калибровке 15.10 (build/CALIBRATION.md, 361
/// день WHOOP «вход → выход») — среднее и SD за 30 ночей: с ними
/// Восстановление проходит допуск §8.2 (MAE 8,0, зона 80 %), с медианой/MAD
/// — нет (MAE 9,2, зона 75 %). [robust] — медиана и MAD·1,4826 (справочно).
class Baseline {
  final double med, sigma;
  final int n;
  const Baseline(this.med, this.sigma, this.n);

  /// Последние [window] значений (по умолчанию 30 ночей), ≥ [minN] — иначе null.
  /// [med] — центр нормы (среднее; при [robust] — медиана).
  static Baseline? of(
    List<double> prev, {
    required double floor,
    int window = 30,
    int minN = 4,
    bool robust = false,
  }) {
    final xs = prev.length > window ? prev.sublist(prev.length - window) : prev;
    if (xs.length < minN) return null;
    if (robust) {
      final m = _median(xs)!;
      final mad = _median([for (final x in xs) (x - m).abs()])!;
      return Baseline(m, math.max(mad * 1.4826, floor), xs.length);
    }
    final m = xs.reduce((a, b) => a + b) / xs.length;
    var v = 0.0;
    for (final x in xs) {
      v += (x - m) * (x - m);
    }
    return Baseline(m, math.max(math.sqrt(v / xs.length), floor), xs.length);
  }

  double z(double x) => (x - med) / sigma;
}

/// Полы σ (единицы метрики). ТЗ §7 «пол σ 0,3» — в шкале дыхания (вдох/мин);
/// для ln ВСР 0,3 сплющил бы z почти до нуля (типичная σ ln rMSSD 0,1–0,2),
/// поэтому пол ln ВСР — 0,05, пульса — 1 уд/мин. Структурные константы, не θ.
const double kFloorLnHrv = 0.05, kFloorRhr = 1.0, kFloorResp = 0.3;

// ── §7.2 Восстановление ──────────────────────────────────────────────────────

/// Вклад фактора: z, вес и сколько пунктов он дал (R − R без него).
class RecDriver {
  final String key; // hrv | rhr | resp | sleep | temp
  final double z, weight, points;
  const RecDriver(this.key, this.z, this.weight, this.points);
}

class RecoveryResult {
  final int? value;

  /// Ночей в норме (для «N/14»), предварительное ли число (< 14).
  final int nights;
  final bool preliminary;
  final double? zbar;
  final List<RecDriver> drivers;

  /// Почему нет числа: 'short_night' | 'calibrating' | 'no_inputs'.
  final String? why;
  final bool cappedBySleep;
  const RecoveryResult({
    this.value,
    this.nights = 0,
    this.preliminary = false,
    this.zbar,
    this.drivers = const [],
    this.why,
    this.cappedBySleep = false,
  });
}

const Map<String, double> kRecWeights = {
  'hrv': 0.45,
  'rhr': 0.20,
  'resp': 0.10,
  'sleep': 0.15,
  'temp': 0.10,
};

double _logistic(double z, RingTheta th) =>
    100 / (1 + math.exp(-(th.recA * z + th.recB)));

/// Восстановление §7.2. Истории — значения ПРЕДЫДУЩИХ ночей (без этой).
RecoveryResult recoveryV3({
  required double? rmssd,
  required double? rhr,
  double? resp,
  double? tempDev,
  bool tempSettled = false,
  double? sleepPct,
  required List<double> rmssdHist,
  required List<double> rhrHist,
  List<double> respHist = const [],
  bool shortNight = false,
  RingTheta theta = kRingTheta,
}) {
  if (shortNight) return const RecoveryResult(why: 'short_night');
  if (rmssd == null || rhr == null || rmssd <= 0) {
    return const RecoveryResult(why: 'no_inputs');
  }
  final bHrv = Baseline.of(
    [for (final x in rmssdHist) if (x > 0) math.log(x)],
    floor: kFloorLnHrv,
  );
  final bRhr = Baseline.of(rhrHist, floor: kFloorRhr);
  final nights = math.min(rmssdHist.length, rhrHist.length);
  if (bHrv == null || bRhr == null) {
    return RecoveryResult(nights: nights, why: 'calibrating');
  }
  final z = <String, double>{
    'hrv': bHrv.z(math.log(rmssd)).clamp(-3.0, 3.0),
    'rhr': (-bRhr.z(rhr)).clamp(-3.0, 3.0),
  };
  final bResp = Baseline.of(respHist, floor: kFloorResp);
  if (resp != null && bResp != null) {
    z['resp'] = (-(resp - bResp.med).abs() / bResp.sigma).clamp(-3.0, 0.0);
  }
  if (sleepPct != null) {
    z['sleep'] = ((sleepPct - 85) / 15).clamp(-2.0, 1.0);
  }
  if (tempSettled && tempDev != null) {
    z['temp'] = (-math.max(0, tempDev - 0.3) / 0.3).clamp(-3.0, 0.0);
  }
  var wsum = 0.0, acc = 0.0;
  for (final e in z.entries) {
    wsum += kRecWeights[e.key]!;
    acc += kRecWeights[e.key]! * e.value;
  }
  final zbar = acc / wsum;
  var r = _logistic(zbar, theta);
  final drivers = <RecDriver>[];
  for (final e in z.entries) {
    final w = kRecWeights[e.key]! / wsum;
    final without = _logistic(zbar - w * e.value, theta);
    drivers.add(RecDriver(e.key, e.value, w, r - without));
  }
  var capped = false;
  if (sleepPct != null && sleepPct < 60 && r > 66) {
    r = 66;
    capped = true;
  }
  return RecoveryResult(
    value: r.round().clamp(0, 100),
    nights: nights,
    preliminary: nights < 14,
    zbar: zbar,
    drivers: drivers,
    cappedBySleep: capped,
  );
}

/// Сон% «достаточность» S = TST/потребность (K1 старой формулы; v2 — B4¾).
double? sleepSufficiency(num? tstMin, num? needMin) {
  if (tstMin == null || needMin == null || needMin <= 0) return null;
  return math.min(1.0, tstMin / needMin) * 100;
}

// ── §7.3 Нагрузка ────────────────────────────────────────────────────────────

/// Источник минуты пульса.
enum HrSrc { band, watch, garmin }

/// Минута склеенного ряда.
class HrMinute {
  final int t;
  final double hr;
  final HrSrc src;
  const HrMinute(this.t, this.hr, this.src);
}

/// Сегмент таймлайна под кольцом (D7): [from, to) секунды, источник,
/// доля минут с пульсом.
class HrSegment {
  final int from, to;
  final HrSrc? src; // null — не носился
  final double valid;
  const HrSegment(this.from, this.to, this.src, this.valid);
  int get minutes => ((to - from) / 60).round();
}

/// Тренировка второго устройства: окно и ряд пульса (эпоха, секунды).
class SecondWorkout {
  final int from, to;

  /// Бег / ходьба / вело / поход — пульс Watch точнее запястного WHOOP.
  final bool cardio;
  final List<TV> hr;
  final HrSrc src;
  const SecondWorkout({
    required this.from,
    required this.to,
    required this.cardio,
    required this.hr,
    this.src = HrSrc.watch,
  });
}

/// HKWorkoutActivityType: бег 37, ходьба 52, вело 13, поход 24 и колесо 72/73.
bool isCardioHkType(int t) => const {37, 52, 13, 24, 72, 73}.contains(t);

/// Склейка ряда пульса дня (D7): внутри кардио-тренировки второго устройства
/// с ≥ 80 % минут с замером — его пульс; остальное — браслет; дыры пусты.
List<HrMinute> stitchHr(List<TV> bandMin, List<SecondWorkout> second) {
  final byMin = <int, HrMinute>{
    for (final p in bandMin) p.t ~/ 60: HrMinute(p.t ~/ 60 * 60, p.v, HrSrc.band),
  };
  for (final w in second) {
    if (!w.cardio || w.to <= w.from) continue;
    final buckets = <int, List<double>>{};
    for (final p in w.hr) {
      if (p.t < w.from || p.t >= w.to) continue;
      (buckets[p.t ~/ 60] ??= []).add(p.v);
    }
    final total = ((w.to - w.from) / 60).ceil();
    if (total <= 0 || buckets.length / total < 0.8) continue;
    for (final e in buckets.entries) {
      byMin[e.key] = HrMinute(e.key * 60, _mean(e.value)!, w.src);
    }
  }
  final keys = byMin.keys.toList()..sort();
  return [for (final k in keys) byMin[k]!];
}

/// Таймлайн источников за окно [dayFrom, dayTo): соседние минуты одного
/// источника сливаются; разрыв > 5 мин — сегмент «не носился».
List<HrSegment> hrTimeline(List<HrMinute> xs, int dayFrom, int dayTo) {
  final out = <HrSegment>[];
  HrSrc? src;
  var segFrom = dayFrom, have = 0, cur = dayFrom;
  void emit(int from, int to, HrSrc? s, int n) {
    if (to <= from) return;
    final mins = math.max(1, ((to - from) / 60).round());
    out.add(HrSegment(from, to, s, s == null ? 0 : math.min(1, n / mins)));
  }

  for (final m in xs) {
    if (m.t < dayFrom || m.t >= dayTo) continue;
    if (m.t - cur > 5 * 60) {
      if (src != null) emit(segFrom, cur, src, have);
      emit(src == null ? segFrom : cur, m.t, null, 0);
      segFrom = m.t;
      src = m.src;
      have = 0;
    } else if (m.src != src) {
      if (src != null) {
        emit(segFrom, m.t, src, have);
      } else {
        emit(segFrom, m.t, null, 0);
      }
      segFrom = m.t;
      src = m.src;
      have = 0;
    }
    have++;
    cur = m.t + 60;
  }
  if (src != null) emit(segFrom, cur, src, have);
  if (dayTo - cur > 5 * 60) emit(src == null ? segFrom : cur, dayTo, null, 0);
  return out;
}

/// HRmax: профиль → максимум за 90 дней → Танака 208 − 0,7·возраст.
double hrMaxFor({double? profile, double? observed90, int? age}) {
  if (profile != null && profile > 120) return profile;
  if (observed90 != null && observed90 > 120) return observed90;
  return 208 - 0.7 * (age ?? 40);
}

class StrainResult {
  final double strain;

  /// Интеграл I (весовые минуты).
  final double load;

  /// Минуты в зонах Z0..Z5 (доля резерва <40, 40–60, 60–70, 70–80, 80–90, ≥90).
  final List<int> zoneMin;

  /// Banister TRIMP — второй оценщик (справочно).
  final double trimp;
  final int minutes;

  /// Минуты по источникам.
  final Map<HrSrc, int> bySrc;

  /// Страховка §7.3: нагрузка 0 при ≥ 20 мин пульса > покой + 30.
  final bool suspicious;
  const StrainResult({
    required this.strain,
    required this.load,
    required this.zoneMin,
    required this.trimp,
    required this.minutes,
    required this.bySrc,
    this.suspicious = false,
  });
}

int hrZone(double v) {
  if (v < 0.4) return 0;
  if (v < 0.6) return 1;
  if (v < 0.7) return 2;
  if (v < 0.8) return 3;
  if (v < 0.9) return 4;
  return 5;
}

/// Вес минуты w(v) = c·(e^(k·v)−1), v ∈ [0; 1,1].
double strainWeight(double v, RingTheta th) {
  final x = v.clamp(0.0, 1.1);
  return th.strainC * (math.exp(th.strainK * x) - 1);
}

/// Шкала 0–21: 21·(2/π)·arctan(I/s).
double strainScale(double load, RingTheta th) =>
    21 * (2 / math.pi) * math.atan(math.max(0, load) / th.strainS);

/// Нагрузка дня по склеенному ряду (минуты, Δt = 1 мин) — §7.3.
StrainResult strainV3(
  List<HrMinute> xs, {
  required double rhr,
  required double hrMax,
  bool female = false,
  RingTheta theta = kRingTheta,
}) {
  final hrr = math.max(20.0, hrMax - rhr);
  var load = 0.0, trimp = 0.0, hot = 0;
  final zones = List<int>.filled(6, 0);
  final bySrc = <HrSrc, int>{};
  final b = female ? 1.67 : 1.92, a = female ? 0.86 : 0.64;
  for (final m in xs) {
    final v = (m.hr - rhr) / hrr;
    load += strainWeight(v, theta);
    zones[hrZone(v)]++;
    if (v > 0) trimp += v * a * math.exp(b * v);
    if (m.hr > rhr + 30) hot++;
    bySrc[m.src] = (bySrc[m.src] ?? 0) + 1;
  }
  final s = strainScale(load, theta);
  return StrainResult(
    strain: s,
    load: load,
    zoneMin: zones,
    trimp: trimp,
    minutes: xs.length,
    bySrc: bySrc,
    suspicious: s < 0.05 && hot >= 20,
  );
}

/// Гистограмма минут по доле резерва (корзина 0 — v < 0, далее по 0,05,
/// последняя — v ≥ 1,1) для «Экспорта для сверки» и калибровки s, k.
String vHistogram(List<HrMinute> xs, {required double rhr, required double hrMax}) {
  final hrr = math.max(20.0, hrMax - rhr);
  final bins = List<int>.filled(24, 0);
  for (final m in xs) {
    final v = (m.hr - rhr) / hrr;
    final i = v < 0 ? 0 : math.min(23, 1 + (v / 0.05).floor());
    bins[i]++;
  }
  return bins.join(';');
}

/// Подпись источника под кольцом «Нагрузка»: «браслет 14 ч + Watch 1 ч».
String strainSourceLine(Map<HrSrc, int> bySrc) {
  String h(int m) {
    if (m < 60) return '$m мин';
    final r = m % 60;
    return r == 0 ? '${m ~/ 60} ч' : '${m ~/ 60} ч $r мин';
  }
  final parts = <String>[];
  for (final s in HrSrc.values) {
    final m = bySrc[s] ?? 0;
    if (m <= 0) continue;
    parts.add('${hrSrcName(s)} ${h(m)}');
  }
  return parts.isEmpty ? 'нет пульса' : parts.join(' + ');
}

String hrSrcName(HrSrc s) => switch (s) {
  HrSrc.band => 'браслет',
  HrSrc.watch => 'Watch',
  HrSrc.garmin => 'Garmin',
};
