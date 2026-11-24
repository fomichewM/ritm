// «Ритм» B4½ — сверка с официальным WHOOP (ТЗ v3 §8): выравнивание дней,
// допуски §8.2, MAE / смещение / медиана / r / доля в допуске, калибровочная
// и проверочная трети по времени, совпадение зон.
//
// Тот же расчёт — в tool/ritm_compare.py (сервер: build/whoop_reconcile.py);
// test/ritm_compare_test.dart сверяет Dart с ожидаемым JSON, который выдал
// скрипт на фикстуре 90 дней, — числа должны совпасть до округления.
//
// Правила (§8.1–§8.2):
//   • день WHOOP = дата пробуждения; наш день = ночь, закончившаяся этим
//     пробуждением; |подъём WHOOP − наш подъём| > 2 ч → `align_fail`, день
//     исключён из метрик (в таблице виден);
//   • «чистый» день: наблюдено ≥ 85 % ночи, пульс ≥ 80 % минут, дыра ≤ 2 ч;
//     для Нагрузки ещё и без силовых (силовые WHOOP добирает Muscular Load);
//   • метрики считаются на чистых днях: на ВСЕХ и на ПРОВЕРОЧНОЙ трети
//     (последняя треть чистых дней по дате) — проходить должны обе;
//   • < 30 чистых дней — «предварительно», допуски MAE/смещения ×1,5;
//   • Δ = Ритм − WHOOP.

import 'dart:math' as math;

import 'ritm_seed.dart' show parseCsvRows;
import 'ritm_whoop_csv.dart';

// ── наш день («Экспорт для сверки») ──────────────────────────────────────────

/// Колонки «Экспорта для сверки» — порядок фиксирован (их же читает скрипт).
const List<String> kRitmExportCols = [
  'day',
  'onset',
  'wake',
  'rhr_sleep_mean',
  'rhr_trough30',
  'rmssd_sws_last',
  'rmssd_night_mean',
  'resp',
  'temp_dev',
  'tst_min',
  'in_bed_min',
  'eff',
  'light_min',
  'deep_min',
  'rem_min',
  'awake_min',
  'need_min',
  'debt_min',
  'consistency',
  'sleep_pct',
  'recovery',
  'strain',
  'observed_frac',
  'hr_valid_frac',
  'max_gap_min',
  'strength',
  'sws_found',
  'watch_min',
  'rec_zbar',
  'strain_load',
  'v_hist',
];

/// Ширина корзины гистограммы доли резерва пульса (для калибровки s, k).
const double kVHistBin = 0.05;

/// Один день «Ритма» в шкалах сверки.
class RitmDayExport {
  final String day;
  final DateTime? onset, wake;
  final Map<String, double?> v;
  final bool strength, swsFound;

  /// Минуты по корзинам доли резерва (v<0 — корзина 0, далее по 0,05),
  /// через «;» — чтобы tool/ritm_calibrate.py пересчитал I при других k.
  final String vHist;
  const RitmDayExport({
    required this.day,
    this.onset,
    this.wake,
    this.v = const {},
    this.strength = false,
    this.swsFound = false,
    this.vHist = '',
  });

  double? operator [](String k) => v[k];
  double get observedFrac => v['observed_frac'] ?? 1;
  double get hrValidFrac => v['hr_valid_frac'] ?? 1;
  double get maxGapMin => v['max_gap_min'] ?? 0;

  static String _ts(DateTime? d) {
    if (d == null) return '';
    String p(int x) => x.toString().padLeft(2, '0');
    return '${dayId(d)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  static String _n(double? x) {
    if (x == null || x.isNaN) return '';
    final r = (x * 1000).roundToDouble() / 1000;
    return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
  }

  List<String> toRow() => [
    for (final c in kRitmExportCols)
      switch (c) {
        'day' => day,
        'onset' => _ts(onset),
        'wake' => _ts(wake),
        'strength' => strength ? 'true' : 'false',
        'sws_found' => swsFound ? 'true' : 'false',
        'v_hist' => vHist,
        _ => _n(v[c]),
      },
  ];

  static RitmDayExport? fromRow(List<String> head, List<String> r) {
    String at(String c) {
      final i = head.indexOf(c);
      return i >= 0 && i < r.length ? r[i].trim() : '';
    }

    final day = at('day');
    if (day.isEmpty) return null;
    return RitmDayExport(
      day: day,
      onset: parseWhoopTs(at('onset')),
      wake: parseWhoopTs(at('wake')),
      strength: at('strength') == 'true',
      swsFound: at('sws_found') == 'true',
      vHist: at('v_hist'),
      v: {
        for (final c in kRitmExportCols.skip(3))
          if (c != 'strength' && c != 'sws_found' && c != 'v_hist')
            c: double.tryParse(at(c)),
      },
    );
  }
}

String ritmExportCsv(List<RitmDayExport> days) {
  String q(String s) => s.contains(',') ? '"$s"' : s;
  final b = StringBuffer(kRitmExportCols.join(','))..write('\n');
  for (final d in days) {
    b
      ..write(d.toRow().map(q).join(','))
      ..write('\n');
  }
  return b.toString();
}

List<RitmDayExport> parseRitmExport(String text) {
  final rows = parseCsvRows(text);
  if (rows.isEmpty) return const [];
  final head = [for (final h in rows.first) h.trim()];
  return [
    for (final r in rows.skip(1)) ?RitmDayExport.fromRow(head, r),
  ];
}

// ── показатели и допуски §8.2 ────────────────────────────────────────────────

/// Допуск: MAE ≤, |смещение| ≤, r ≥, доля дней с |Δ| ≤ within не ниже share.
class CmpTol {
  final double? mae, bias, r, within, share;
  const CmpTol({this.mae, this.bias, this.r, this.within, this.share});
}

class CmpMetric {
  final String key, title, unit;

  /// 'rings' — вкладка «Кольца» (B4½), 'sleep' — «Сон» (B4¾).
  final String tab;

  /// Обязательная строка приёмки B4½ (§13 T0).
  final bool required;
  final CmpTol tol;

  /// Знаков после запятой при показе.
  final int dp;
  const CmpMetric(
    this.key,
    this.title,
    this.unit,
    this.tab,
    this.tol, {
    this.required = false,
    this.dp = 0,
  });
}

const List<CmpMetric> kCmpMetrics = [
  CmpMetric('recovery', 'Восстановление', '%', 'rings',
      CmpTol(mae: 8, bias: 4, r: 0.85), required: true),
  CmpMetric('strain', 'Нагрузка', '', 'rings',
      CmpTol(mae: 1.5, bias: 0.8, r: 0.90), required: true, dp: 1),
  CmpMetric('hrv', 'ВСР', 'мс', 'rings',
      CmpTol(mae: 8, bias: 4, r: 0.85, within: 10, share: 0.80), required: true),
  CmpMetric('rhr', 'Пульс покоя', 'уд/мин', 'rings',
      CmpTol(mae: 2, bias: 1, r: 0.90, within: 3, share: 0.85), required: true),
  CmpMetric('resp', 'Дыхание', '/мин', 'rings',
      CmpTol(mae: 0.8, bias: 0.5, r: 0.70), required: true, dp: 1),
  CmpMetric('temp', 'Температура (знак)', '°C', 'rings',
      CmpTol(share: 0.75), dp: 1),
  CmpMetric('sleep_pct', 'Сон', '%', 'rings',
      CmpTol(mae: 5, bias: 3, r: 0.90), required: true),
  CmpMetric('tst', 'Время сна', 'мин', 'sleep',
      CmpTol(mae: 15, bias: 10, r: 0.90), required: true),
  CmpMetric('onset', 'Отбой', 'мин', 'sleep',
      CmpTol(mae: 15, bias: 10, within: 15, share: 0.85)),
  CmpMetric('wake', 'Подъём', 'мин', 'sleep',
      CmpTol(mae: 15, bias: 10, within: 15, share: 0.85)),
  CmpMetric('in_bed', 'В кровати', 'мин', 'sleep', CmpTol(mae: 15)),
  CmpMetric('eff', 'Эффективность', '%', 'sleep', CmpTol(mae: 3, bias: 2)),
  CmpMetric('light', 'Лёгкий', 'мин', 'sleep', CmpTol(mae: 25, bias: 15)),
  CmpMetric('deep', 'Глубокий', 'мин', 'sleep', CmpTol(mae: 25, bias: 15)),
  CmpMetric('rem', 'Быстрый', 'мин', 'sleep', CmpTol(mae: 25, bias: 15)),
  CmpMetric('awake', 'Бодрствование', 'мин', 'sleep', CmpTol(mae: 25, bias: 15)),
  CmpMetric('need', 'Потребность', 'мин', 'sleep',
      CmpTol(mae: 20, bias: 10, r: 0.80)),
  CmpMetric('debt', 'Долг', 'мин', 'sleep', CmpTol(mae: 20, bias: 10)),
  CmpMetric('consistency', 'Регулярность', '%', 'sleep',
      CmpTol(mae: 8, r: 0.70)),
];

CmpMetric cmpMetric(String key) => kCmpMetrics.firstWhere((m) => m.key == key);

/// Значение WHOOP для показателя (onset/wake — минуты от полуночи дня цикла).
double? _whoopVal(String k, WhoopCycle c, double? tempDev) {
  final s = c.sleep;
  return switch (k) {
    'recovery' => c.recovery,
    'strain' => c.strain,
    'hrv' => c.hrv,
    'rhr' => c.rhr,
    'resp' => s.resp,
    'temp' => tempDev,
    'sleep_pct' => s.perf,
    'tst' => s.asleep,
    'in_bed' => s.inBed,
    'eff' => s.eff,
    'light' => s.light,
    'deep' => s.deep,
    'rem' => s.rem,
    'awake' => s.awake,
    'need' => s.need,
    'debt' => s.debt,
    'consistency' => s.consistency,
    _ => null,
  };
}

double? _ritmVal(String k, RitmDayExport d) => switch (k) {
  'recovery' => d['recovery'],
  'strain' => d['strain'],
  'hrv' => d['rmssd_sws_last'],
  'rhr' => d['rhr_sleep_mean'],
  'resp' => d['resp'],
  'temp' => d['temp_dev'],
  'sleep_pct' => d['sleep_pct'],
  'tst' => d['tst_min'],
  'in_bed' => d['in_bed_min'],
  'eff' => d['eff'],
  'light' => d['light_min'],
  'deep' => d['deep_min'],
  'rem' => d['rem_min'],
  'awake' => d['awake_min'],
  'need' => d['need_min'],
  'debt' => d['debt_min'],
  'consistency' => d['consistency'],
  _ => null,
};

/// Минуты времени [t] относительно полуночи дня [day] (отбой бывает < 0).
double? _clockMin(DateTime? t, String day) {
  if (t == null) return null;
  final d0 = DateTime.parse(day);
  return t.difference(d0).inSeconds / 60.0;
}

// ── строки и статистика ──────────────────────────────────────────────────────

class CmpCell {
  final double whoop, ritm;
  const CmpCell(this.whoop, this.ritm);
  double get delta => ritm - whoop;
}

class CmpRow {
  final String day;
  final bool alignFail, strength;

  /// Причины «грязного» дня: 'observed' | 'hr_valid' | 'gap'.
  final List<String> dirty;
  final Map<String, CmpCell> cells;
  const CmpRow({
    required this.day,
    this.alignFail = false,
    this.strength = false,
    this.dirty = const [],
    this.cells = const {},
  });
  bool get clean => !alignFail && dirty.isEmpty;
  bool cleanFor(String k) => clean && (k != 'strain' || !strength);
}

class CmpStat {
  final int n;
  final double? mae, bias, median, r, share;
  const CmpStat({
    this.n = 0,
    this.mae,
    this.bias,
    this.median,
    this.r,
    this.share,
  });
}

double? pearson(List<double> x, List<double> y) {
  final n = x.length;
  if (n < 5) return null;
  final mx = x.reduce((a, b) => a + b) / n, my = y.reduce((a, b) => a + b) / n;
  var sxy = 0.0, sxx = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    sxy += (x[i] - mx) * (y[i] - my);
    sxx += (x[i] - mx) * (x[i] - mx);
    syy += (y[i] - my) * (y[i] - my);
  }
  if (sxx <= 0 || syy <= 0) return null;
  return sxy / math.sqrt(sxx * syy);
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

CmpStat cmpStat(List<CmpCell> cells, CmpTol tol, {bool sign = false}) {
  if (cells.isEmpty) return const CmpStat();
  final d = [for (final c in cells) c.delta];
  final n = d.length;
  if (sign) {
    // Температура: совпадение знака отклонения, где WHOOP ушёл ≥ 0,1 °C.
    final s = [for (final c in cells) if (c.whoop.abs() >= 0.1) c];
    if (s.isEmpty) return CmpStat(n: 0);
    final same = s.where((c) => (c.whoop > 0) == (c.ritm > 0)).length;
    return CmpStat(n: s.length, share: same / s.length);
  }
  return CmpStat(
    n: n,
    mae: d.map((x) => x.abs()).reduce((a, b) => a + b) / n,
    bias: d.reduce((a, b) => a + b) / n,
    median: _median(d),
    r: pearson([for (final c in cells) c.whoop], [for (final c in cells) c.ritm]),
    share: tol.within == null
        ? null
        : d.where((x) => x.abs() <= tol.within! + 1e-9).length / n,
  );
}

/// Проходит ли [s] допуск (MAE/смещение/доля — с множителем [mult]).
bool cmpPass(CmpStat s, CmpTol t, {double mult = 1}) {
  if (s.n < 3) return false;
  if (t.mae != null && (s.mae == null || s.mae! > t.mae! * mult + 1e-9)) {
    return false;
  }
  if (t.bias != null && (s.bias == null || s.bias!.abs() > t.bias! * mult + 1e-9)) {
    return false;
  }
  if (t.r != null && s.r != null && s.r! < t.r! - 1e-9) return false;
  if (t.share != null && (s.share == null || s.share! < t.share! - 1e-9)) {
    return false;
  }
  return true;
}

/// Почему [s] не прошёл допуск — короткие причины по-русски (для экрана).
/// Ключи: mae, bias, r, share, n; [sign] — для температуры («знак совпал»).
Map<String, String> cmpWhy(CmpStat s, CmpTol t, {double mult = 1, int dp = 0, bool sign = false}) {
  String f(double x, [int d = 0]) {
    final v = x.toStringAsFixed(d).replaceAll('.', ',');
    return v.startsWith('-') ? '\u2212${v.substring(1)}' : v;
  }

  if (s.n < 3) return {'n': 'мало дней (${s.n})'};
  return {
    if (t.mae != null && (s.mae ?? 1e9) > t.mae! * mult + 1e-9)
      'mae': 'ошибка ${f(s.mae ?? 0, dp)} > ${f(t.mae! * mult, dp)}',
    if (t.bias != null && (s.bias ?? 1e9).abs() > t.bias! * mult + 1e-9)
      'bias': 'смещение ${f(s.bias ?? 0, dp)} за ±${f(t.bias! * mult, dp)}',
    if (t.r != null && s.r != null && s.r! < t.r! - 1e-9)
      'r': 'дни не в такт: r ${f(s.r!, 2)} < ${f(t.r!, 2)}',
    if (t.share != null && (s.share ?? 0) < t.share! - 1e-9)
      'share': '${sign ? 'знак совпал' : 'в допуске'} ${((s.share ?? 0) * 100).round()}\u00a0% дней < ${(t.share! * 100).round()}\u00a0%',
  };
}

/// Итог по одному показателю.
class CmpResult {
  final CmpMetric m;
  final CmpStat all, calib, valid;
  final bool pass;
  const CmpResult(this.m, this.all, this.calib, this.valid, this.pass);
  bool get hasData => all.n > 0;

  /// Причины красного (по всем дням, затем по проверочной трети), без повторов.
  List<String> why(double mult) {
    if (pass) return const [];
    final sign = m.key == 'temp';
    final a = cmpWhy(all, m.tol, mult: mult, dp: m.dp, sign: sign);
    final v = cmpWhy(valid, m.tol, mult: mult, dp: m.dp, sign: sign);
    // Одна причина — одна строка; проверочная треть — только если там своё.
    return [
      for (final k in {...a.keys, ...v.keys})
        a[k] ?? '${v[k]} на проверочной трети',
    ];
  }
}

int zoneOfRecovery(double v) => v >= 67 ? 2 : (v >= 34 ? 1 : 0);
int zoneOfSleep(double v) => v >= 85 ? 2 : (v >= 70 ? 1 : 0);

class CmpReport {
  final List<CmpRow> rows;
  final Map<String, CmpResult> results;
  final int cleanDays, alignFail;

  /// Первая дата проверочной трети.
  final String? validFrom;
  final bool preliminary;

  /// Совпадение зоны Восстановления и Сна (доля чистых дней).
  final double? recZoneAgree, sleepZoneAgree;

  /// Распределение наших зон Восстановления (зел/жёлт/кр, доли).
  final List<double>? recDist;
  const CmpReport({
    this.rows = const [],
    this.results = const {},
    this.cleanDays = 0,
    this.alignFail = 0,
    this.validFrom,
    this.preliminary = true,
    this.recZoneAgree,
    this.sleepZoneAgree,
    this.recDist,
  });

  double get mult => preliminary ? 1.5 : 1.0;

  /// Все обязательные строки вкладки зелёные (+ зона Восстановления ≥ 80 %).
  bool passTab(String tab) {
    for (final r in results.values) {
      if (r.m.tab == tab && r.m.required && !r.pass) return false;
    }
    if (tab == 'rings' && (recZoneAgree == null || recZoneAgree! < 0.8)) {
      return false;
    }
    return true;
  }

  /// Зелёный ли конкретный Δ дня (по MAE-допуску, с множителем).
  bool cellOk(String key, double delta) {
    final t = cmpMetric(key).tol;
    final lim = t.within ?? t.mae;
    if (lim == null) return true;
    return delta.abs() <= lim * mult + 1e-9;
  }
}

/// Сверка: экспорт WHOOP × наши дни.
CmpReport compareWhoop(WhoopExport w, List<RitmDayExport> ours) {
  final byDay = {for (final d in ours) d.day: d};
  final strengthW = w.strengthDays;
  // Отклонение температуры WHOOP: от медианы предыдущих ≤ 30 циклов (≥ 3).
  final tempDev = <String, double?>{};
  final hist = <double>[];
  for (final c in w.cycles) {
    final t = c.skinTemp;
    final base = hist.length >= 3
        ? _median(hist.length > 30 ? hist.sublist(hist.length - 30) : hist)
        : null;
    tempDev[c.day] = t == null || base == null ? null : t - base;
    if (t != null) hist.add(t);
  }
  final rows = <CmpRow>[];
  final seen = <String>{};
  for (final c in w.cycles.reversed) {
    if (!seen.add(c.day)) continue; // дубль дня — берём последний цикл
    final o = byDay[c.day];
    if (o == null) continue;
    final ww = c.sleep.wake;
    final align = ww != null &&
        o.wake != null &&
        (ww.difference(o.wake!).inMinutes).abs() > 120;
    final dirty = <String>[
      if (o.observedFrac < 0.85) 'observed',
      if (o.hrValidFrac < 0.80) 'hr_valid',
      if (o.maxGapMin > 120) 'gap',
    ];
    final cells = <String, CmpCell>{};
    for (final m in kCmpMetrics) {
      double? a, b;
      if (m.key == 'onset') {
        a = _clockMin(c.sleep.onset, c.day);
        b = _clockMin(o.onset, c.day);
      } else if (m.key == 'wake') {
        a = _clockMin(c.sleep.wake, c.day);
        b = _clockMin(o.wake, c.day);
      } else {
        a = _whoopVal(m.key, c, tempDev[c.day]);
        b = _ritmVal(m.key, o);
      }
      if (a != null && b != null && !a.isNaN && !b.isNaN) {
        cells[m.key] = CmpCell(a, b);
      }
    }
    rows.add(
      CmpRow(
        day: c.day,
        alignFail: align,
        strength: o.strength || strengthW.contains(c.day),
        dirty: dirty,
        cells: cells,
      ),
    );
  }
  rows.sort((a, b) => a.day.compareTo(b.day));
  final clean = [for (final r in rows) if (r.clean) r.day];
  final k = (clean.length * 2) ~/ 3;
  final validFrom = clean.isEmpty || k >= clean.length ? null : clean[k];
  final preliminary = clean.length < 30;
  final mult = preliminary ? 1.5 : 1.0;
  final results = <String, CmpResult>{};
  for (final m in kCmpMetrics) {
    final all = <CmpCell>[], cal = <CmpCell>[], val = <CmpCell>[];
    for (final r in rows) {
      final cell = r.cells[m.key];
      if (cell == null || !r.cleanFor(m.key)) continue;
      all.add(cell);
      if (validFrom != null && r.day.compareTo(validFrom) >= 0) {
        val.add(cell);
      } else {
        cal.add(cell);
      }
    }
    final sign = m.key == 'temp';
    final sAll = cmpStat(all, m.tol, sign: sign);
    final sVal = cmpStat(val, m.tol, sign: sign);
    final pass = cmpPass(sAll, m.tol, mult: mult) &&
        cmpPass(sVal, m.tol, mult: mult);
    results[m.key] = CmpResult(m, sAll, cmpStat(cal, m.tol, sign: sign), sVal, pass);
  }
  double? zoneAgree(String key, int Function(double) z) {
    final xs = [
      for (final r in rows)
        if (r.clean && r.cells[key] != null) r.cells[key]!,
    ];
    if (xs.isEmpty) return null;
    return xs.where((c) => z(c.whoop) == z(c.ritm)).length / xs.length;
  }

  List<double>? dist;
  final rec = [
    for (final r in rows)
      if (r.clean && r.cells['recovery'] != null) r.cells['recovery']!.ritm,
  ];
  if (rec.isNotEmpty) {
    dist = [
      rec.where((v) => zoneOfRecovery(v) == 2).length / rec.length,
      rec.where((v) => zoneOfRecovery(v) == 1).length / rec.length,
      rec.where((v) => zoneOfRecovery(v) == 0).length / rec.length,
    ];
  }
  return CmpReport(
    rows: rows,
    results: results,
    cleanDays: clean.length,
    alignFail: rows.where((r) => r.alignFail).length,
    validFrom: validFrom,
    preliminary: preliminary,
    recZoneAgree: zoneAgree('recovery', zoneOfRecovery),
    sleepZoneAgree: zoneAgree('sleep_pct', zoneOfSleep),
    recDist: dist,
  );
}

/// JSON-сводка (тот же формат печатает tool/ritm_compare.py --json).
Map<String, dynamic> cmpReportJson(CmpReport r) {
  double? rd(double? x) => x == null ? null : (x * 1000).round() / 1000;
  Map<String, dynamic> st(CmpStat s) => {
    'n': s.n,
    'mae': rd(s.mae),
    'bias': rd(s.bias),
    'median': rd(s.median),
    'r': rd(s.r),
    'share': rd(s.share),
  };
  return {
    'clean_days': r.cleanDays,
    'align_fail': r.alignFail,
    'valid_from': r.validFrom,
    'preliminary': r.preliminary,
    'rec_zone_agree': rd(r.recZoneAgree),
    'sleep_zone_agree': rd(r.sleepZoneAgree),
    'metrics': {
      for (final e in r.results.entries)
        e.key: {
          'all': st(e.value.all),
          'calib': st(e.value.calib),
          'valid': st(e.value.valid),
          'pass': e.value.pass,
        },
    },
  };
}
