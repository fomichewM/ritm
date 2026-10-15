// «Ритм» — данные Apple Watch из Swift-канала `ritm/health` и чистые правила
// сборки B3 (ТЗ v2 §10.6, §10.9, §10.10, §10.11, §10.12, §4.3–4.5).
//
// Здесь нет Flutter и нет канала: разбор ответа Swift (тот формат, что
// отдаёт RitmHealthKit.swift — значения в единицах HealthKit, SpO₂ долей
// 0…1), медианы, классификатор тренировок, сверка, шаги, правила записи.
// Всё проверяется юнит-тестами (test/ritm_b3_test.dart) на фикстурах.

import 'dart:math' as math;

import 'ritm_calc.dart' show Agree, mean, percentile;

// ───────────────────────── разбор ответа канала ─────────────────────────

/// Источник записи HealthKit: `sourceRevision.source` + устройство.
class HkSource {
  final String bundle, name, product, model;

  /// Тестовая запись DEBUG-засева симулятора (метаданные RitmDebugSeed).
  final bool seed;
  const HkSource({
    this.bundle = '',
    this.name = '',
    this.product = '',
    this.model = '',
    this.seed = false,
  });

  factory HkSource.parse(Object? m) {
    if (m is! Map) return const HkSource();
    return HkSource(
      bundle: '${m['bundle'] ?? ''}',
      name: '${m['name'] ?? ''}',
      product: '${m['product'] ?? ''}',
      model: '${m['model'] ?? ''}',
      seed: m['seed'] == true,
    );
  }

  /// Записал Apple Watch. Наши собственные записи (bundle «Ритма») — нет,
  /// кроме DEBUG-засева симулятора, если [allowSeed].
  bool isWatch({String own = '', bool allowSeed = false}) {
    if (seed) return allowSeed;
    if (own.isNotEmpty && bundle == own) return false;
    if (model.toLowerCase().contains('watch')) return true;
    if (product.startsWith('Watch')) return true;
    final n = name.toLowerCase();
    return n.contains('watch') || n.contains('часы');
  }
}

DateTime _t(Object? ms) =>
    DateTime.fromMillisecondsSinceEpoch((ms as num? ?? 0).toInt());

double? _d(Object? v) => v is num ? v.toDouble() : null;

class HkSample {
  final double v;
  final DateTime s, e;
  final HkSource src;
  const HkSample(this.v, this.s, this.e, [this.src = const HkSource()]);

  static List<HkSample> list(Object? raw) => [
    if (raw is List)
      for (final m in raw)
        if (m is Map && m['v'] is num)
          HkSample(
            (m['v'] as num).toDouble(),
            _t(m['s']),
            _t(m['e'] ?? m['s']),
            HkSource.parse(m['src']),
          ),
  ];
}

/// Запись ЭКГ Apple Watch (HKElectrocardiogram) — дата, классификация, пульс.
class HkEcg {
  final DateTime at;

  /// Имя `HKElectrocardiogram.Classification`: sinusRhythm, atrialFibrillation,
  /// inconclusiveLowHeartRate, inconclusiveHighHeartRate,
  /// inconclusivePoorReading, inconclusiveOther, unrecognized, notSet.
  final String cls;
  final double? hr;
  final HkSource src;

  /// DEBUG: синтетическая запись Swift (в симулятор ЭКГ записать нельзя).
  final bool synthetic;
  const HkEcg(
    this.at,
    this.cls, {
    this.hr,
    this.src = const HkSource(),
    this.synthetic = false,
  });

  static List<HkEcg> list(Object? raw) => [
    if (raw is List)
      for (final m in raw)
        if (m is Map && m['cls'] is String)
          HkEcg(
            _t(m['s']),
            m['cls'] as String,
            hr: _d(m['hr']),
            src: HkSource.parse(m['src']),
            synthetic: m['synthetic'] == true,
          ),
  ];
}

/// Тренировка из «Здоровья» (HKWorkout) с пульсом внутри и после конца.
class HkWorkout {
  final String uuid;
  final DateTime s, e;

  /// `HKWorkoutActivityType.rawValue` (37 — бег, 52 — ходьба, 13 — велосипед…).
  final int type;
  final double? distM, kcal, hrAvg, hrMax;

  /// Сколько замеров пульса Watch внутри (Watch во время тренировки пишет
  /// пульс каждые ~5 с — это и есть «валидные секунды» для сверки).
  final int hrN;

  /// Замеры пульса 0–120 с после конца: (время, уд/мин).
  final List<(DateTime, double)> hrAfter;

  /// Пульс Watch внутри тренировки (время, уд/мин) — график по зонам (B4).
  final List<(DateTime, double)> hrSeries;
  final HkSource src;
  const HkWorkout({
    this.uuid = '',
    required this.s,
    required this.e,
    this.type = 3000,
    this.distM,
    this.kcal,
    this.hrAvg,
    this.hrMax,
    this.hrN = 0,
    this.hrAfter = const [],
    this.hrSeries = const [],
    this.src = const HkSource(),
  });

  int get minutes => e.difference(s).inMinutes;

  static List<HkWorkout> list(Object? raw) => [
    if (raw is List)
      for (final m in raw)
        if (m is Map && m['s'] is num && m['e'] is num)
          HkWorkout(
            uuid: '${m['uuid'] ?? ''}',
            s: _t(m['s']),
            e: _t(m['e']),
            type: (m['type'] as num?)?.toInt() ?? 3000,
            distM: _d(m['dist']),
            kcal: _d(m['kcal']),
            hrAvg: _d(m['hrAvg']),
            hrMax: _d(m['hrMax']),
            hrN: (m['hrN'] as num?)?.toInt() ?? 0,
            hrAfter: [
              if (m['hrAfter'] is List)
                for (final p in m['hrAfter'] as List)
                  if (p is List && p.length >= 2 && p[0] is num && p[1] is num)
                    (_t(p[0]), (p[1] as num).toDouble()),
            ],
            hrSeries: [
              if (m['hrSeries'] is List)
                for (final p in m['hrSeries'] as List)
                  if (p is List && p.length >= 2 && p[0] is num && p[1] is num)
                    (_t(p[0]), (p[1] as num).toDouble()),
            ],
            src: HkSource.parse(m['src']),
          ),
  ];
}

/// Шаги за сегодня по данным «Здоровья».
class HkSteps {
  /// Все источники (сумма «Здоровья» без двойного счёта).
  final double? all;

  /// Только Apple Watch.
  final double? watch;

  /// Часы суток, в которые Watch писал пульс (≈ часы ношения).
  final int watchHours;
  const HkSteps({this.all, this.watch, this.watchHours = 0});

  factory HkSteps.parse(Object? m) => m is Map
      ? HkSteps(
          all: _d(m['all']),
          watch: _d(m['watch']),
          watchHours: (m['watchHours'] as num?)?.toInt() ?? 0,
        )
      : const HkSteps();
}

/// Ответ `snapshot` канала, как есть.
class HkSnapshot {
  final bool available;
  final DateTime now;
  final List<HkSample> vo2, spo2, rhr, wristTemp, hrr, sleep;
  final List<HkEcg> ecg;
  final List<HkWorkout> workouts;
  final HkSteps steps;
  final bool debugSeeded;
  const HkSnapshot({
    this.available = false,
    required this.now,
    this.vo2 = const [],
    this.spo2 = const [],
    this.rhr = const [],
    this.wristTemp = const [],
    this.hrr = const [],
    this.sleep = const [],
    this.ecg = const [],
    this.workouts = const [],
    this.steps = const HkSteps(),
    this.debugSeeded = false,
  });

  factory HkSnapshot.parse(Object? raw, {DateTime? now}) {
    if (raw is! Map) return HkSnapshot(now: now ?? DateTime.now());
    return HkSnapshot(
      available: raw['available'] == true,
      now: raw['nowMs'] is num ? _t(raw['nowMs']) : (now ?? DateTime.now()),
      vo2: HkSample.list(raw['vo2']),
      spo2: HkSample.list(raw['spo2']),
      rhr: HkSample.list(raw['rhr']),
      wristTemp: HkSample.list(raw['wristTemp']),
      hrr: HkSample.list(raw['hrr']),
      sleep: HkSample.list(raw['sleep']),
      ecg: HkEcg.list(raw['ecg']),
      workouts: HkWorkout.list(raw['workouts']),
      steps: HkSteps.parse(raw['steps']),
      debugSeeded: raw['debugSeeded'] == true,
    );
  }
}

// ───────────────────────── что показываем (только Watch) ─────────────────────────

/// HRR тренировки: насколько упал пульс за минуту после финиша.
class WorkoutHrr {
  final int drop;

  /// «Watch» — замер HealthKit heartRateRecoveryOneMinute; «по пульсу Watch» —
  /// посчитано из замеров пульса после финиша; «браслет» — из 1 Гц браслета.
  final String source;
  const WorkoutHrr(this.drop, this.source);

  /// Словами (ориентиры для взрослых: < 12 — медленно, 12–20 — обычно,
  /// 21–29 — хорошо, ≥ 30 — отлично).
  String get word => drop >= 30
      ? 'отлично'
      : drop >= 21
      ? 'хорошо'
      : drop >= 12
      ? 'обычно'
      : 'медленно';
}

/// HRR из замеров после финиша: пик в первые 15 с (или пульс на финише)
/// минус пульс через 60 с (ближайший замер 45–75 с).
int? hrrFromSamples(
  DateTime end,
  List<(DateTime, double)> after, {
  double? hrAtEnd,
}) {
  double? peak = hrAtEnd;
  double? at60;
  var best = 1e9;
  for (final (t, v) in after) {
    final dt = t.difference(end).inMilliseconds / 1000;
    if (dt >= -1 && dt <= 15) peak = peak == null ? v : math.max(peak, v);
    if (dt >= 45 && dt <= 75 && (dt - 60).abs() < best) {
      best = (dt - 60).abs();
      at60 = v;
    }
  }
  if (peak == null || at60 == null) return null;
  final d = (peak - at60).round();
  return d > 0 ? d : null;
}

class WatchData {
  /// Последний VO₂max Watch и все замеры за 90 дней.
  final double? vo2;
  final DateTime? vo2At;
  final List<HkSample> vo2Series;

  /// SpO₂ ночью, %: медиана замеров Watch 23:00–08:00.
  final double? spo2;
  final int spo2N;

  /// Пульс покоя Watch за ночь/утро.
  final int? rhr;

  /// Минуты сна Watch за ночь.
  final int? sleepMin;

  /// Температура запястья во сне: отклонение последней ночи от медианы
  /// прошлых ночей, °C (null — меньше 5 ночей или Watch не носился).
  final double? wristDev;
  final List<HkEcg> ecg;
  final List<HkWorkout> workouts;

  /// Замеры heartRateRecoveryOneMinute Watch (для привязки к тренировкам).
  final List<HkSample> hrr;
  final HkSteps steps;
  final DateTime? lastSample;
  final int samples;
  final bool viaChannel;
  const WatchData({
    this.vo2,
    this.vo2At,
    this.vo2Series = const [],
    this.spo2,
    this.spo2N = 0,
    this.rhr,
    this.sleepMin,
    this.wristDev,
    this.ecg = const [],
    this.workouts = const [],
    this.hrr = const [],
    this.steps = const HkSteps(),
    this.lastSample,
    this.samples = 0,
    this.viaChannel = false,
  });

  bool get any => samples > 0;

  /// Все данные Watch из снимка канала. [own] — наш bundle id (свои записи
  /// не считаются Watch); [allowSeed] — DEBUG-засев симулятора считать Watch.
  factory WatchData.from(
    HkSnapshot s, {
    String own = '',
    bool allowSeed = false,
    Set<String> off = const {},
  }) {
    bool w(HkSource x) => x.isWatch(own: own, allowSeed: allowSeed);
    List<HkSample> ws(List<HkSample> l) => [
      for (final x in l)
        if (w(x.src)) x,
    ];
    final now = s.now;
    final vo2 = off.contains('vo2') ? <HkSample>[] : ws(s.vo2)
      ..sort((a, b) => a.e.compareTo(b.e));
    final spo2 = off.contains('spo2') ? <HkSample>[] : ws(s.spo2);
    final rhr = off.contains('rhr') ? <HkSample>[] : ws(s.rhr);
    final temp = off.contains('temp') ? <HkSample>[] : ws(s.wristTemp);
    final sleep = off.contains('sleep') ? <HkSample>[] : ws(s.sleep);
    final hrr = ws(s.hrr);
    final ecg = off.contains('ecg')
        ? <HkEcg>[]
        : [
            for (final e in s.ecg)
              if (w(e.src)) e,
          ];
    final wk = off.contains('workouts')
        ? <HkWorkout>[]
        : [
            for (final x in s.workouts)
              if (w(x.src)) x,
          ];
    final night = nightWindow(now);
    final rhrNight = [
      for (final x in rhr)
        if (!x.e.isBefore(night.from)) x,
    ]..sort((a, b) => a.e.compareTo(b.e));
    DateTime? last;
    var n = 0;
    void seen(DateTime t) {
      n++;
      if (last == null || t.isAfter(last!)) last = t;
    }

    for (final l in [vo2, spo2, rhr, temp, sleep, hrr]) {
      for (final x in l) {
        seen(x.e);
      }
    }
    for (final x in ecg) {
      seen(x.at);
    }
    for (final x in wk) {
      seen(x.e);
    }
    final stepsOff = off.contains('steps');
    if (!stepsOff && (s.steps.watch ?? 0) > 0) n++;
    return WatchData(
      vo2: vo2.isEmpty ? null : vo2.last.v,
      vo2At: vo2.isEmpty ? null : vo2.last.e,
      vo2Series: vo2,
      spo2: spo2Median(spo2, now),
      spo2N: spo2InWindow(spo2, now).length,
      rhr: rhrNight.isEmpty ? null : rhrNight.last.v.round(),
      sleepMin: watchAsleepMin(sleep, night.from),
      wristDev: wristTempDev(temp, now),
      ecg: ecg..sort((a, b) => b.at.compareTo(a.at)),
      workouts: wk,
      hrr: hrr,
      steps: stepsOff ? const HkSteps() : s.steps,
      lastSample: last,
      samples: n,
      viaChannel: true,
    );
  }

  /// HRR тренировки [wk]: замер Watch в течение 10 мин после конца, иначе
  /// по пульсу Watch после финиша.
  WorkoutHrr? hrrOf(HkWorkout wk) {
    for (final h in hrr) {
      final dt = h.s.difference(wk.e).inSeconds;
      if (dt >= -60 && dt <= 600) return WorkoutHrr(h.v.round(), 'Watch');
    }
    final d = hrrFromSamples(wk.e, wk.hrAfter);
    return d == null ? null : WorkoutHrr(d, 'по пульсу Watch');
  }
}

/// Ночь для «Watch за ночь»: с 18:00 вчера до сейчас.
({DateTime from, DateTime to}) nightWindow(DateTime now) => (
  from: DateTime(now.year, now.month, now.day - 1, 18),
  to: now,
);

/// Замеры SpO₂ в окне ночи 23:00–08:00 (ночь, закончившаяся сегодня утром;
/// до 08:00 — уже идущая).
List<HkSample> spo2InWindow(List<HkSample> xs, DateTime now) {
  final from = DateTime(now.year, now.month, now.day - 1, 23);
  final to = DateTime(now.year, now.month, now.day, 8);
  return [
    for (final x in xs)
      if (!x.s.isBefore(from) && !x.s.isAfter(to)) x,
  ];
}

/// SpO₂ ночью, % (медиана; HealthKit отдаёт долю 0…1). Нужно ≥ 3 замеров.
double? spo2Median(List<HkSample> xs, DateTime now) {
  final w = spo2InWindow(xs, now);
  if (w.length < 3) return null;
  final m = percentile([for (final x in w) x.v <= 1.0 ? x.v * 100 : x.v], .5);
  return m;
}

/// Сон Watch, мин: стадии asleepUnspecified(1)/Core(3)/Deep(4)/REM(5) с
/// [from], пересечения слиты; «в кровати»(0) и «бодрствование»(2) не считаются.
int? watchAsleepMin(List<HkSample> xs, DateTime from) {
  final iv = [
    for (final x in xs)
      if (!x.e.isBefore(from) && const {1, 3, 4, 5}.contains(x.v.round()))
        (x.s, x.e),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (iv.isEmpty) return null;
  var total = 0;
  var (cs, ce) = iv.first;
  for (final (s, e) in iv.skip(1)) {
    if (!s.isAfter(ce)) {
      if (e.isAfter(ce)) ce = e;
    } else {
      total += ce.difference(cs).inMinutes;
      cs = s;
      ce = e;
    }
  }
  total += ce.difference(cs).inMinutes;
  return total > 0 ? total : null;
}

/// Отклонение температуры запястья последней ночи от медианы прошлых
/// (нужно ≥ 5 прошлых ночей; последняя — закончилась не раньше 18:00 вчера).
double? wristTempDev(List<HkSample> xs, DateTime now) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort((a, b) => a.e.compareTo(b.e));
  final last = s.last;
  if (last.e.isBefore(nightWindow(now).from)) return null;
  final prev = [for (final x in s.sublist(0, s.length - 1)) x.v];
  if (prev.length < 5) return null;
  return last.v - percentile(prev, .5)!;
}

// ───────────────────────── VO₂max: перцентили ACSM ─────────────────────────

/// p25 / p50 / p75 VO₂max (мл/кг/мин) по возрасту и полу — ориентиры ACSM
/// (Cooper Institute), десятилетия 20–29 … 70+.
const _vo2Men = [
  (40.1, 44.2, 48.0),
  (37.4, 41.0, 44.6),
  (34.6, 38.4, 42.4),
  (31.4, 35.2, 39.3),
  (28.0, 31.8, 35.9),
  (25.6, 28.7, 32.3),
];
const _vo2Women = [
  (33.0, 37.0, 41.0),
  (30.9, 34.6, 38.6),
  (29.0, 32.3, 36.3),
  (26.3, 29.4, 32.8),
  (23.6, 26.6, 29.7),
  (21.5, 24.6, 27.2),
];

/// Перцентильная зона VO₂max: 3 — ≥ p75, 2 — p50–75, 1 — p25–50, 0 — < p25.
int vo2Zone(double vo2, {required int age, bool female = false}) {
  final i = ((age.clamp(20, 79) - 20) ~/ 10).clamp(0, 5);
  final (p25, p50, p75) = (female ? _vo2Women : _vo2Men)[i];
  if (vo2 >= p75) return 3;
  if (vo2 >= p50) return 2;
  if (vo2 >= p25) return 1;
  return 0;
}

/// «отлично для 42 лет» / «хорошо для 42 лет» / … ; без возраста — null.
String? vo2Word(double vo2, {int? age, bool female = false}) {
  if (age == null || age < 18) return null;
  final w = switch (vo2Zone(vo2, age: age, female: female)) {
    3 => 'отлично',
    2 => 'хорошо',
    1 => 'средне',
    _ => 'ниже среднего',
  };
  return '$w для $age ${_years(age)}';
}

String _years(int n) {
  final a = n % 100, b = n % 10;
  if (a >= 11 && a <= 14) return 'лет';
  if (b == 1) return 'года';
  if (b >= 2 && b <= 4) return 'лет';
  return 'лет';
}

/// Изменение VO₂max к замеру ~30 дней назад (ближайший не позже 21 дня назад).
double? vo2DeltaMonth(List<HkSample> series) {
  if (series.length < 2) return null;
  final last = series.last;
  HkSample? ref;
  for (final x in series.reversed.skip(1)) {
    if (last.e.difference(x.e).inDays >= 21) {
      ref = x;
      break;
    }
  }
  return ref == null ? null : last.v - ref.v;
}

// ───────────────────────── ЭКГ (§4.5, §10.12) ─────────────────────────

/// Строка списка ЭКГ (браслет и Watch вперемешку).
class EcgItem {
  final DateTime at;
  final String text;

  /// «браслет» / «Apple Watch».
  final String source;
  final bool attention;
  const EcgItem(this.at, this.text, this.source, {this.attention = false});
}

/// Классификация Watch словами. Слово «фибрилляция» не пишем.
({String text, bool attention}) watchEcgText(String cls, double? hr) {
  final h = hr == null ? '' : ' · ${hr.round()}';
  return switch (cls) {
    'sinusRhythm' => (text: 'Синусовый ритм$h', attention: false),
    'atrialFibrillation' => (
      text: 'Нерегулярный ритм — покажите врачу',
      attention: true,
    ),
    'inconclusiveLowHeartRate' => (text: 'Запись неясная (низкий пульс) — повторите', attention: false),
    'inconclusiveHighHeartRate' => (text: 'Запись неясная (высокий пульс) — повторите', attention: false),
    'inconclusivePoorReading' => (text: 'Запись неясная — повторите', attention: false),
    _ => (text: 'Запись неясная — повторите', attention: false),
  };
}

/// Неясная/нечитаемая запись — серая точка (не «всё хорошо»).
bool ecgUnclear(String text) => text.startsWith('Запись неясная');

/// Категория браслета (Edge `EcgCategory.name`) словами.
({String text, bool attention}) bandEcgText(String category, int? hr) {
  final h = hr == null ? '' : ' · $hr';
  return switch (category) {
    'sinusRhythm' => (text: 'Синусовый ритм$h', attention: false),
    'lowHeartRate' => (text: 'Низкий пульс$h', attention: false),
    'possibleAfib' || 'afibHighHeartRate' => (
      text: 'Нерегулярный ритм — покажите врачу',
      attention: true,
    ),
    'highHeartRate' || 'highHeartRateNoAfib' => (
      text: 'Высокий пульс$h',
      attention: false,
    ),
    'unreadable' => (text: 'Запись неясная — повторите', attention: false),
    _ => (text: 'Запись неясная — повторите', attention: false),
  };
}

/// Список ЭКГ: браслет + Watch, новые сверху, не больше [limit].
List<EcgItem> mergeEcg({
  required List<({DateTime at, String category, int? hr})> band,
  required List<HkEcg> watch,
  int limit = 5,
}) {
  final out = <EcgItem>[
    for (final b in band)
      () {
        final t = bandEcgText(b.category, b.hr);
        return EcgItem(b.at, t.text, 'браслет', attention: t.attention);
      }(),
    for (final w in watch)
      () {
        final t = watchEcgText(w.cls, w.hr);
        return EcgItem(w.at, t.text, 'Apple Watch', attention: t.attention);
      }(),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return out.length > limit ? out.sublist(0, limit) : out;
}

// ───────────────────────── тренировки: классификатор §10.6 ─────────────────────────

/// Одна секунда браслета для классификатора.
class WkSec {
  final int ts;
  final int? hr;
  final bool valid;

  /// activity_class Edge: 1 — ходьба, 2 — бег.
  final int? cls;

  /// Каденс шагов/мин (step_cadence) — null, если браслет не дал.
  final int? cadence;

  /// Движение по акселерометру (ENMO, g).
  final double? enmo;
  const WkSec(
    this.ts, {
    this.hr,
    this.valid = true,
    this.cls,
    this.cadence,
    this.enmo,
  });
}

enum WkType { run, walk, cardio, strength, other }

/// Ключ типа Edge (каталог активностей).
String wkTypeKey(WkType t) => switch (t) {
  WkType.run => 'running',
  WkType.walk => 'walking',
  WkType.cardio => 'elliptical',
  WkType.strength => 'weight_training',
  WkType.other => 'other',
};

/// «бег» / «ходьба» / «кардио» / «силовая» — для «ДА, БЕГ».
String wkTypeWord(WkType t) => switch (t) {
  WkType.run => 'бег',
  WkType.walk => 'ходьба',
  WkType.cardio => 'кардио',
  WkType.strength => 'силовая',
  WkType.other => 'тренировка',
};

/// «Это был бег?» / «Это была ходьба?» / «Это было кардио?» /
/// «Это была силовая?» / «Это была тренировка?».
String wkQuestion(WkType t) => switch (t) {
  WkType.run => 'Это был бег?',
  WkType.walk => 'Это была ходьба?',
  WkType.cardio => 'Это было кардио?',
  WkType.strength => 'Это была силовая?',
  WkType.other => 'Это была тренировка?',
};

/// Тип по ключу Edge (для подписей у пендингов Edge).
WkType? wkTypeOfKey(String? k) => switch ((k ?? '').toLowerCase()) {
  'running' || 'treadmill' => WkType.run,
  'walking' || 'hiking' => WkType.walk,
  'elliptical' || 'indoor_bike' || 'cycling' || 'rowing' => WkType.cardio,
  'weight_training' || 'powerlifting' || 'crossfit' || 'kettlebell' =>
    WkType.strength,
  _ => null,
};

/// Найденная браслетом тренировка.
class WkCandidate {
  final int from, to; // unix, с
  final WkType type;
  final int avgHr;

  /// Жёсткий ярус (Edge, с пушем) — HR ≥ max(RHR+40, RHR+0,45·HRR) ≥ 12 мин;
  /// иначе мягкий (карточка без пуша).
  final bool hard;

  /// Доля секунд с валидным пульсом браслета (для сверки с Watch).
  final double validShare;
  const WkCandidate(
    this.from,
    this.to,
    this.type,
    this.avgHr, {
    this.hard = false,
    this.validShare = 1,
  });

  int get minutes => (to - from) ~/ 60;
}

class _Min {
  final int t;
  final double? hr;
  final int valid, n;
  final int? cls;
  final double? cad;
  final bool moving;
  _Min(this.t, this.hr, this.valid, this.n, this.cls, this.cad, this.moving);
}

/// Порог мягкого яруса и жёсткого (уд/мин) по пульсу покоя и HRmax.
({double soft, double hard}) wkThresholds(double rhr, double hrMax) {
  final hrr = math.max(hrMax - rhr, 1.0);
  return (
    soft: rhr + 0.30 * hrr,
    hard: math.max(rhr + 40, rhr + 0.45 * hrr),
  );
}

List<_Min> _minutes(List<WkSec> secs) {
  if (secs.isEmpty) return const [];
  final s = [...secs]..sort((a, b) => a.ts.compareTo(b.ts));
  final out = <_Min>[];
  var i = 0;
  while (i < s.length) {
    final m0 = s[i].ts - s[i].ts % 60;
    final hrs = <int>[];
    final cls = <int, int>{};
    final cad = <int>[];
    var n = 0, moving = 0;
    while (i < s.length && s[i].ts < m0 + 60) {
      final x = s[i];
      n++;
      if (x.valid && x.hr != null && x.hr! > 30) hrs.add(x.hr!);
      if (x.cls != null) cls[x.cls!] = (cls[x.cls!] ?? 0) + 1;
      if (x.cadence != null) cad.add(x.cadence!);
      if ((x.cls ?? 0) >= 1 ||
          (x.cadence ?? 0) > 0 ||
          (x.enmo ?? 0) > 0.05) {
        moving++;
      }
      i++;
    }
    int? topCls;
    if (cls.isNotEmpty) {
      topCls = cls.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }
    out.add(
      _Min(
        m0,
        hrs.length >= 20 ? hrs.reduce((a, b) => a + b) / hrs.length : null,
        hrs.length,
        n,
        topCls,
        cad.isEmpty ? null : percentile(cad.map((e) => e.toDouble()), .5),
        moving * 3 >= n,
      ),
    );
  }
  return out;
}

/// Тип по минутам тренировки (§10.6).
WkType classifyMinutes(
  List<WkSec> secs, {
  required double rhr,
  required double hrMax,
}) {
  final ms = _minutes(secs);
  if (ms.isEmpty) return WkType.other;
  final hrr = math.max(hrMax - rhr, 1.0);
  final n = ms.length;
  final run = ms.where((m) => m.cls == 2).length / n;
  final walk = ms.where((m) => m.cls == 1).length / n;
  final cads = [for (final m in ms) ?m.cad];
  final cad = cads.isEmpty ? 0.0 : percentile(cads, .5)!;
  final hrs = [
    for (final x in secs)
      if (x.valid && x.hr != null && x.hr! > 30) x.hr!.toDouble(),
  ];
  final avg = mean(hrs) ?? 0;
  final sd = hrs.length < 2
      ? 0.0
      : math.sqrt(
          hrs.map((h) => (h - avg) * (h - avg)).reduce((a, b) => a + b) /
              (hrs.length - 1),
        );
  final cv = avg > 0 ? sd / avg : 0.0;
  if (run >= 0.5 || cad >= 150) return WkType.run;
  if (walk >= 0.6 &&
      cad >= 90 &&
      cad <= 130 &&
      avg < rhr + 0.6 * hrr) {
    return WkType.walk;
  }
  final fewSteps = cad < 20;
  if (fewSteps && cv < 0.12) return WkType.cardio;
  if (fewSteps && cv >= 0.15 && hrPeaks(secs) >= 4) return WkType.strength;
  return WkType.other;
}

/// Пики пульса с падением ≥ [drop] уд/мин (по средним 15 с) — подходы
/// силовой.
int hrPeaks(List<WkSec> secs, {double drop = 15}) {
  final s = [...secs]..sort((a, b) => a.ts.compareTo(b.ts));
  final bins = <double>[];
  var i = 0;
  while (i < s.length) {
    final b0 = s[i].ts - s[i].ts % 15;
    final v = <int>[];
    while (i < s.length && s[i].ts < b0 + 15) {
      if (s[i].valid && s[i].hr != null) v.add(s[i].hr!);
      i++;
    }
    if (v.isNotEmpty) bins.add(v.reduce((a, b) => a + b) / v.length);
  }
  if (bins.isEmpty) return 0;
  var peaks = 0;
  var seekingPeak = true;
  var hi = bins.first, lo = bins.first;
  for (final x in bins.skip(1)) {
    if (seekingPeak) {
      if (x > hi) hi = x;
      if (x <= hi - drop) {
        peaks++;
        seekingPeak = false;
        lo = x;
      }
    } else {
      if (x < lo) lo = x;
      if (x >= lo + drop) {
        seekingPeak = true;
        hi = x;
      }
    }
  }
  return peaks;
}

/// Поиск тренировок по секундам браслета (§10.6): отрезки минут с пульсом
/// ≥ порога мягкого яруса (паузы до 2 мин допускаются) и движением; мягкий —
/// ≥ 20 мин, жёсткий — внутри ≥ 12 мин подряд выше жёсткого порога.
/// [sleep] — интервалы сна (там тренировок не ищем).
List<WkCandidate> detectWorkouts(
  List<WkSec> secs, {
  required double rhr,
  required double hrMax,
  List<({int from, int to})> sleep = const [],
}) {
  final th = wkThresholds(rhr, hrMax);
  final ms = _minutes(secs);
  bool asleep(int t) => sleep.any((s) => t >= s.from && t < s.to);
  final out = <WkCandidate>[];
  var i = 0;
  while (i < ms.length) {
    if (!(ms[i].hr != null && ms[i].hr! >= th.soft && !asleep(ms[i].t))) {
      i++;
      continue;
    }
    var j = i, gap = 0, lastHit = i;
    while (j + 1 < ms.length) {
      final m = ms[j + 1];
      final contiguous = m.t - ms[j].t <= 60;
      final hit = m.hr != null && m.hr! >= th.soft && !asleep(m.t);
      if (!contiguous) break;
      if (hit) {
        gap = 0;
        lastHit = j + 1;
      } else {
        gap++;
        if (gap > 2) break;
      }
      j++;
    }
    final seg = ms.sublist(i, lastHit + 1);
    final from = seg.first.t, to = seg.last.t + 60;
    final moving = seg.where((m) => m.moving).length / seg.length;
    if (seg.length >= 12 && moving >= 0.5) {
      var run = 0, best = 0;
      for (final m in seg) {
        run = (m.hr != null && m.hr! >= th.hard) ? run + 1 : 0;
        best = math.max(best, run);
      }
      final hard = best >= 12;
      if (hard || seg.length >= 20) {
        final secsIn = [
          for (final x in secs)
            if (x.ts >= from && x.ts < to) x,
        ];
        final hrs = [
          for (final m in seg) ?m.hr,
        ];
        final valid = seg.fold<int>(0, (a, m) => a + m.valid);
        out.add(
          WkCandidate(
            from,
            to,
            classifyMinutes(secsIn, rhr: rhr, hrMax: hrMax),
            (mean(hrs) ?? 0).round(),
            hard: hard,
            validShare: (valid / (to - from)).clamp(0.0, 1.0),
          ),
        );
      }
    }
    i = lastHit + 1;
  }
  return out;
}

// ───────────────────────── приоритет Watch (§6, §10.6) ─────────────────────────

/// Доля времени [from, to) отрезка браслета, покрытая тренировкой Watch.
double overlapShare(DateTime from, DateTime to, DateTime wFrom, DateTime wTo) {
  final a = from.isAfter(wFrom) ? from : wFrom;
  final b = to.isBefore(wTo) ? to : wTo;
  final len = to.difference(from).inSeconds;
  if (len <= 0 || !b.isAfter(a)) return 0;
  return b.difference(a).inSeconds / len;
}

/// Тренировка Watch, перекрывающая отрезок браслета ≥ 50 % (или null).
HkWorkout? watchMatch(DateTime from, DateTime to, List<HkWorkout> watch) {
  HkWorkout? best;
  var bestShare = 0.0;
  for (final w in watch) {
    final sh = overlapShare(from, to, w.s, w.e);
    if (sh >= 0.5 && sh > bestShare) {
      best = w;
      bestShare = sh;
    }
  }
  return best;
}

/// Что делать с тренировкой, найденной браслетом.
enum WkAction {
  /// Есть тренировка Watch ≥ 50 % — карточку не показываем, подтверждаем
  /// автоматически с типом/дистанцией Watch.
  autoWatch,

  /// Карточка «Это был бег?» (жёсткий ярус — ещё и пуш Edge).
  ask,

  /// Пользователь уже ответил «Нет» — повторно не предлагаем.
  dismissed,
}

WkAction wkAction(
  DateTime from,
  DateTime to, {
  required List<HkWorkout> watch,
  Set<int> dismissed = const {},
}) {
  if (watchMatch(from, to, watch) != null) return WkAction.autoWatch;
  if (dismissed.contains(from.millisecondsSinceEpoch ~/ 1000)) {
    return WkAction.dismissed;
  }
  return WkAction.ask;
}

/// Ключ типа Edge по `HKWorkoutActivityType.rawValue`.
String hkTypeKey(int raw) => switch (raw) {
  37 => 'running',
  52 => 'walking',
  24 => 'hiking',
  13 => 'cycling',
  46 => 'swimming',
  35 => 'rowing',
  16 => 'elliptical',
  50 || 20 => 'weight_training',
  11 => 'crossfit',
  63 => 'hiit',
  57 => 'yoga',
  _ => 'other',
};

/// Название тренировки Watch по-русски.
String hkTypeName(int raw) => switch (raw) {
  37 => 'Бег',
  52 => 'Ходьба',
  24 => 'Поход',
  13 => 'Велосипед',
  46 => 'Плавание',
  35 => 'Гребля',
  16 => 'Эллипс',
  50 || 20 => 'Силовая',
  11 => 'Кроссфит',
  63 => 'Интервальная',
  57 => 'Йога',
  _ => 'Тренировка',
};

/// «7,24 км» / «850 м».
String distRu(double m) {
  if (m < 1000) return '${m.round()} м';
  final km = (m / 10).round() / 100;
  return '${km.toStringAsFixed(2).replaceAll('.', ',')} км';
}

// ───────────────────────── сверка §10.9 ─────────────────────────

/// Температура: оба в коридоре ±0,3 — совпадают («оба в норме»); один
/// отклонён — совпадают, если знак отклонения одинаков, иначе расходятся.
Agree reconcileTemp(double band, double watch) {
  final bn = band.abs() < 0.3, wn = watch.abs() < 0.3;
  if (bn && wn) return Agree.match;
  if (band.sign == watch.sign && band.sign != 0) return Agree.match;
  return Agree.differ;
}

String tempWords(double band, double watch) {
  final a = reconcileTemp(band, watch);
  if (band.abs() < 0.3 && watch.abs() < 0.3) return 'оба в норме';
  return a == Agree.match ? 'оба выше обычного' : 'расходятся';
}

/// Пульс тренировки: у кого больше доля валидных секунд, тот точнее.
/// [bandShare] — доля секунд с валидным пульсом браслета; [watchN] — число
/// замеров Watch (каждый ≈ 5 с).
({String winner, double bandShare, double watchShare}) workoutHrWinner({
  required double bandShare,
  required int watchN,
  required int seconds,
}) {
  final ws = seconds <= 0 ? 0.0 : (watchN * 5 / seconds).clamp(0.0, 1.0);
  final bs = bandShare.clamp(0.0, 1.0);
  final winner = (ws - bs).abs() < 0.05
      ? 'оба'
      : (ws > bs ? 'Watch' : 'браслет');
  return (winner: winner, bandShare: bs, watchShare: ws);
}

/// Строка сверки тренировки: «пульс ср. браслет 138 · Watch 146 · точнее Watch».
String workoutHrLine({
  required int bandAvg,
  required int watchAvg,
  required String winner,
}) {
  final w = switch (winner) {
    'Watch' => 'точнее Watch (больше секунд с пульсом)',
    'браслет' => 'точнее браслет (больше секунд с пульсом)',
    _ => 'оба записали всю тренировку',
  };
  return 'пульс ср. браслет $bandAvg · Watch $watchAvg · $w';
}

// ───────────────────────── шаги §10.10 ─────────────────────────

const kWatchStepsHours = 12;

/// Шаги дня без сложения источников (§10.10): Watch, если он носился ≥ 12 ч
/// (часы, в которые от Watch есть шаги); иначе браслет — в том числе утром,
/// пока 12 ч не набралось; телефон — когда браслет снят.
({num? value, String source}) ritmSteps({
  double? watch,
  int watchHours = 0,
  num? band,
  num? phone,
  bool bandWorn = true,
  required DateTime now,
  bool today = true,
}) {
  if (watch != null && watch > 0 && watchHours >= kWatchStepsHours) {
    return (value: watch.round(), source: 'Apple Watch');
  }
  if (band != null && bandWorn) return (value: band, source: 'браслет');
  if (phone != null) return (value: phone, source: 'телефон');
  if (band != null) return (value: band, source: 'браслет');
  return (value: null, source: '');
}

// ───────────────────────── запись в «Здоровье» §10.11 ─────────────────────────

/// Тренировку браслета пишем в «Здоровье», только если за это время нет
/// тренировки Apple Watch (иначе в «Фитнесе» будет две).
bool ritmMayWriteWorkout(
  DateTime from,
  DateTime to,
  List<HkWorkout> watch,
) => !watch.any((w) => overlapShare(from, to, w.s, w.e) > 0);

/// Калории пишем, только если включено и нет Watch (иначе кольца
/// Активности удвоятся).
bool ritmMayWriteEnergy({required bool toggle, required bool watchPresent}) =>
    toggle && !watchPresent;
