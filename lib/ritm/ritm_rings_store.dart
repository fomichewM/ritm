// «Ритм» B4½ — кольца v3 по дням: чтение пакетов дня Edge, кэш входов,
// Восстановление к 30 предыдущим ночам, Нагрузка по склеенному ряду,
// «Экспорт для сверки». Формулы — ritm_rings.dart (чистые, с тестами).
//
// Кэш `ritm_rings.json` (документы приложения): по дню — ночные входы,
// Нагрузка и гистограмма; финальные дни не пересчитываются, последние два —
// при каждом чтении (ночь могла дописаться). Версия формул [kRingsVersion]
// в кэше: поменялась — всё пересчитывается.

import 'ritm_srpe.dart' show RitmRpe, SrpeSession;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import 'ritm_compare.dart';
import 'ritm_demo.dart' show kRitmDemo, ritmDemoRings;
import 'ritm_hk.dart';
import 'ritm_rings.dart';
import 'ritm_scores.dart' show ritmSleepPct;
import 'ritm_sleep.dart'
    show
        NeedNight,
        NeedResult,
        SleepScore,
        consistencyOf,
        needDebtSeries,
        nextNeed,
        nightStressOf,
        sleepScoreV2,
        stressFracOf;
import 'ritm_seed.dart' show RecSeedHist, RitmSeed, recSeedHist, usualWakeMin;
import 'ritm_whoop_csv.dart' show dayId;

const int kRingsVersion = 4; // 2: θ калибровки 15.10 (Нагрузка s, k); 3: окно сна (B4¾); 4: FIX84 остаток дня B·v^g, HRmax ≥ Танака

/// Входы одного дня (то, что кэшируется).
class RingDayInputs {
  final String day;
  final NightInputs night;
  final double? resp, tempDev, needMin, debtMin, eff;
  final double? lightMin, deepMin, remMin, awakeMin;
  final double? sleepPct;
  final StrainResult? strain;
  final List<HrSegment> timeline;
  final double? rhrForStrain, hrMax, dayMaxHr;
  final String vHist;

  /// Окно основного сна (секунды эпохи) — для регулярности (B4¾).
  final int? onset, wake;

  /// Доля 5-мин окон сна с ночным стрессом ≥ 2 (вход «Ночной стресс»).
  final double? nightStress;
  const RingDayInputs({
    required this.day,
    this.night = const NightInputs(),
    this.resp,
    this.tempDev,
    this.needMin,
    this.debtMin,
    this.eff,
    this.lightMin,
    this.deepMin,
    this.remMin,
    this.awakeMin,
    this.sleepPct,
    this.strain,
    this.timeline = const [],
    this.rhrForStrain,
    this.hrMax,
    this.dayMaxHr,
    this.vHist = '',
    this.onset,
    this.wake,
    this.nightStress,
  });

  Map<String, dynamic> toJson() {
    final n = night;
    final s = strain;
    return {
      'day': day,
      'n': {
        'rhr_sm': n.rhrSleepMean,
        'rhr_t30': n.rhrTrough30,
        'hrv_sws': n.rmssdSwsLast,
        'hrv_mean': n.rmssdNightMean,
        'sws': n.swsFound,
        'obs': n.observedFrac,
        'hrv_ok': n.hrValidFrac,
        'rrw': n.rrWindows,
        'on': n.onsetTs,
        'off': n.wakeTs,
        'tst': n.tstMin,
        'bed': n.inBedMin,
        'gap': n.maxGapMin,
      },
      'resp': resp,
      'temp': tempDev,
      'need': needMin,
      'debt': debtMin,
      'eff': eff,
      'light': lightMin,
      'deep': deepMin,
      'rem': remMin,
      'awake': awakeMin,
      'sp': sleepPct,
      if (s != null)
        's': {
          'v': s.strain,
          'i': s.load,
          'z': s.zoneMin,
          'trimp': s.trimp,
          'min': s.minutes,
          'src': {for (final e in s.bySrc.entries) e.key.name: e.value},
          'bad': s.suspicious,
          if (s.srpeLoad > 0) 'sr': s.srpeLoad,
        },
      'tl': [
        for (final g in timeline) [g.from, g.to, g.src?.name, g.valid],
      ],
      'rhr_s': rhrForStrain,
      'hrmax': hrMax,
      'dmax': dayMaxHr,
      'vh': vHist,
      'on': onset,
      'wk': wake,
      'ns': nightStress,
    };
  }

  static RingDayInputs fromJson(Map m) {
    double? d(Object? x) => (x as num?)?.toDouble();
    final n = (m['n'] as Map?) ?? const {};
    final s = m['s'] as Map?;
    HrSrc? src(Object? x) => HrSrc.values.where((e) => e.name == x).firstOrNull;
    return RingDayInputs(
      day: '${m['day']}',
      night: NightInputs(
        rhrSleepMean: d(n['rhr_sm']),
        rhrTrough30: d(n['rhr_t30']),
        rmssdSwsLast: d(n['hrv_sws']),
        rmssdNightMean: d(n['hrv_mean']),
        swsFound: n['sws'] == true,
        observedFrac: d(n['obs']) ?? 0,
        hrValidFrac: d(n['hrv_ok']) ?? 0,
        rrWindows: (n['rrw'] as num?)?.toInt() ?? 0,
        onsetTs: (n['on'] as num?)?.toInt(),
        wakeTs: (n['off'] as num?)?.toInt(),
        tstMin: (n['tst'] as num?)?.toInt() ?? 0,
        inBedMin: (n['bed'] as num?)?.toInt() ?? 0,
        maxGapMin: (n['gap'] as num?)?.toInt() ?? 0,
      ),
      resp: d(m['resp']),
      tempDev: d(m['temp']),
      needMin: d(m['need']),
      debtMin: d(m['debt']),
      eff: d(m['eff']),
      lightMin: d(m['light']),
      deepMin: d(m['deep']),
      remMin: d(m['rem']),
      awakeMin: d(m['awake']),
      sleepPct: d(m['sp']),
      strain: s == null
          ? null
          : StrainResult(
              strain: d(s['v']) ?? 0,
              load: d(s['i']) ?? 0,
              zoneMin: [for (final z in (s['z'] as List? ?? const [])) (z as num).toInt()],
              trimp: d(s['trimp']) ?? 0,
              minutes: (s['min'] as num?)?.toInt() ?? 0,
              bySrc: {
                for (final e in ((s['src'] as Map?) ?? const {}).entries)
                  if (src(e.key) != null) src(e.key)!: (e.value as num).toInt(),
              },
              suspicious: s['bad'] == true,
              srpeLoad: d(s['sr']) ?? 0,
            ),
      timeline: [
        for (final g in (m['tl'] as List? ?? const []))
          if (g is List && g.length == 4)
            HrSegment((g[0] as num).toInt(), (g[1] as num).toInt(), src(g[2]), d(g[3]) ?? 0),
      ],
      rhrForStrain: d(m['rhr_s']),
      hrMax: d(m['hrmax']),
      dayMaxHr: d(m['dmax']),
      vHist: '${m['vh'] ?? ''}',
      onset: (m['on'] as num?)?.toInt(),
      wake: (m['wk'] as num?)?.toInt(),
      nightStress: d(m['ns']),
    );
  }
}

/// Что рисует главная за день (кольца v3).
class RitmRingsDay {
  final RingDayInputs inputs;
  final RecoveryResult recovery;

  /// Восстановление вчера — для стрелки «Готов ↑».
  final int? prevRecovery;
  final int dayFrom, dayTo;

  /// «Обычно» для экрана Восстановления: средние 30 предыдущих ночей
  /// ('hrv', 'rhr', 'resp', 'sleep').
  final Map<String, double> norms;

  /// Оценка сна v2 (4 составляющие) — то, что показывает кольцо «Сон».
  final SleepScore? sleepScore;

  /// Потребность и долг «Ритма» на эту ночь (§7.4.2).
  final NeedResult? need;

  /// Потребность на следующую ночь (после этой ночи и сегодняшней Нагрузки).
  final NeedResult? tonight;

  /// Долг сна за 14 ночей по порядку (последний — эта ночь), мин.
  final List<double> debtHist;

  /// FIX84: обычное время подъёма (мин от полуночи) — медиана последних
  /// пробуждений браслета, иначе «Здоровья»; null — не знаем.
  final int? usualWake;

  /// FIX84: откуда засеяна норма Восстановления («WHOOP», «Apple Watch»…)
  /// и сколько ночей нормы из засева; '' / 0 — норма только своя.
  final String recSeedSrc;
  final int recSeeded;

  /// Откуда ночи засева: «Здоровье» / экспорт CSV / «Здоровье» и CSV.
  final String recSeedVia;

  /// FIX84: значения этой ночи, с которыми реально считали Восстановление
  /// (при засеве Apple Watch — пульс покоя Watch, а не браслета).
  final Map<String, double> recTonight;
  const RitmRingsDay({
    this.usualWake,
    this.recSeedSrc = '',
    this.recSeedVia = '',
    this.recTonight = const {},
    this.recSeeded = 0,
    required this.inputs,
    required this.recovery,
    this.sleepScore,
    this.need,
    this.debtHist = const [],
    this.tonight,
    this.norms = const {},
    this.prevRecovery,
    required this.dayFrom,
    required this.dayTo,
  });

  StrainResult? get strain => inputs.strain;

  /// «браслет 14 ч + Watch 1 ч».
  String? get strainSource =>
      strain == null || strain!.minutes == 0
          ? null
          : strainSourceLine(strain!.bySrc) + (strain!.srpeLoad > 0 ? ' + силовая по ощущению' : '');

  /// Стрелка к вчера: ↑ / ↓ (|Δ| ≥ 5 п.п.), иначе пусто.
  String get arrow {
    final a = recovery.value, b = prevRecovery;
    if (a == null || b == null) return '';
    if (a - b >= 5) return ' ↑';
    if (b - a >= 5) return ' ↓';
    return '';
  }
}

/// Переход пакета дня Edge → входы колец (без I/O; тестируется отдельно).
RingDayInputs ringInputsFromBundle({
  required String day,
  required Map sleep,
  required Map heart,
  required Map hrv,
  double? tempDev,
  List<HkWorkout> watch = const [],
  bool secondGarmin = false,
  List<TV> broadcast = const [],
  HrSrc broadcastSrc = HrSrc.sensor,
  List<SrpeSession> srpe = const [],
  double? hrMaxProfile,
  double? observed90,
  int? age,
  bool female = false,
  RingTheta theta = kRingTheta,
}) {
  // getDaySleep отдаёт гипнограмму точками {t, stage}; последняя — конец.
  final pts = (sleep['hypnogram'] as List?) ?? const [];
  final hyp = <HypSeg>[];
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    if (a is! Map || b is! Map) continue;
    final s = (a['t'] as num?)?.toInt(), e = (b['t'] as num?)?.toInt();
    if (s == null || e == null || e <= s) continue;
    hyp.add(HypSeg(s, e, '${a['stage']}'));
  }
  final hrMin = TV.parse(heart['hr']);
  final hrvTl = TV.parse(hrv['timeline']);
  final night = nightInputs(hyp: hyp, hrMin: hrMin, hrv: hrvTl);
  double? d(Object? x) => (x as num?)?.toDouble();
  final tst = d(sleep['duration_min']) ?? (night.tstMin > 0 ? night.tstMin.toDouble() : null);
  final need = d(sleep['need_min']);
  final sp = ritmSleepPct(tst, need)?.toDouble();
  final effRaw = d(sleep['efficiency']);
  // Нагрузка: склеенный ряд за день.
  final second = <SecondWorkout>[
    for (final w in watch)
      SecondWorkout(
        from: w.s.millisecondsSinceEpoch ~/ 1000,
        to: w.e.millisecondsSinceEpoch ~/ 1000,
        // ТЗ §6, набор S4: ряд Garmin из «Здоровья» — только для сверки; в Нагрузку
        // Garmin попадает трансляцией пульса (ниже), иначе на тренировке — браслет.
        cardio: isCardioHkType(w.type) && !(secondGarmin || w.src.isGarmin()),
        hr: [for (final p in w.hrSeries) TV(p.$1.millisecondsSinceEpoch ~/ 1000, p.$2)],
        src: secondGarmin || w.src.isGarmin() ? HrSrc.garmin : HrSrc.watch,
      ),
    // B7: трансляция пульса (BLE) — поверх, она идёт с груди/часов на тренировке.
    ...broadcastSegments(broadcast, broadcastSrc),
  ];
  final xs = stitchHr(hrMin, second);
  final rhr = night.rhrSleepMean ?? d(heart['resting_hr']);
  var dayMax = 0.0;
  for (final p in hrMin) {
    if (p.v <= 220) dayMax = math.max(dayMax, p.v);
  }
  final hrMax = hrMaxFor(
    profile: hrMaxProfile,
    observed90: [?observed90, if (dayMax > 0) dayMax].fold<double?>(
      null,
      (a, b) => a == null ? b : math.max(a, b),
    ),
    age: age,
  );
  StrainResult? strain;
  var vh = '';
  if (rhr != null && xs.isNotEmpty) {
    strain = strainV3(xs, rhr: rhr, hrMax: hrMax, female: female, theta: theta, srpe: srpe);
    vh = vHistogram(xs, rhr: rhr, hrMax: hrMax);
  }
  final d0 = DateTime.parse(day);
  final from = d0.millisecondsSinceEpoch ~/ 1000;
  final to = from + 86400;
  return RingDayInputs(
    day: day,
    night: night,
    resp: d((sleep['resp'] as Map?)?['value']),
    tempDev: tempDev,
    needMin: need,
    debtMin: d(sleep['debt_min']),
    eff: effRaw == null ? null : (effRaw <= 1 ? effRaw * 100 : effRaw),
    lightMin: d(sleep['light_min']),
    deepMin: d(sleep['deep_min']),
    remMin: d(sleep['rem_min']),
    awakeMin: d(sleep['awake_min']),
    sleepPct: sp,
    strain: strain,
    timeline: hrTimeline(xs, from, to),
    rhrForStrain: rhr,
    hrMax: hrMax,
    dayMaxHr: dayMax > 0 ? dayMax : null,
    vHist: vh,
    onset: (sleep['onset_ts'] as num?)?.toInt() ?? _firstAsleep(hyp)?.start,
    wake: (sleep['wake_ts'] as num?)?.toInt() ?? _lastAsleep(hyp)?.end,
    nightStress: _nightStress(hyp, hrMin, hrvTl),
  );
}

/// Потребность/долг «Ритма» (§7.4.2) для всех дней кэша по порядку.
/// Нагрузка накануне — только если предыдущий день кэша и есть вчера.
List<NeedResult> needForDays(List<RingDayInputs> all) {
  final nights = <NeedNight>[];
  for (var i = 0; i < all.length; i++) {
    final x = all[i];
    final p = i > 0 ? all[i - 1] : null;
    final yesterday = p != null &&
        DateTime.parse(x.day).difference(DateTime.parse(p.day)).inHours.abs() <= 25;
    nights.add((
      tst: x.night.tstMin > 0 ? x.night.tstMin.toDouble() : null,
      strainPrev: yesterday ? (p.strain?.strain ?? 0) : 0,
      napPrev: 0,
    ));
  }
  return needDebtSeries(nights);
}

/// Ночной стресс только по окнам сна (ВСР 5 мин + пульс), доля ≥ 2.
double? _nightStress(List<HypSeg> hyp, List<TV> hr, List<TV> hrv) {
  bool asleep(int t) => hyp.any((h) => h.asleep && t >= h.start && t < h.end);
  final rm = [for (final p in hrv) if (asleep(p.t)) p];
  if (rm.length < 12) return null; // меньше часа ВСР во сне — компонента нет
  final from = rm.first.t - 300, to = rm.last.t + 300;
  return stressFracOf(nightStressOf([for (final p in hr) if (p.t >= from && p.t <= to) p], rm));
}

HypSeg? _firstAsleep(List<HypSeg> h) {
  for (final x in h) {
    if (x.asleep) return x;
  }
  return null;
}

HypSeg? _lastAsleep(List<HypSeg> h) {
  for (final x in h.reversed) {
    if (x.asleep) return x;
  }
  return null;
}

/// Оценка сна v2 дня (ТЗ v3 §7.4.1): достаточность, регулярность по окнам
/// сна этой и 2 предыдущих суток (нужно ≥ 3 ночей), эффективность; ночной
/// стресс — когда появится стресс-индекс сна [stressFrac].
SleepScore? sleepScoreForDay(RingDayInputs x, List<RingDayInputs> before, {double? stressFrac, double? needMin}) {
  final tst = x.night.tstMin > 0 ? x.night.tstMin : null;
  final need = needMin ?? x.needMin;
  final suff = x.sleepPct;
  // Вход «сон/потребность» мог прийти готовым (Edge) — восстановим TST из него.
  final tstMin = tst ?? (suff != null && need != null ? suff / 100 * need : null);
  double? cons;
  final on = x.onset ?? x.night.onsetTs, wk = x.wake ?? x.night.wakeTs;
  if (on != null && wk != null) {
    final last = (onset: on, wake: wk);
    final tail = before.length > 3 ? before.sublist(before.length - 3) : before;
    cons = consistencyOf([
      for (final h in tail)
        if ((h.onset ?? h.night.onsetTs) != null && (h.wake ?? h.night.wakeTs) != null)
          (onset: (h.onset ?? h.night.onsetTs)!, wake: (h.wake ?? h.night.wakeTs)!),
      last,
    ], last);
  }
  return sleepScoreV2(
    tstMin: tstMin,
    needMin: need,
    consistency: cons,
    effPct: x.eff,
    stressFrac: stressFrac ?? x.nightStress,
  );
}

/// FIX84: на чём реально посчитано Восстановление — значения этой ночи и ряды
/// нормы (свои или засеянные). Экран «Восстановление» показывает ровно их:
/// «обычно» = среднее того ряда, с которым сравнивали (а не свой ряд, когда
/// сравнивали с засевом).
typedef RecBasis = ({
  double? hrv,
  double? rhr,
  double? resp,
  List<double> hrvH,
  List<double> rhrH,
  List<double> respH,
  bool seeded,
});

/// Восстановление дня по истории [before] (дни строго раньше, по порядку).
/// FIX84: [seed] — история из CSV WHOOP и «Здоровья»: пока своих ночей меньше
/// 30, норма добирается засевом (правила шкал — [recSeedHist]).
RecoveryResult recoveryForDay(
  RingDayInputs x,
  List<RingDayInputs> before, {
  RingTheta theta = kRingTheta,
  double? needMin,
  RitmSeed? seed,
}) => recoveryWithBasis(x, before, theta: theta, needMin: needMin, seed: seed).r;

({RecoveryResult r, RecBasis b}) recoveryWithBasis(
  RingDayInputs x,
  List<RingDayInputs> before, {
  RingTheta theta = kRingTheta,
  double? needMin,
  RitmSeed? seed,
}) {
  final hist = before.length > 30 ? before.sublist(before.length - 30) : before;
  final temps = [for (final h in hist) ?h.tempDev];
  final sleepPct = sleepScoreForDay(x, before, needMin: needMin)?.pct ?? x.sleepPct;
  final shortNight = x.night.inBedMin > 0 && x.night.tooShort;
  final RecBasis ob = (
    hrv: x.night.rmssdSwsLast,
    rhr: x.night.rhrSleepMean,
    resp: x.resp,
    hrvH: [for (final h in hist) ?h.night.rmssdSwsLast],
    rhrH: [for (final h in hist) ?h.night.rhrSleepMean],
    respH: [for (final h in hist) ?h.resp],
    seeded: false,
  );
  final own = recoveryV3(
    rmssd: ob.hrv,
    rhr: ob.rhr,
    resp: ob.resp,
    tempDev: x.tempDev,
    // Температура входит, когда отклонение считается ≥ 14 ночей (норма браслета
    // устоялась) — до этого вес 0, честно (ТЗ v3 §7.1: «иначе выкл.»).
    tempSettled: temps.length >= 14,
    sleepPct: sleepPct,
    rmssdHist: ob.hrvH,
    rhrHist: ob.rhrH,
    respHist: ob.respH,
    shortNight: shortNight,
    theta: theta,
  );
  if (seed == null || seed.isEmpty || own.why == 'short_night') return (r: own, b: ob);
  if (own.value != null && own.nights >= 30) return (r: own, b: ob);
  final s = recSeedHist(
    day: x.day,
    seed: seed,
    bandHrv: {for (final h in before) h.day: ?h.night.rmssdSwsLast},
    bandRhr: {for (final h in before) h.day: ?h.night.rhrSleepMean},
    bandResp: {for (final h in before) h.day: ?h.resp},
    tonightHrv: x.night.rmssdSwsLast,
    tonightRhr: x.night.rhrSleepMean,
  );
  if (s.seededRhr + s.seededHrv == 0) return (r: own, b: ob);
  final RecBasis sb = (
    hrv: s.hrvTonight,
    rhr: s.rhrTonight,
    resp: x.resp,
    hrvH: s.hrv,
    rhrH: s.rhr,
    respH: s.resp,
    seeded: true,
  );
  final r = recoveryV3(
    rmssd: sb.hrv,
    rhr: sb.rhr,
    resp: sb.resp,
    tempDev: x.tempDev,
    tempSettled: temps.length >= 14,
    sleepPct: sleepPct,
    rmssdHist: sb.hrvH,
    rhrHist: sb.rhrH,
    respHist: sb.respH,
    shortNight: shortNight,
    // WHOOP не пишет ВСР в «Здоровье»: при засеянной норме пульса (≥ 14 ночей)
    // считаем без ВСР — «уточняется», пока ВСР браслета не наберёт 4 ночи.
    allowNoHrv: s.rhr.length >= kRecSettledNights,
    theta: theta,
  );
  if (r.value == null && own.why == 'calibrating' && r.nights <= own.nights) return (r: own, b: ob);
  return (r: r, b: sb);
}

/// Ряды засева той же ночи — для подписи «норма по истории …» и «обычно».
RecSeedHist? recSeedInfo(RingDayInputs x, List<RingDayInputs> before, RitmSeed? seed) {
  if (seed == null || seed.isEmpty) return null;
  final s = recSeedHist(
    day: x.day,
    seed: seed,
    bandHrv: {for (final h in before) h.day: ?h.night.rmssdSwsLast},
    bandRhr: {for (final h in before) h.day: ?h.night.rhrSleepMean},
    bandResp: {for (final h in before) h.day: ?h.resp},
    tonightHrv: x.night.rmssdSwsLast,
    tonightRhr: x.night.rhrSleepMean,
  );
  return s.seededRhr + s.seededHrv == 0 ? null : s;
}

/// Наш день → строка «Экспорта для сверки».
RitmDayExport exportRow(RingDayInputs x, RecoveryResult r, {bool strength = false, SleepScore? sleep, NeedResult? need}) {
  final n = x.night;
  DateTime? ts(int? s) => s == null ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);
  final watchMin = x.strain?.bySrc[HrSrc.watch] ?? 0;
  return RitmDayExport(
    day: x.day,
    onset: ts(n.onsetTs),
    wake: ts(n.wakeTs),
    strength: strength,
    swsFound: n.swsFound,
    vHist: x.vHist,
    v: {
      'rhr_sleep_mean': n.rhrSleepMean,
      'rhr_trough30': n.rhrTrough30,
      'rmssd_sws_last': n.rmssdSwsLast,
      'rmssd_night_mean': n.rmssdNightMean,
      'resp': x.resp,
      'temp_dev': x.tempDev,
      'tst_min': n.tstMin > 0 ? n.tstMin.toDouble() : null,
      'in_bed_min': n.inBedMin > 0 ? n.inBedMin.toDouble() : null,
      'eff': x.eff,
      'light_min': x.lightMin,
      'deep_min': x.deepMin,
      'rem_min': x.remMin,
      'awake_min': x.awakeMin,
      'need_min': need?.need ?? x.needMin,
      'debt_min': need?.debt ?? x.debtMin,
      'consistency': sleep?.c,
      'sleep_pct': sleep?.pct ?? x.sleepPct,
      'recovery': r.value?.toDouble(),
      'strain': x.strain == null ? null : (x.strain!.strain * 10).round() / 10,
      'observed_frac': n.observedFrac,
      'hr_valid_frac': n.hrValidFrac,
      'max_gap_min': n.maxGapMin.toDouble(),
      'watch_min': watchMin.toDouble(),
      'rec_zbar': r.zbar,
      'strain_load': x.strain?.load,
    },
  );
}

/// Хранилище колец v3.
class RitmRingsStore {
  RitmRingsStore._();

  static final Map<String, RingDayInputs> _days = {};
  static bool _loaded = false;

  static Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/ritm_rings.json');
  }

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map;
      if (m['v'] != kRingsVersion) return;
      for (final e in (m['days'] as List? ?? const [])) {
        if (e is Map) {
          final x = RingDayInputs.fromJson(e);
          _days[x.day] = x;
        }
      }
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      final keys = _days.keys.toList()..sort();
      final keep = keys.length > 120 ? keys.sublist(keys.length - 120) : keys;
      await f.writeAsString(
        jsonEncode({
          'v': kRingsVersion,
          'days': [for (final k in keep) _days[k]!.toJson()],
        }),
      );
    } catch (_) {}
  }

  static List<RingDayInputs> get days {
    final keys = _days.keys.toList()..sort();
    return [for (final k in keys) _days[k]!];
  }

  /// Досчитать дни (последние [backfill] из [available]) и вернуть кольца
  /// дня [day]. [repo] — LocalRepository (dynamic, как в главной).
  /// B7: трансляция пульса за окно [от, до) в секундах (ставит RitmHrsRecorder).
  static Future<List<TV>> Function(int fromSec, int toSec)? broadcastSource;

  static Future<RitmRingsDay?> ensure(
    dynamic repo,
    String day, {
    required List<String> available,
    List<HkWorkout> watch = const [],
    bool secondGarmin = false,
    int backfill = 45,
  }) async {
    await _load();
    final sorted = [...available]..sort();
    final want = sorted.length > backfill ? sorted.sublist(sorted.length - backfill) : sorted;
    final fresh = want.length >= 2 ? want.sublist(want.length - 2) : want;
    Map<String, double> temps = const {};
    try {
      temps = {
        for (final p in ((await repo.getChart('skin_temp_dev_c'))['points'] as List? ?? const []))
          if (p is Map && p['t'] is num && p['v'] is num)
            dayId(DateTime.fromMillisecondsSinceEpoch((p['t'] as num).toInt() * 1000)):
                (p['v'] as num).toDouble(),
      };
    } catch (_) {}
    double? hrMaxProfile;
    int? age;
    try {
      final p = await repo.getProfile() as Map;
      hrMaxProfile = (p['max_hr'] as num?)?.toDouble() ?? (p['hr_max'] as num?)?.toDouble();
      age = (p['age'] as num?)?.toInt();
    } catch (_) {}
    var changed = false;
    for (final d in want) {
      if (_days.containsKey(d) && !fresh.contains(d) && d != day) continue;
      try {
        final sleep = await repo.getDaySleep(d) as Map;
        final heart = await repo.getDayHeart(d) as Map;
        final hrv = await repo.getDayHrv(d) as Map;
        double? obs;
        for (final x in _days.values) {
          final m = x.dayMaxHr;
          if (m != null && (obs == null || m > obs)) obs = m;
        }
        // FIX84: максимум пульса за год из истории WHOOP (у пользователя-калибровщика —
        // тот же HRmax, на котором откалибрована Нагрузка), если он выше.
        final hy = seedSource()?.hrMaxYear(DateTime.now());
        if (hy != null && (obs == null || hy > obs)) obs = hy;
        final dd = DateTime.parse(d);
        final d0 = dd.millisecondsSinceEpoch ~/ 1000;
        var bc = const <TV>[];
        try {
          bc = await broadcastSource?.call(d0, d0 + 86400) ?? const [];
        } catch (_) {}
        _days[d] = ringInputsFromBundle(
          day: d,
          sleep: sleep,
          heart: heart,
          hrv: hrv,
          tempDev: temps[d],
          watch: [
            for (final w in watch)
              if (w.s.year == dd.year && w.s.month == dd.month && w.s.day == dd.day) w,
          ],
          secondGarmin: secondGarmin,
          broadcast: bc,
          broadcastSrc: secondGarmin ? HrSrc.garmin : HrSrc.sensor,
          srpe: RitmRpe.range(d0, d0 + 86400),
          hrMaxProfile: hrMaxProfile,
          observed90: obs,
          age: age,
        );
        changed = true;
      } catch (_) {}
    }
    if (changed) await _save();
    return dayResult(day);
  }

  /// Кольца дня по кэшу.
  static RitmRingsDay? dayResult(String day) {
    final all = days;
    final i = all.indexWhere((x) => x.day == day);
    if (i < 0) return null;
    final nd = needForDays(all);
    final seed = seedSource();
    final rb = recoveryWithBasis(all[i], all.sublist(0, i), needMin: nd[i].need, seed: seed);
    final rec = rb.r;
    final prev = i > 0 ? recoveryForDay(all[i - 1], all.sublist(0, i - 1), seed: seed).value : null;
    final info = rec.value == null ? null : recSeedInfo(all[i], all.sublist(0, i), seed);
    // FIX84: «обычно» — среднее ТОГО ряда, с которым сравнивали, и только если
    // в нём ≥ kRecMinNights ночей (норма из одной ночи — не норма).
    double? norm(List<double> xs) =>
        xs.length < kRecMinNights ? null : xs.reduce((a, b) => a + b) / xs.length;
    // Обычный подъём: свои пробуждения браслета, иначе окна сна «Здоровья».
    final ownWakes = [
      for (var j = 0; j <= i; j++) ?(all[j].wake ?? all[j].night.wakeTs),
    ];
    final hkKeys = (seed?.sleep.keys.toList() ?? <String>[])..sort();
    final usual = usualWakeMin(ownWakes) ??
        usualWakeMin([
          for (final k in hkKeys)
            if (k.compareTo(day) <= 0) seed!.sleep[k]!.wake,
          ...ownWakes,
        ]);
    final d0 = DateTime.parse(day).millisecondsSinceEpoch ~/ 1000;
    final before = all.sublist(math.max(0, i - 30), i);
    double? avg(Iterable<double?> xs) {
      final v = [for (final x in xs) ?x];
      return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    }
    return RitmRingsDay(
      inputs: all[i],
      recovery: rec,
      sleepScore: sleepScoreForDay(all[i], all.sublist(0, i), needMin: nd[i].need),
      need: nd[i],
      debtHist: [for (var j = math.max(0, i - 13); j <= i; j++) nd[j].debt],
      tonight: nextNeed(
        nd[i],
        tstToday: all[i].night.tstMin > 0 ? all[i].night.tstMin.toDouble() : null,
        strainToday: all[i].strain?.strain ?? 0,
      ),
      norms: {
        'hrv': ?norm(rb.b.hrvH),
        'rhr': ?norm(rb.b.rhrH),
        'resp': ?norm(rb.b.respH),
        'light': ?avg(before.map((x) => x.lightMin)),
        'deep': ?avg(before.map((x) => x.deepMin)),
        'rem': ?avg(before.map((x) => x.remMin)),
        'sleep': ?avg([
          for (var j = math.max(0, i - 30); j < i; j++)
            sleepScoreForDay(all[j], all.sublist(0, j), needMin: nd[j].need)?.pct ?? all[j].sleepPct,
        ]),
      },
      prevRecovery: prev,
      usualWake: usual,
      recTonight: {'hrv': ?rb.b.hrv, 'rhr': ?rb.b.rhr, 'resp': ?rb.b.resp},
      recSeedSrc: info?.src ?? '',
      recSeedVia: info?.via ?? '',
      recSeeded: info == null ? 0 : math.max(info.seededRhr, info.seededHrv),
      dayFrom: d0,
      dayTo: d0 + 86400,
    );
  }

  /// «Экспорт для сверки»: все дни кэша.
  static List<RitmDayExport> export() {
    final all = days;
    final nd = needForDays(all);
    return [
      for (var i = 0; i < all.length; i++)
        exportRow(
          all[i],
          recoveryForDay(all[i], all.sublist(0, i), needMin: nd[i].need, seed: seedSource()),
          sleep: sleepScoreForDay(all[i], all.sublist(0, i), needMin: nd[i].need),
          need: nd[i],
        ),
    ];
  }

  /// FIX84: засев нормы (CSV WHOOP, «Здоровье»); тесты подменяют.
  static RitmSeed? Function() seedSource = () => RitmSeed.cached;

  /// Для тестов и демо.
  static void debugSeed(List<RingDayInputs> xs) {
    _loaded = true;
    _days
      ..clear()
      ..addAll({for (final x in xs) x.day: x});
  }
}

/// Чей пульс пошёл в Нагрузку в окне [from; to) — большинство минут склейки
/// (null — нет данных). Демо — по демо-кольцам сегодняшнего дня.
HrSrc? ritmStrainSrcIn(DateTime from, DateTime to) {
  final day = dayId(from);
  final n = DateTime.now();
  final tl = kRitmDemo
      ? (dayId(n) == day ? ritmDemoRings(DateTime(n.year, n.month, n.day)).inputs.timeline : const <HrSegment>[])
      : (RitmRingsStore.dayResult(day)?.inputs.timeline ?? const <HrSegment>[]);
  final a = from.millisecondsSinceEpoch ~/ 1000, b = to.millisecondsSinceEpoch ~/ 1000;
  final by = <HrSrc, int>{};
  for (final g in tl) {
    if (g.src == null) continue;
    final o = (g.to < b ? g.to : b) - (g.from > a ? g.from : a);
    if (o > 0) by[g.src!] = (by[g.src!] ?? 0) + o;
  }
  if (by.isEmpty) return null;
  return by.entries.reduce((x, y) => x.value >= y.value ? x : y).key;
}

