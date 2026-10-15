// «Ритм» — биовозраст и темп старения (ТЗ v2 §10.7, §4.1–4.2, сборка B4).
//
// Чистые функции без Flutter: вход — дневные ряды (браслет, Watch, профиль),
// выход — вклады, биовозраст, темп. Всё помечается словом «оценка».
//
// Формула §10.7:
//   окно — 30 дней, нужно ≥ 14 дней с данными;
//   8 вкладов (годы) по таблицам ниже; n_present — сколько вкладов посчитано
//   (≥ 5, иначе числа нет);
//   Δ_день = Σвкладов × 8 / n_present, clamp [−10; +10];
//   биовозраст = паспортный возраст + EMA(α = 0,1) от Δ по дням; шаг EMA за
//   день не больше 0,1 года (критерий «меняется не более чем на 0,1 в день»).
//   EMA ведём по каждому вкладу отдельно (EMA линейна), поэтому сглаженные
//   вклады на детальном экране складываются ровно в Δ = биовозраст − возраст.
//   Темп = 1 + (БВ_сегодня − БВ_28 дн. назад) / (28/365), clamp [−1; 3];
//   «медленнее/быстрее, чем неделю назад» — темп против темпа 7 дней назад,
//   порог 0,1x.

import 'dart:math' as math;

import 'ritm_hk.dart' show vo2Zone;

/// Окно средних и минимум дней с данными.
const int kBioWindow = 30;
const int kBioMinDays = 14;

/// Минимум посчитанных вкладов.
const int kBioMinPresent = 5;

const double kBioAlpha = 0.1;
const double kBioMaxStep = 0.1;
const double kPaceMin = -1, kPaceMax = 3;

/// Полных лет на дату [on] (день рождения в этот день — уже исполнилось).
int ageOn(DateTime birth, DateTime on) {
  var a = on.year - birth.year;
  if (on.month < birth.month ||
      (on.month == birth.month && on.day < birth.day)) {
    a--;
  }
  return a;
}

/// Возраст в годах с долями (для биовозраста): полные годы + доля года,
/// прошедшая с последнего дня рождения.
double ageYears(DateTime birth, DateTime on) {
  final full = ageOn(birth, on);
  final last = _birthdayIn(birth, birth.year + full);
  final next = _birthdayIn(birth, birth.year + full + 1);
  final d0 = DateTime(on.year, on.month, on.day);
  final frac = d0.difference(last).inDays / next.difference(last).inDays;
  return full + frac.clamp(0.0, 1.0);
}

DateTime _birthdayIn(DateTime b, int year) {
  // 29 февраля в невисокосный год — 28 февраля.
  final lastDay = DateTime(year, b.month + 1, 0).day;
  return DateTime(year, b.month, math.min(b.day, lastDay));
}

/// «1989-03-21» → дата; null — нет/не разобрать.
DateTime? parseBirth(Object? v) {
  if (v == null) return null;
  final d = DateTime.tryParse('$v');
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day);
}

String birthIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Один день входных данных. Null — нет данных за день.
class BioDay {
  final DateTime day;

  /// Сон, мин.
  final double? sleepMin;

  /// Засыпание и подъём — минуты от полуночи дня засыпания (может быть > 1440
  /// или < 0 для ночей через полночь; важна только разброс).
  final double? onsetMin, wakeMin;
  final double? steps;

  /// Минуты зон 1–3 и 4–5 за день.
  final double? z13, z45;

  /// Минуты силовых за день (0 — тренировки были, но не силовые / не было).
  final double? strength;
  final double? rhr;

  /// Последний VO₂max Watch на этот день.
  final double? vo2;
  const BioDay(
    this.day, {
    this.sleepMin,
    this.onsetMin,
    this.wakeMin,
    this.steps,
    this.z13,
    this.z45,
    this.strength,
    this.rhr,
    this.vo2,
  });

  /// День «с данными» — браслет был на руке (сон или пульс покоя).
  bool get hasData => sleepMin != null || rhr != null;
}

enum BioKey { sleep, regular, steps, z13, z45, strength, vo2, rhr }

const kBioOrder = BioKey.values;

String bioName(BioKey k) => switch (k) {
  BioKey.sleep => 'Сон',
  BioKey.regular => 'Режим сна',
  BioKey.steps => 'Шаги',
  BioKey.z13 => 'Зоны 1–3',
  BioKey.z45 => 'Зоны 4–5',
  BioKey.strength => 'Силовые',
  BioKey.vo2 => 'VO₂max',
  BioKey.rhr => 'Пульс покоя',
};

/// Подпись источника.
String bioSource(BioKey k) => switch (k) {
  BioKey.vo2 => 'Watch',
  BioKey.steps => 'браслет',
  _ => 'браслет',
};

/// Вклад одного фактора в окне.
class BioPart {
  final BioKey key;

  /// Значение фактора словами: «7:38 в среднем», «6 900 в день».
  final String value;

  /// Вклад по таблице §10.7 (годы), null — фактора нет.
  final double? table;
  const BioPart(this.key, this.value, this.table);
  bool get present => table != null;
}

// ───────────────────────── таблицы §10.7 ─────────────────────────

/// Сон: 7–8 ч → 0; −1,5/ч ниже 7 (до +4; т. е. вклад растёт), +0,5/ч выше 9.
double sleepYears(double hours) {
  if (hours < 7) return math.min(4, 1.5 * (7 - hours));
  if (hours > 9) return 0.5 * (hours - 9);
  return 0;
}

/// Режим: SD отбоя+подъёма ≤ 30 → −1, 30–60 → 0, 60–90 → +1, > 90 → +2.
double regularYears(double sdMin) {
  if (sdMin <= 30) return -1;
  if (sdMin <= 60) return 0;
  if (sdMin <= 90) return 1;
  return 2;
}

/// Шаги/день: ≥ 8 000 → −1,5; 5–8 тыс. → 0; 3–5 → +1; < 3 → +2.
double stepsYears(double steps) {
  if (steps >= 8000) return -1.5;
  if (steps >= 5000) return 0;
  if (steps >= 3000) return 1;
  return 2;
}

/// Зоны 1–3 в неделю: ≥ 150 → −1,5; 75–150 → 0; < 75 → +1.
double z13Years(double minWeek) {
  if (minWeek >= 150) return -1.5;
  if (minWeek >= 75) return 0;
  return 1;
}

/// Зоны 4–5 в неделю: ≥ 75 → −1,5; 30–75 → −0,5; < 30 → 0.
double z45Years(double minWeek) {
  if (minWeek >= 75) return -1.5;
  if (minWeek >= 30) return -0.5;
  return 0;
}

/// Силовые в неделю: ≥ 60 → −1; 30–60 → −0,5; 0 → +0,5; 1–29 → 0.
double strengthYears(double minWeek) {
  if (minWeek >= 60) return -1;
  if (minWeek >= 30) return -0.5;
  if (minWeek <= 0) return 0.5;
  return 0;
}

/// VO₂max по перцентилям ACSM: ≥ p75 → −3; p50–75 → −1,5; p25–50 → 0; < p25 → +2.
double vo2Years(double vo2, {required int age, bool female = false}) =>
    switch (vo2Zone(vo2, age: age, female: female)) {
      3 => -3,
      2 => -1.5,
      1 => 0,
      _ => 2,
    };

/// Пульс покоя: ≤ 55 → −1,5; 56–65 → 0; 66–75 → +1; > 75 → +2,5.
double rhrYears(double rhr) {
  final r = rhr.round();
  if (r <= 55) return -1.5;
  if (r <= 65) return 0;
  if (r <= 75) return 1;
  return 2.5;
}

double? _mean(Iterable<double?> xs) {
  final v = xs.whereType<double>().toList();
  if (v.isEmpty) return null;
  return v.reduce((a, b) => a + b) / v.length;
}

double? _sd(List<double> xs) {
  if (xs.length < 3) return null;
  final m = xs.reduce((a, b) => a + b) / xs.length;
  final s = xs.fold<double>(0, (a, x) => a + (x - m) * (x - m));
  return math.sqrt(s / (xs.length - 1));
}

String _hm(double min) {
  final m = min.round();
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
}

String _thousands(num v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('\u202F');
    b.write(s[i]);
  }
  return b.toString();
}

String _dec1(num v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Восемь вкладов по окну дней (≤ 30, последние — в конце).
List<BioPart> bioParts(
  List<BioDay> window, {
  required int age,
  bool female = false,
}) {
  final worn = window.where((d) => d.hasData).length;
  final weeks = math.max(1, worn) / 7;
  final sleep = _mean(window.map((d) => d.sleepMin));
  final onsets = [for (final d in window) ?d.onsetMin];
  final wakes = [for (final d in window) ?d.wakeMin];
  final sdOn = _sd(onsets), sdWake = _sd(wakes);
  final sd = sdOn == null || sdWake == null ? null : (sdOn + sdWake) / 2;
  final steps = _mean(window.map((d) => d.steps));
  final zDays = window.where((d) => d.z13 != null || d.z45 != null).length;
  final z13 = zDays == 0
      ? null
      : window.fold<double>(0, (a, d) => a + (d.z13 ?? 0)) / weeks;
  final z45 = zDays == 0
      ? null
      : window.fold<double>(0, (a, d) => a + (d.z45 ?? 0)) / weeks;
  final strDays = window.where((d) => d.strength != null).length;
  final str = strDays == 0
      ? null
      : window.fold<double>(0, (a, d) => a + (d.strength ?? 0)) / weeks;
  double? vo2;
  for (final d in window.reversed) {
    if (d.vo2 != null) {
      vo2 = d.vo2;
      break;
    }
  }
  final rhr = _mean(window.map((d) => d.rhr));
  return [
    BioPart(
      BioKey.sleep,
      sleep == null ? 'нет данных' : '${_hm(sleep)} в среднем',
      sleep == null ? null : sleepYears(sleep / 60),
    ),
    BioPart(
      BioKey.regular,
      sd == null ? 'нет данных' : 'разброс ±${sd.round()} мин',
      sd == null ? null : regularYears(sd),
    ),
    BioPart(
      BioKey.steps,
      steps == null ? 'нет данных' : '${_thousands(steps)} в день',
      steps == null ? null : stepsYears(steps),
    ),
    BioPart(
      BioKey.z13,
      z13 == null ? 'нет данных' : '${_hm(z13)} в неделю · в ср. за 30 дн.',
      z13 == null ? null : z13Years(z13),
    ),
    BioPart(
      BioKey.z45,
      z45 == null ? 'нет данных' : '${_hm(z45)} в неделю · в ср. за 30 дн.',
      z45 == null ? null : z45Years(z45),
    ),
    BioPart(
      BioKey.strength,
      str == null ? 'нет данных' : '${_hm(str)} в неделю · в ср. за 30 дн.',
      str == null ? null : strengthYears(str),
    ),
    BioPart(
      BioKey.vo2,
      vo2 == null ? 'нет источника: нужны Apple Watch' : '${_dec1(vo2)} · Watch',
      vo2 == null ? null : vo2Years(vo2, age: age, female: female),
    ),
    BioPart(
      BioKey.rhr,
      rhr == null ? 'нет данных' : '${rhr.round()} уд/мин в среднем',
      rhr == null ? null : rhrYears(rhr),
    ),
  ];
}

/// Δ за день по вкладам: каждый × 8/n_present; при |Σ| > 10 — все
/// пропорционально сжаты до ±10. Null — n_present < 5.
List<double>? bioScaled(List<BioPart> parts) {
  final n = parts.where((p) => p.present).length;
  if (n < kBioMinPresent) return null;
  final k = 8 / n;
  final v = [for (final p in parts) (p.table ?? 0) * k];
  final sum = v.fold<double>(0, (a, b) => a + b);
  if (sum.abs() > 10) {
    final s = 10 / sum.abs();
    return [for (final x in v) x * s];
  }
  return v;
}

enum BioState { ready, calibrating, noProfile, noData }

/// Итог для экрана.
class BioResult {
  final BioState state;

  /// Дней с данными в окне (для «6/14»).
  final int have;

  /// Паспортный возраст (с долями) на сегодня.
  final double? age;

  /// Биовозраст (оценка) = age + Σ parts (по округлённым до 0,1 вкладам).
  final double? bio;

  /// Вклады за последние 30 дней (годы, ×8/n_present, до 0,1) в порядке
  /// [kBioOrder]; Σparts + [smooth] = bio − age.
  final List<double> parts;

  /// Сглаживание по дням (EMA): сглаженная разница − сегодняшняя сумма.
  final double smooth;

  /// Сырые вклады окна сегодня (таблица §10.7) — значения факторов.
  final List<BioPart> today;

  /// Темп старения сегодня и неделю назад; null — истории < 28 дней.
  final double? pace, paceWeekAgo;

  /// Биовозраст по дням (оценка), 90 последних, null — нет числа.
  final List<double?> history;
  const BioResult({
    required this.state,
    this.have = 0,
    this.age,
    this.bio,
    this.parts = const [],
    this.smooth = 0,
    this.today = const [],
    this.pace,
    this.paceWeekAgo,
    this.history = const [],
  });

  /// Разница с паспортом (биовозраст − возраст), округлена как на экране.
  double? get delta => bio == null || age == null
      ? null
      : ((bio! * 10).round() - (age! * 10).round()) / 10;
}

/// Темп по разнице «биовозраст − паспорт» сегодня и 28 дней назад:
/// 1 + (Δ_сегодня − Δ_28)/(28/365), clamp [−1; 3]. Это то же, что прирост
/// биовозраста за 28 дней в годах на календарный год: если разница с
/// паспортом не меняется, биовозраст растёт вместе с календарём — 1,0x.
/// (В ТЗ записано через БВ; буквально от БВ ровная жизнь дала бы 2,0x.)
double paceOf(double deltaNow, double delta28) =>
    (1 + (deltaNow - delta28) / (28 / 365)).clamp(kPaceMin, kPaceMax).toDouble();

/// «медленнее / быстрее, чем неделю назад»: −1 медленнее, 1 быстрее, 0 как.
int paceTrend(double? now, double? weekAgo) {
  if (now == null || weekAgo == null) return 0;
  final d = now - weekAgo;
  if (d <= -0.1) return -1;
  if (d >= 0.1) return 1;
  return 0;
}

/// Округлить вклады до 0,1 так, чтобы сумма округлённых = округлённой сумме
/// (метод наибольших остатков) — на экране вклады складываются в Δ без
/// расхождения в десятых.
List<double> roundTenthsKeepingSum(List<double> xs) {
  final target = (xs.fold<double>(0, (a, b) => a + b) * 10).round();
  final fl = [for (final x in xs) (x * 10).floor()];
  var rest = target - fl.fold<int>(0, (a, b) => a + b);
  final order = List.generate(xs.length, (i) => i)
    ..sort((a, b) => ((xs[b] * 10) - fl[b]).compareTo((xs[a] * 10) - fl[a]));
  final out = [...fl];
  for (final i in order) {
    if (rest <= 0) break;
    out[i]++;
    rest--;
  }
  return [for (final v in out) v / 10];
}

/// Полный расчёт по истории [days] (по возрастанию дат, последний — сегодня).
BioResult computeBio(
  List<BioDay> days, {
  DateTime? birth,
  bool female = false,
}) {
  if (days.isEmpty) return const BioResult(state: BioState.noData);
  final today = days.last.day;
  final lastWin = days.sublist(math.max(0, days.length - kBioWindow));
  final have = lastWin.where((d) => d.hasData).length;
  if (birth == null) {
    return BioResult(state: BioState.noProfile, have: have);
  }
  if (have < kBioMinDays) {
    return BioResult(
      state: BioState.calibrating,
      have: have,
      age: ageYears(birth, today),
    );
  }
  // EMA по каждому вкладу; шаг суммы ≤ 0,1 года в день.
  List<double>? ema;
  final bioByDay = <double?>[];
  // Сглаженная разница с паспортом по дням — для темпа.
  final deltaByDay = <double?>[];
  List<BioPart> todayParts = const [];
  for (var i = 0; i < days.length; i++) {
    final win = days.sublist(math.max(0, i + 1 - kBioWindow), i + 1);
    final age = ageOn(birth, days[i].day);
    final parts = bioParts(win, age: age, female: female);
    if (i == days.length - 1) todayParts = parts;
    final enough = win.where((d) => d.hasData).length >= kBioMinDays;
    final s = enough ? bioScaled(parts) : null;
    if (s != null) {
      if (ema == null) {
        ema = [...s];
      } else {
        final step = [for (var j = 0; j < s.length; j++) kBioAlpha * (s[j] - ema[j])];
        final tot = step.fold<double>(0, (a, b) => a + b);
        final k = tot.abs() > kBioMaxStep ? kBioMaxStep / tot.abs() : 1.0;
        for (var j = 0; j < s.length; j++) {
          ema[j] += step[j] * k;
        }
      }
    }
    deltaByDay.add(ema?.fold<double>(0, (a, b) => a + b));
    bioByDay.add(
      ema == null
          ? null
          : ageYears(birth, days[i].day) + ema.fold<double>(0, (a, b) => a + b),
    );
  }
  if (ema == null) {
    return BioResult(
      state: BioState.calibrating,
      have: have,
      age: ageYears(birth, today),
    );
  }
  final age = ageYears(birth, today);
  final emaSum = ema.fold<double>(0, (a, b) => a + b);
  final tenths = (emaSum * 10).round();
  // Строки детального экрана — вклады сегодняшнего окна по таблице §10.7;
  // разница со сглаженным числом — отдельной строкой «сглаживание».
  final raw = bioScaled(todayParts);
  final parts = raw == null
      ? roundTenthsKeepingSum(ema)
      : roundTenthsKeepingSum(raw);
  final rawTenths = (parts.fold<double>(0, (a, b) => a + b) * 10).round();
  final smooth = (tenths - rawTenths) / 10;
  final bio = ((age * 10).round() + tenths) / 10;
  double? paceAt(int back) {
    final i = deltaByDay.length - 1 - back;
    final j = i - 28;
    if (j < 0 || deltaByDay[i] == null || deltaByDay[j] == null) return null;
    return paceOf(deltaByDay[i]!, deltaByDay[j]!);
  }

  return BioResult(
    state: BioState.ready,
    have: have,
    age: age,
    bio: bio,
    parts: parts,
    smooth: smooth,
    today: todayParts,
    pace: paceAt(0),
    paceWeekAgo: paceAt(7),
    history: bioByDay.length > 90
        ? bioByDay.sublist(bioByDay.length - 90)
        : bioByDay,
  );
}

/// «на 2,8 года моложе» / «на 1,1 года старше» / «как по паспорту».
String bioDeltaText(double delta) {
  final a = delta.abs();
  if (a < 0.05) return 'как по паспорту';
  final word = _yearsWord(a);
  final t = (a * 10).round();
  final n = t % 10 == 0 ? '${t ~/ 10}' : _dec1(a);
  return delta < 0 ? 'на $n $word моложе' : 'на $n $word старше';
}

/// Дробные — «года»; целые — 1 год, 2 года, 5 лет.
String _yearsWord(double a) {
  final t = (a * 10).round();
  if (t % 10 != 0) return 'года';
  final n = t ~/ 10;
  final m100 = n % 100, m10 = n % 10;
  if (m100 >= 11 && m100 <= 14) return 'лет';
  if (m10 == 1) return 'год';
  if (m10 >= 2 && m10 <= 4) return 'года';
  return 'лет';
}

/// Вклад словами: «−0,6 года», «0», «+1 год».
String bioPartText(double years) {
  final t = (years * 10).round();
  if (t == 0) return '0';
  final a = t.abs() / 10;
  final num = t % 10 == 0 ? '${t.abs() ~/ 10}' : _dec1(a);
  return '${t < 0 ? '−' : '+'}$num ${_yearsWord(a)}';
}

/// «0,6x» для темпа.
String paceText(double p) =>
    '${p < 0 ? '−' : ''}${_dec1(p.abs())}x';

/// Цвет-зона облака: −1 зелёный (Δ ≤ −1), 0 бренд, 1 жёлтый (Δ ≥ +1).
int bioZone(double delta) => delta <= -1 ? -1 : (delta >= 1 ? 1 : 0);
