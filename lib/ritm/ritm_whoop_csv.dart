// «Ритм» B4½ — разбор официального экспорта WHOOP (ТЗ v3 §8.1).
//
// WHOOP присылает zip с четырьмя CSV (заголовки — как в «Мои данные»):
//   physiological_cycles.csv — Cycle start/end, Recovery score %, Resting heart
//       rate (bpm), Heart rate variability (ms), Skin temp (celsius), Blood
//       oxygen %, Day Strain, Energy burned (cal), Max/Average HR (bpm), Sleep
//       onset, Wake onset, Sleep performance %, Respiratory rate (rpm),
//       Asleep/In bed/Light sleep/Deep (SWS)/REM/Awake duration (min), Sleep
//       need (min), Sleep debt (min), Sleep efficiency %, Sleep consistency %;
//   sleeps.csv — те же поля сна + Nap (true/false);
//   workouts.csv — Workout start/end time, Duration (min), Activity name,
//       Activity Strain, Energy burned, Max/Average HR, HR Zone 1..5 %, GPS;
//   journal_entries.csv — Cycle start time, Question text, Answered yes, Notes.
// Время — местное «YYYY-MM-DD HH:MM:SS», пояс отдельной колонкой. Колонки
// ищутся по названию без учёта регистра (WHOOP переставляет их между версиями).
// День цикла = дата ПРОБУЖДЕНИЯ (Wake onset), как день `derived_day` Edge.
//
// Тест: test/ritm_compare_test.dart.

import 'ritm_seed.dart' show parseCsvRows;

String dayId(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? parseWhoopTs(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  return DateTime.tryParse(t.replaceFirst(' ', 'T'));
}

double? _num(String s) {
  final t = s.trim().replaceAll('%', '').replaceAll(',', '.');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

/// Таблица CSV с поиском колонки по имени.
class _Table {
  final List<String> head;
  final List<List<String>> rows;
  _Table(this.head, this.rows);

  factory _Table.parse(String text) {
    final r = parseCsvRows(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (r.isEmpty) return _Table(const [], const []);
    return _Table([for (final h in r.first) h.trim().toLowerCase()], r.sublist(1));
  }

  int col(List<String> names) {
    for (final n in names) {
      final i = head.indexOf(n);
      if (i >= 0) return i;
    }
    return -1;
  }

  bool has(String name) => head.contains(name);
}

String _at(List<String> r, int i) => i >= 0 && i < r.length ? r[i] : '';

/// Поля сна (общие у physiological_cycles и sleeps).
class WhoopSleepFields {
  final DateTime? onset, wake;
  final double? perf, resp, asleep, inBed, light, deep, rem, awake;
  final double? need, debt, eff, consistency;
  const WhoopSleepFields({
    this.onset,
    this.wake,
    this.perf,
    this.resp,
    this.asleep,
    this.inBed,
    this.light,
    this.deep,
    this.rem,
    this.awake,
    this.need,
    this.debt,
    this.eff,
    this.consistency,
  });
}

WhoopSleepFields _sleepFields(_Table t, List<String> r) {
  double? n(List<String> names) => _num(_at(r, t.col(names)));
  return WhoopSleepFields(
    onset: parseWhoopTs(_at(r, t.col(['sleep onset']))),
    wake: parseWhoopTs(_at(r, t.col(['wake onset']))),
    perf: n(['sleep performance %']),
    resp: n(['respiratory rate (rpm)', 'respiratory rate']),
    asleep: n(['asleep duration (min)']),
    inBed: n(['in bed duration (min)']),
    light: n(['light sleep duration (min)']),
    deep: n(['deep (sws) duration (min)', 'deep sleep duration (min)']),
    rem: n(['rem duration (min)', 'rem sleep duration (min)']),
    awake: n(['awake duration (min)']),
    need: n(['sleep need (min)']),
    debt: n(['sleep debt (min)']),
    eff: n(['sleep efficiency %']),
    consistency: n(['sleep consistency %']),
  );
}

/// Строка physiological_cycles.csv.
class WhoopCycle {
  final String day;
  final DateTime? start, end;
  final double? recovery, rhr, hrv, skinTemp, spo2, strain, kcal, maxHr, avgHr;
  final WhoopSleepFields sleep;
  const WhoopCycle({
    required this.day,
    this.start,
    this.end,
    this.recovery,
    this.rhr,
    this.hrv,
    this.skinTemp,
    this.spo2,
    this.strain,
    this.kcal,
    this.maxHr,
    this.avgHr,
    this.sleep = const WhoopSleepFields(),
  });
}

/// Строка sleeps.csv.
class WhoopSleep {
  final String day;
  final bool nap;
  final WhoopSleepFields f;
  const WhoopSleep(this.day, this.nap, this.f);
}

/// Строка workouts.csv.
class WhoopWorkout {
  final DateTime start;
  final DateTime? end;
  final double? durMin, strain, kcal, maxHr, avgHr;
  final String name;

  /// HR Zone 1..5 % (зоны WHOOP от резерва пульса).
  final List<double?> zones;
  const WhoopWorkout({
    required this.start,
    this.end,
    this.durMin,
    this.strain,
    this.kcal,
    this.maxHr,
    this.avgHr,
    this.name = '',
    this.zones = const [],
  });

  /// Силовая: Muscular Load WHOOP в Day Strain, у нас — только sRPE (K7).
  bool get strength {
    final n = name.toLowerCase();
    return const [
      'weightlifting',
      'powerlifting',
      'functional fitness',
      'strength',
      'crossfit',
      'f45',
      'barry',
      'pilates',
      'yoga',
      'climbing',
      'силов',
    ].any(n.contains);
  }
}

/// Строка journal_entries.csv.
class WhoopJournal {
  final DateTime? cycleStart;
  final String question;
  final bool? yes;
  final String notes;
  const WhoopJournal(this.cycleStart, this.question, this.yes, this.notes);
}

/// Распознанный экспорт.
class WhoopExport {
  final List<WhoopCycle> cycles;
  final List<WhoopSleep> sleeps;
  final List<WhoopWorkout> workouts;
  final List<WhoopJournal> journal;

  /// Какие файлы узнали: cycles / sleeps / workouts / journal.
  final Set<String> files;
  const WhoopExport({
    this.cycles = const [],
    this.sleeps = const [],
    this.workouts = const [],
    this.journal = const [],
    this.files = const {},
  });

  bool get isEmpty => cycles.isEmpty && sleeps.isEmpty;

  /// Дни с силовой тренировкой (дата начала тренировки).
  Set<String> get strengthDays => {
    for (final w in workouts)
      if (w.strength) dayId(w.start),
  };
}

/// Дата цикла: пробуждение; без него — старт цикла (вечер → следующий день).
String? _cycleDay(DateTime? wake, DateTime? start) {
  if (wake != null) return dayId(wake);
  if (start == null) return null;
  final d = start.hour >= 12
      ? DateTime(start.year, start.month, start.day + 1)
      : start;
  return dayId(d);
}

/// Вид файла по заголовку: 'cycles' | 'sleeps' | 'workouts' | 'journal' | null.
String? whoopFileKind(String text) {
  final t = _Table.parse(text);
  if (t.has('recovery score %') || t.has('day strain')) return 'cycles';
  if (t.has('activity strain') || t.has('workout start time')) return 'workouts';
  if (t.has('question text') || t.has('answered yes')) return 'journal';
  if (t.has('nap') || t.has('sleep performance %')) return 'sleeps';
  return null;
}

List<WhoopCycle> parseCycles(String text) {
  final t = _Table.parse(text);
  final out = <WhoopCycle>[];
  for (final r in t.rows) {
    double? n(List<String> names) => _num(_at(r, t.col(names)));
    final sf = _sleepFields(t, r);
    final start = parseWhoopTs(_at(r, t.col(['cycle start time'])));
    final day = _cycleDay(sf.wake, start);
    if (day == null) continue;
    out.add(
      WhoopCycle(
        day: day,
        start: start,
        end: parseWhoopTs(_at(r, t.col(['cycle end time']))),
        recovery: n(['recovery score %']),
        rhr: n(['resting heart rate (bpm)', 'resting heart rate']),
        hrv: n(['heart rate variability (ms)', 'heart rate variability (rmssd) (ms)']),
        skinTemp: n(['skin temp (celsius)', 'skin temp (fahrenheit)']),
        spo2: n(['blood oxygen %']),
        strain: n(['day strain']),
        kcal: n(['energy burned (cal)']),
        maxHr: n(['max hr (bpm)']),
        avgHr: n(['average hr (bpm)']),
        sleep: sf,
      ),
    );
  }
  out.sort((a, b) => a.day.compareTo(b.day));
  return out;
}

List<WhoopSleep> parseSleeps(String text) {
  final t = _Table.parse(text);
  final out = <WhoopSleep>[];
  for (final r in t.rows) {
    final sf = _sleepFields(t, r);
    final day = _cycleDay(sf.wake, sf.onset);
    if (day == null) continue;
    final nap = _at(r, t.col(['nap'])).trim().toLowerCase() == 'true';
    out.add(WhoopSleep(day, nap, sf));
  }
  out.sort((a, b) => a.day.compareTo(b.day));
  return out;
}

List<WhoopWorkout> parseWorkouts(String text) {
  final t = _Table.parse(text);
  final out = <WhoopWorkout>[];
  for (final r in t.rows) {
    double? n(List<String> names) => _num(_at(r, t.col(names)));
    final st = parseWhoopTs(_at(r, t.col(['workout start time'])));
    if (st == null) continue;
    out.add(
      WhoopWorkout(
        start: st,
        end: parseWhoopTs(_at(r, t.col(['workout end time']))),
        durMin: n(['duration (min)']),
        strain: n(['activity strain']),
        kcal: n(['energy burned (cal)']),
        maxHr: n(['max hr (bpm)']),
        avgHr: n(['average hr (bpm)']),
        name: _at(r, t.col(['activity name'])).trim(),
        zones: [for (var z = 1; z <= 5; z++) n(['hr zone $z %'])],
      ),
    );
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

List<WhoopJournal> parseJournal(String text) {
  final t = _Table.parse(text);
  return [
    for (final r in t.rows)
      WhoopJournal(
        parseWhoopTs(_at(r, t.col(['cycle start time']))),
        _at(r, t.col(['question text'])).trim(),
        switch (_at(r, t.col(['answered yes'])).trim().toLowerCase()) {
          'true' => true,
          'false' => false,
          _ => null,
        },
        _at(r, t.col(['notes'])).trim(),
      ),
  ];
}

/// Разбор набора файлов (имя → текст). Вид файла — по заголовку, не по имени.
WhoopExport parseWhoopExport(Map<String, String> files) {
  var cycles = <WhoopCycle>[];
  var sleeps = <WhoopSleep>[];
  var workouts = <WhoopWorkout>[];
  var journal = <WhoopJournal>[];
  final kinds = <String>{};
  for (final text in files.values) {
    final k = whoopFileKind(text);
    if (k == null) continue;
    kinds.add(k);
    switch (k) {
      case 'cycles':
        cycles = parseCycles(text);
      case 'sleeps':
        sleeps = parseSleeps(text);
      case 'workouts':
        workouts = parseWorkouts(text);
      case 'journal':
        journal = parseJournal(text);
    }
  }
  return WhoopExport(
    cycles: cycles,
    sleeps: sleeps,
    workouts: workouts,
    journal: journal,
    files: kinds,
  );
}
