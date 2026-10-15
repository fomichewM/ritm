// «Ритм» — чистые алгоритмы вкладки «Здоровье» и экрана «Источники и сверка»
// (ТЗ v2 §10.4 Монитор здоровья, §10.8 Кардиоформа, §10.9 Сверка с Watch).
// Без Flutter-виджетов — проверяются юнит-тестами (test/ritm_calc_test.dart).

import 'dart:math' as math;

import 'ritm_scores.dart' show dec1, plural;

// ───────────────────────── перцентили ─────────────────────────

/// Перцентиль [p] (0…1) с линейной интерполяцией. Пустой список — null.
double? percentile(Iterable<double> xs, double p) {
  final s = xs.toList()..sort();
  if (s.isEmpty) return null;
  if (s.length == 1) return s.first;
  final pos = (s.length - 1) * p.clamp(0.0, 1.0);
  final lo = pos.floor(), hi = pos.ceil();
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

double? mean(Iterable<double> xs) {
  final l = xs.toList();
  if (l.isEmpty) return null;
  return l.reduce((a, b) => a + b) / l.length;
}

// ───────────────────────── Монитор здоровья ─────────────────────────

enum MonKind { rhr, hrv, resp, temp, spo2 }

enum MonStatus { ok, warn, alert, calibrating, noSource, noData }

/// Минимум ночей для коридора; до [kMonFinal] — «предварительно».
const int kMonMin = 7;
const int kMonFinal = 14;

class MonRow {
  final MonKind kind;
  final String name;

  /// Значение за последнюю ночь, уже отформатированное («51», «14,2», «+0,2»).
  final String? value;
  final String unit;

  /// «норма 49–55» / «нужно 7 ночей · 3/7» / «нет источника: нужны Apple Watch».
  final String note;
  final MonStatus status;
  final bool preliminary;

  const MonRow({
    required this.kind,
    required this.name,
    this.value,
    this.unit = '',
    required this.note,
    required this.status,
    this.preliminary = false,
  });

  bool get measured =>
      status == MonStatus.ok ||
      status == MonStatus.warn ||
      status == MonStatus.alert;
}

String monName(MonKind k) => switch (k) {
  MonKind.rhr => 'Пульс покоя',
  MonKind.hrv => 'ВСР',
  MonKind.resp => 'Дыхание',
  MonKind.temp => 'Температура кожи',
  MonKind.spo2 => 'SpO₂ ночью',
};

String _fmt(MonKind k, double v) => switch (k) {
  MonKind.rhr || MonKind.hrv => v.round().toString(),
  MonKind.resp => dec1(v),
  MonKind.temp => '${v > 0 ? '+' : (v < 0 ? '−' : '')}${dec1(v.abs())}',
  MonKind.spo2 => v.round().toString(),
};

String _unit(MonKind k) => switch (k) {
  MonKind.rhr => 'уд/мин',
  MonKind.hrv => 'мс',
  MonKind.resp => 'вд/мин',
  MonKind.temp => '°C',
  MonKind.spo2 => '%',
};

/// Строка монитора по истории ночей (§10.4).
///
/// [history] — прошлые ночи (без последней), до 30; [last] — последняя ночь;
/// [prev] — ночь перед последней (для правила «две ночи подряд»).
/// Для температуры [last]/[prev] — отклонение от личной нормы в °C, история
/// нужна только для счёта ночей.
MonRow monitorRow(
  MonKind kind, {
  required List<double> history,
  double? last,
  double? prev,
  bool hasSource = true,
  List<double> recent = const [],
  String seededFrom = '',
}) {
  final name = monName(kind);
  final unit = _unit(kind);
  if (!hasSource) {
    return MonRow(
      kind: kind,
      name: name,
      unit: unit,
      note: 'нет источника: нужны Apple Watch',
      status: MonStatus.noSource,
    );
  }
  if (kind == MonKind.spo2) {
    if (last == null) {
      return MonRow(
        kind: kind,
        name: name,
        unit: unit,
        note: 'Watch не носился ночью',
        status: MonStatus.noData,
      );
    }
    final st = last >= 95
        ? MonStatus.ok
        : last >= 93
        ? MonStatus.warn
        : MonStatus.alert;
    return MonRow(
      kind: kind,
      name: name,
      value: _fmt(kind, last),
      unit: unit,
      note: 'норма 95–100 · Watch',
      status: st,
    );
  }
  final n = history.length;
  if (last == null) {
    return MonRow(
      kind: kind,
      name: name,
      unit: unit,
      note: n < kMonMin
          ? 'нужно $kMonMin ночей · $n/$kMonMin'
          : 'нет данных за ночь',
      status: n < kMonMin ? MonStatus.calibrating : MonStatus.noData,
    );
  }
  final v = _fmt(kind, last);
  if (n < kMonMin) {
    return MonRow(
      kind: kind,
      name: name,
      value: v,
      unit: unit,
      note: 'нужно $kMonMin ночей · $n/$kMonMin',
      status: MonStatus.calibrating,
    );
  }
  final pre = n < kMonFinal;
  final p10 = percentile(history, .10)!, p90 = percentile(history, .90)!;
  final med = percentile(history, .5)!;
  late MonStatus st;
  late String norm;
  switch (kind) {
    case MonKind.rhr:
      final hi = last > p90, hiPrev = prev != null && prev > p90;
      st = hi ? (hiPrev ? MonStatus.alert : MonStatus.warn) : MonStatus.ok;
      // Медленный дрейф вверх несколько ночей подряд (CUSUM) — тоже красный.
      if (cusumHigh(history, recent)) st = MonStatus.alert;
      // Порог односторонний (плохо только выше) — так и подписываем.
      norm = 'норма до ${p90.round()}';
    case MonKind.hrv:
      final lo = last < p10, loPrev = prev != null && prev < p10;
      st = lo ? (loPrev ? MonStatus.alert : MonStatus.warn) : MonStatus.ok;
      // Высокая ВСР — хорошо: порог только снизу.
      norm = 'норма от ${p10.round()}';
    case MonKind.resp:
      st = last > med + 2
          ? MonStatus.alert
          : last > med + 1.5
          ? MonStatus.warn
          : MonStatus.ok;
      norm = 'норма до ${dec1(med + 1.5)}';
    case MonKind.temp:
      st = last > 0.5
          ? MonStatus.alert
          : last >= 0.3
          ? MonStatus.warn
          : MonStatus.ok;
      norm = 'норма ±0,3';
    case MonKind.spo2:
      throw StateError('unreachable');
  }
  return MonRow(
    kind: kind,
    name: name,
    value: v,
    unit: unit,
    note: pre
        ? '$norm · предварительно'
        : (seededFrom.isEmpty ? norm : '$norm · $seededFrom'),
    status: st,
    preliminary: pre,
  );
}

/// Односторонний CUSUM (вверх) по последним ночам [recent] относительно
/// истории: z = (x − медиана)/(1,4826·MAD, не меньше 1), S = max(0, S + z − 0,5),
/// тревога при S ≥ 4. Нужна история ≥ 7 ночей.
bool cusumHigh(List<double> history, List<double> recent) {
  if (history.length < kMonMin || recent.isEmpty) return false;
  final med = percentile(history, .5)!;
  final mad = percentile([for (final x in history) (x - med).abs()], .5)!;
  final sd = math.max(1.4826 * mad, 1.0);
  var s = 0.0;
  for (final x in recent) {
    s = math.max(0, s + (x - med) / sd - 0.5);
    if (s >= 4) return true;
  }
  return false;
}

/// Итог монитора (плитка и заголовок карточки, §10.4).
({MonStatus status, String text}) monitorSummary(List<MonRow> rows) {
  final measured = rows.where((r) => r.measured).toList();
  if (measured.isEmpty) {
    final cal = rows.where((r) => r.status == MonStatus.calibrating).toList();
    final have = cal.isEmpty
        ? 0
        : cal
              .map((r) {
                final m = RegExp(r'(\d+)/(\d+)').firstMatch(r.note);
                return m == null ? 0 : int.parse(m[1]!);
              })
              .reduce(math.max);
    return (
      status: MonStatus.calibrating,
      text: 'Изучаем норму · $have/$kMonMin',
    );
  }
  final warns = measured.where((r) => r.status == MonStatus.warn).toList();
  final alerts = measured.where((r) => r.status == MonStatus.alert).toList();
  if (alerts.isNotEmpty || warns.length >= 2) {
    return (status: MonStatus.alert, text: 'Вне нормы');
  }
  if (warns.length == 1) {
    final w = warns.first;
    return (
      status: MonStatus.warn,
      text: '1 вне нормы: ${w.name.toLowerCase()} ${w.value}',
    );
  }
  return (
    status: MonStatus.ok,
    text: 'В норме · ${measured.length} из ${measured.length}',
  );
}

/// Строка плитки на главной (одна строка ~16 знаков): «В норме · 4 из 4»,
/// «Пульс покоя 58 ↑», «Вне нормы», «Изучаем норму · 3/7».
String monitorTileText(List<MonRow> rows) {
  final sum = monitorSummary(rows);
  if (sum.status != MonStatus.warn) return sum.text;
  final w = rows.firstWhere((r) => r.status == MonStatus.warn);
  final arrow = w.kind == MonKind.hrv ? '↓' : '↑';
  final short = switch (w.kind) {
    MonKind.rhr => 'Пульс покоя',
    MonKind.temp => 'Темп.',
    MonKind.resp => 'Дыхание',
    _ => w.name,
  };
  return '$short ${w.value} $arrow';
}

/// Плашка «радар болезни» — только когда не зелёно (§4.3).
String? illnessRadar(List<MonRow> rows) {
  final bad = rows.where(
    (r) => r.status == MonStatus.alert || r.status == MonStatus.warn,
  );
  if (bad.isEmpty) return null;
  final r = bad.first;
  final two = r.status == MonStatus.alert;
  final what = switch (r.kind) {
    MonKind.rhr => 'пульс покоя выше нормы',
    MonKind.hrv => 'ВСР ниже нормы',
    MonKind.resp => 'дыхание чаще обычного',
    MonKind.temp => 'температура кожи выше обычной',
    MonKind.spo2 => 'SpO₂ ниже обычного',
  };
  return two
      ? 'Радар болезни: $what две ночи подряд. Поберегитесь.'
      : 'Радар болезни: $what. Если повторится — отдохните.';
}

// ───────────────────────── Кардиоформа ─────────────────────────

/// Тренд одного показателя: 7 последних дней против 30.
class CardioTrend {
  /// Среднее за 7 дней (для ВСР — геометрическое, через ln).
  final double? now7;
  final double? mean30;

  /// +1 — форма растёт, −1 — снижается, 0 — без изменений, null — мало данных.
  final int? form;

  /// «+4 к прошлому месяцу».
  final String delta;
  const CardioTrend({this.now7, this.mean30, this.form, this.delta = ''});
}

/// Дней данных нужно для тренда (§10.8: при < 14 — калибровка).
const int kCardioMin = 14;

/// ВСР: среднее ln rMSSD 7 дн. против 30 дн.; Δ > +0,05 → ↑, < −0,05 → ↓.
CardioTrend cardioHrv(List<double> last30) {
  final xs = last30.where((v) => v > 0).toList();
  if (xs.length < kCardioMin) return const CardioTrend();
  final ln = xs.map(math.log).toList();
  final m7 = mean(ln.sublist(math.max(0, ln.length - 7)))!;
  final m30 = mean(ln)!;
  final d = m7 - m30;
  final now = math.exp(m7), base = math.exp(m30);
  return CardioTrend(
    now7: now,
    mean30: base,
    form: d > 0.05 ? 1 : (d < -0.05 ? -1 : 0),
    // Дельта — из тех же округлённых чисел, что на плитке (49 и 50 → −1).
    delta: deltaShown(now.round() - base.round()),
  );
}

/// Пульс покоя: 7 против 30; Δ ≤ −1 → форма ↑, ≥ +1 → ↓.
CardioTrend cardioRhr(List<double> last30) {
  final xs = last30.where((v) => v > 0).toList();
  if (xs.length < kCardioMin) return const CardioTrend();
  final m7 = mean(xs.sublist(math.max(0, xs.length - 7)))!;
  final m30 = mean(xs)!;
  final d = m7 - m30;
  return CardioTrend(
    now7: m7,
    mean30: m30,
    form: d <= -1 ? 1 : (d >= 1 ? -1 : 0),
    delta: deltaShown(m7.round() - m30.round()),
  );
}

/// «↑ +4 к месяцу» / «↓ −0,6 к месяцу» / «0 к месяцу» — всегда числом
/// (меньше 1 — с десятой).
String deltaToMonth(double d) {
  final r = d.round();
  if (r != 0) return '${r > 0 ? '↑ +' : '↓ −'}${r.abs()} к месяцу';
  final t = (d * 10).round();
  if (t == 0) return '0 к месяцу';
  return '${t > 0 ? '↑ +' : '↓ −'}${dec1(t.abs() / 10)} к месяцу';
}

/// Дельта с десятой (для чисел, которые показаны с десятой: VO₂max).
String deltaToMonth1(double d) {
  final t = (d * 10).round();
  if (t == 0) return 'как месяц назад';
  return '${t > 0 ? '↑ +' : '↓ −'}${dec1(t.abs() / 10)} к месяцу';
}

/// Дельта целых чисел, как они показаны на плитке: «↑ +4 к месяцу»,
/// «↓ −1 к месяцу», «как месяц назад».
String deltaShown(int d) => d == 0
    ? 'как месяц назад'
    : '${d > 0 ? '↑ +' : '↓ −'}${d.abs()} к месяцу';

/// VO₂max (Watch): изменение к месяцу — форма ↑ при ≥ +1, ↓ при ≤ −1.
int? vo2Form(double? deltaMonth) => deltaMonth == null
    ? null
    : (deltaMonth >= 1 ? 1 : (deltaMonth <= -1 ? -1 : 0));

/// Итоговое слово Кардиоформы (§10.8): ↑↑ или (↑ и =) → «Растёт»;
/// ↓ хотя бы по двум → «Снижается»; иначе «Стабильна». Null — калибровка.
String? cardioVerdict(List<int?> forms) {
  final known = forms.whereType<int>().toList();
  if (known.isEmpty) return null;
  final up = known.where((f) => f > 0).length;
  final down = known.where((f) => f < 0).length;
  if (down >= 2) return 'Снижается';
  if (up >= 2 || (up >= 1 && down == 0)) return 'Растёт';
  return 'Стабильна';
}

// ───────────────────────── Сверка браслет / Watch ─────────────────────────

enum Agree { match, differ, check }

/// Пульс покоя: |Δ| ≤ 3 совпадают, 4–6 расходятся, > 6 проверьте посадку.
Agree reconcileRhr(num band, num watch) {
  final d = (band - watch).abs().round();
  if (d <= 3) return Agree.match;
  if (d <= 6) return Agree.differ;
  return Agree.check;
}

/// Сон: |Δ| ≤ 20 мин совпадают, 21–45 расходятся, > 45 проверьте браслет.
Agree reconcileSleep(num bandMin, num watchMin) {
  final d = (bandMin - watchMin).abs().round();
  if (d <= 20) return Agree.match;
  if (d <= 45) return Agree.differ;
  return Agree.check;
}

String agreeWord(Agree a, {bool sleep = false}) => switch (a) {
  Agree.match => 'совпадают',
  Agree.differ => 'расходятся',
  Agree.check => sleep ? 'проверьте браслет' : 'проверьте посадку браслета',
};

/// Одна строка сверки для «Здоровья» (итог) по двум сверкам.
String reconcileSummary({Agree? rhr, Agree? sleep}) {
  final all = [rhr, sleep].whereType<Agree>().toList();
  if (all.isEmpty) return 'Watch не носился ночью';
  if (all.every((a) => a == Agree.match)) {
    return 'Браслет и Watch совпадают';
  }
  if (all.any((a) => a == Agree.check)) return 'Расходятся — проверьте браслет';
  final n = all.where((a) => a != Agree.match).length;
  return '$n ${plural(n, 'показатель расходится', 'показателя расходятся', 'показателей расходятся')}';
}

// ───────────────────────── источник «Apple Watch» ─────────────────────────

/// Запись из «Здоровья» сделана Apple Watch (а не телефоном, Ритмом или
/// другим приложением). [ownBundle] — наш bundle id (свои записи отбрасываем).
bool isWatchSample({
  required String sourceId,
  required String sourceName,
  String? deviceModel,
  String ownBundle = '',
}) {
  if (ownBundle.isNotEmpty && sourceId == ownBundle) return false;
  final m = (deviceModel ?? '').toLowerCase();
  if (m.contains('watch')) return true;
  final n = sourceName.toLowerCase();
  return n.contains('watch') || n.contains('часы');
}

/// Минуты сна Watch за ночь из интервалов стадий (сливает пересечения,
/// бодрствование и «в кровати» не считает).
int watchSleepMinutes(List<({DateTime from, DateTime to})> asleep) {
  if (asleep.isEmpty) return 0;
  final s = [...asleep]..sort((a, b) => a.from.compareTo(b.from));
  var total = 0;
  var curFrom = s.first.from, curTo = s.first.to;
  for (final i in s.skip(1)) {
    if (!i.from.isAfter(curTo)) {
      if (i.to.isAfter(curTo)) curTo = i.to;
    } else {
      total += curTo.difference(curFrom).inMinutes;
      curFrom = i.from;
      curTo = i.to;
    }
  }
  total += curTo.difference(curFrom).inMinutes;
  return total;
}
