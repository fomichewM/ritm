// «Ритм» — наш слой поверх Edge: шкалы и пороги главного экрана.
//
// Источник формул и порогов: RITM2_PROPOSAL.md, п. 2 (утверждён 14.10.2026).
// Здесь только чистые функции без Flutter-виджетов, чтобы их можно было
// проверить юнит-тестами (test/ritm_scores_test.dart).
//
//   Сон%            = TST / потребность × 100, потолок 100.
//                     ≥85 зелёный · 70–84 жёлтый · <70 красный.
//   Восстановление  = 100 / (1 + e^−(1,7·z̄ + 0,43)), z̄ = logit(s_edge/100);
//                     если Сон% < 60 — не выше 66.
//                     67–100 зелёный · 34–66 жёлтый · 0–33 красный.
//   Нагрузка 0–21   — как считает Edge; цвет синий, насыщеннее с ростом:
//                     0–9 лёгкая · 10–13 умеренная · 14–17 высокая · 18–21 предельная.
//                     Цель по зоне восстановления: зел. 14–18 · жёлт. 10–14 · красн. 4–8.

import 'dart:math' as math;

/// Светофор.
enum RitmZone { green, yellow, red }

/// Восстановление «Ритма» из композита Edge (0–100, медианная ночь = 50).
///
/// [sleepPct] — Сон% той же ночи; короткая ночь (< 60%) не бывает зелёной.
int? ritmRecovery(num? edgeScore, {num? sleepPct}) {
  if (edgeScore == null || edgeScore.isNaN) return null;
  final s = (edgeScore / 100).clamp(0.001, 0.999);
  final z = math.log(s / (1 - s));
  var r = 100 / (1 + math.exp(-(1.7 * z + 0.43)));
  if (sleepPct != null && sleepPct < 60) r = math.min(r, 66);
  return r.round().clamp(0, 100);
}

/// Сон% от потребности (потолок 100). Null без потребности.
int? ritmSleepPct(num? sleepMin, num? needMin) {
  if (sleepMin == null || needMin == null || needMin <= 0) return null;
  return (sleepMin / needMin * 100).round().clamp(0, 100);
}

RitmZone? recoveryZone(num? v) {
  if (v == null) return null;
  if (v >= 67) return RitmZone.green;
  if (v >= 34) return RitmZone.yellow;
  return RitmZone.red;
}

RitmZone? sleepZone(num? pct) {
  if (pct == null) return null;
  if (pct >= 85) return RitmZone.green;
  if (pct >= 70) return RitmZone.yellow;
  return RitmZone.red;
}

/// «Готов» / «Умеренно» / «Отдых».
String recoveryWord(RitmZone z) => switch (z) {
  RitmZone.green => 'Готов',
  RitmZone.yellow => 'Умеренно',
  RitmZone.red => 'Отдых',
};

/// Уровень нагрузки 0–3: лёгкая / умеренная / высокая / предельная.
int strainLevel(num v) {
  if (v >= 18) return 3;
  if (v >= 14) return 2;
  if (v >= 10) return 1;
  return 0;
}

String strainWord(num v) =>
    const ['Лёгкая', 'Умеренная', 'Высокая', 'Предельная'][strainLevel(v)];

/// Целевой коридор нагрузки по зоне восстановления.
({double lo, double hi})? strainTargetFor(RitmZone? recovery) =>
    switch (recovery) {
      RitmZone.green => (lo: 14.0, hi: 18.0),
      RitmZone.yellow => (lo: 10.0, hi: 14.0),
      RitmZone.red => (lo: 4.0, hi: 8.0),
      null => null,
    };

/// Серия дней ношения: сколько подряд дней с данными заканчиваются сегодня
/// или вчера (сегодняшний день может ещё не дойти до телефона).
///
/// [days] — `availableDays()` в формате yyyy-MM-dd, порядок любой.
int wearStreak(Iterable<String> days, DateTime today) {
  final set = days.toSet();
  String id(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  var d = DateTime(today.year, today.month, today.day);
  if (!set.contains(id(d))) d = d.subtract(const Duration(days: 1));
  var n = 0;
  while (set.contains(id(d))) {
    n++;
    d = DateTime(d.year, d.month, d.day - 1);
  }
  return n;
}

/// «7:12» из минут.
String hmm(num minutes) {
  final m = minutes.round();
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
}

/// «07:30» — время суток из минут от полуночи.
String clock(int minOfDay) {
  final m = minOfDay % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// Первая буква строчная (для фраз после «Сон: »), кроме аббревиатур.
String lower1(String s) {
  if (s.length < 2) return s;
  final two = s.substring(0, 2);
  if (two == two.toUpperCase()) return s; // «ВСР …»
  return s[0].toLowerCase() + s.substring(1);
}

/// «Пн, 12 окт» из yyyy-MM-dd.
String shortDayRu(String id) {
  final d = DateTime.tryParse(id);
  if (d == null) return id;
  const wd = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
  const mo = [
    'янв',
    'фев',
    'мар',
    'апр',
    'мая',
    'июн',
    'июл',
    'авг',
    'сен',
    'окт',
    'ноя',
    'дек',
  ];
  return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
}

/// «12,4» — русская десятичная запятая.
String dec1(num v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Склонение: 1 ночь, 2 ночи, 5 ночей.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

/// Причина, по которой показателя нет, — по-русски, из машинной заметки Edge.
///
/// Edge пишет `need_baseline:have=H,need=N`, `need_input:name=X…` и т. п.
/// Свободный английский текст не показываем — вместо него общая фраза.
String ritmWhy(String? note, {required String fallback, bool days = false}) {
  final s = note?.trim() ?? '';
  final counts = RegExp(r'have=(\d+),need=(\d+)').firstMatch(s);
  if (s.contains('need_baseline') && counts != null) {
    final have = int.parse(counts[1]!), need = int.parse(counts[2]!);
    final left = math.max(1, need - have);
    return days
        ? 'Изучаем вашу норму — ещё $left ${plural(left, 'день', 'дня', 'дней')} ношения.'
        : 'Изучаем вашу норму — ещё $left ${plural(left, 'ночь', 'ночи', 'ночей')} с браслетом.';
  }
  final name = RegExp(r'name=([a-z0-9_]+)').firstMatch(s)?[1];
  if (name != null) {
    final why = _inputWhyRu[name];
    if (why != null) return why;
  }
  if (s.startsWith('unknown_device_family')) {
    return 'Записи не помечены моделью браслета — показатель не считаем, чтобы не гадать.';
  }
  return fallback;
}

const _inputWhyRu = {
  'age':
      'Не указан возраст — от него считается максимальный пульс. Ещё → Профиль.',
  'weight_kg': 'Не указан вес. Ещё → Профиль.',
  'height_cm': 'Не указан рост. Ещё → Профиль.',
  'sex': 'Не указан пол — формуле он нужен. Ещё → Профиль.',
  'wake_hr': 'За день нет пульса бодрствования.',
  'hr_samples': 'Слишком мало замеров пульса за день.',
  'resting_hr': 'Нет пульса покоя за посчитанную ночь.',
  'resting_hr_days': 'Мало ночей с пульсом покоя для расчёта нагрузки.',
  'scored_night': 'Нет посчитанной ночи.',
  'nn_beats': 'Мало чистых интервалов между ударами сердца за ночь.',
  'resp_windows': 'Мало спокойных отрезков дыхания за ночь.',
  'accel_1hz': 'Нет данных о движении рядом с пульсом.',
  'imported_day': 'День импортирован без дневных данных.',
  'today_activity': 'За сегодня с браслета ещё ничего не пришло.',
  'tst_min': 'У ночи нет длительности сна.',
};

/// Данные для «Пульса дня» — без ИИ, детерминированные шаблоны.
class PulseInput {
  final String? name;
  final int? recovery;
  final int? sleepPct;
  final num? sleepMin, needMin;
  final num? strain;
  final int? bedtimeMinOfDay;

  /// Драйвер восстановления Edge с наибольшим |вкладом|: 'hrv' | 'rhr' |
  /// 'resp' | 'temp' и знак (+ помог, − потянул вниз).
  final String? driver;
  final double? driverSign;

  /// Ночей до первой оценки восстановления (калибровка), если идёт.
  final ({int have, int need})? calibrating;
  final int hour;
  final bool isToday;

  const PulseInput({
    this.name,
    this.recovery,
    this.sleepPct,
    this.sleepMin,
    this.needMin,
    this.strain,
    this.bedtimeMinOfDay,
    this.driver,
    this.driverSign,
    this.calibrating,
    this.hour = 9,
    this.isToday = true,
  });
}

/// Заголовок карточки.
String pulseTitle(PulseInput p) {
  final n = p.name?.trim() ?? '';
  final hello = p.hour < 5
      ? 'Доброй ночи'
      : p.hour < 12
      ? 'Доброе утро'
      : p.hour < 18
      ? 'Добрый день'
      : 'Добрый вечер';
  return n.isEmpty ? '$hello!' : '$hello, $n!';
}

/// 2–3 фразы «Пульса дня».
String pulseText(PulseInput p) {
  final out = <String>[];
  final rz = recoveryZone(p.recovery);

  if (!p.isToday) {
    // Прошедший день — причина → следствие, без советов на будущее.
    final causes = <String>[];
    if (p.sleepMin != null) {
      causes.add(
        p.needMin == null
            ? 'сон ${hmm(p.sleepMin!)}'
            : 'сон ${hmm(p.sleepMin!)} при потребности ${hmm(p.needMin!)}',
      );
    }
    final drv = _driverShort(p.driver, p.driverSign);
    if (drv != null) causes.add(drv);
    if (p.recovery != null && rz != null) {
      out.add(
        causes.isEmpty
            ? 'Восстановление ${p.recovery}% (${recoveryWord(rz).toLowerCase()}).'
            : '${_cap(causes.join(' и '))} — отсюда восстановление '
                  '${p.recovery}% (${recoveryWord(rz).toLowerCase()}).',
      );
      if (p.strain != null) {
        final t = strainTargetFor(rz)!;
        final s = p.strain!;
        final range = '${t.lo.round()}–${t.hi.round()}';
        out.add(
          s > t.hi
              ? 'Нагрузка ${dec1(s)} — выше коридора $range: телу досталось больше, чем оно было готово принять.'
              : s >= t.lo
              ? 'Нагрузка ${dec1(s)} — в рекомендованном коридоре $range.'
              : 'Нагрузка ${dec1(s)} — ниже коридора $range, запас сил остался.',
        );
      }
    } else {
      if (p.calibrating != null) {
        out.add(
          'Восстановление ещё не считается: идёт калибровка, '
          '${p.calibrating!.have} из ${p.calibrating!.need} ночей.',
        );
      }
      out.add(
        causes.isEmpty
            ? 'За этот день браслет не записал ночь.'
            : '${_cap(causes.join(', '))}.',
      );
      if (p.strain != null) {
        out.add(
          'Нагрузка ${dec1(p.strain!)} — ${strainWord(p.strain!).toLowerCase()}.',
        );
      }
    }
    return out.join(' ');
  }

  if (p.recovery != null && rz != null) {
    final t = strainTargetFor(rz)!;
    out.add(switch (rz) {
      RitmZone.green =>
        'Восстановление ${p.recovery}% — организм готов к нагрузке. '
            'Хороший день для тренировки: нагрузка ${t.lo.round()}–${t.hi.round()}.',
      RitmZone.yellow =>
        'Восстановление ${p.recovery}% — умеренный день. '
            'Тренируйтесь в комфортном темпе, нагрузка ${t.lo.round()}–${t.hi.round()}.',
      RitmZone.red =>
        'Восстановление ${p.recovery}% — организму нужен отдых. '
            'Лучше прогулка или растяжка, нагрузка до ${t.hi.round()}.',
    });
    // Сколько осталось до коридора нагрузки при уже набранной (§10.3).
    final s = p.strain;
    if (p.isToday && s != null && s >= 1 && rz != RitmZone.red) {
      if (s < t.lo) {
        out.add('Сейчас ${dec1(s)} — до коридора ещё ${dec1(t.lo - s)}.');
      } else if (s <= t.hi) {
        out.add('Сейчас ${dec1(s)} — вы в коридоре.');
      } else {
        out.add('Сейчас ${dec1(s)} — выше коридора, дальше восстановление.');
      }
    }
    final why = _driverPhrase(p.driver, p.driverSign);
    if (why != null) out.add(why);
  } else if (p.calibrating != null) {
    final left = math.max(1, p.calibrating!.need - p.calibrating!.have);
    out.add(
      'Ритм изучает вашу норму: ${p.calibrating!.have} из '
      '${p.calibrating!.need} ночей. Ещё $left '
      '${plural(left, 'ночь', 'ночи', 'ночей')} — и появится восстановление.',
    );
  } else if (p.sleepMin == null) {
    out.add(
      p.isToday
          ? 'Наденьте браслет на ночь — утром здесь появятся сон и восстановление.'
          : 'За этот день браслет не записал ночь.',
    );
  }

  if (p.sleepMin != null) {
    final sp = p.sleepPct;
    if (sp == null) {
      out.add('Сон ${hmm(p.sleepMin!)}.');
    } else if (sp >= 85) {
      out.add('Сон ${hmm(p.sleepMin!)} — оценка сна $sp\u00a0%, отлично.');
    } else {
      final debt = (p.needMin ?? p.sleepMin!) - p.sleepMin!;
      final bed = p.bedtimeMinOfDay;
      out.add(
        'Сон ${hmm(p.sleepMin!)} из ${hmm(p.needMin ?? p.sleepMin!)} — '
        'не хватило ${hmm(debt)}.'
        '${p.isToday && bed != null ? ' Сегодня лучше лечь в ${hmm(bed)}.' : ''}',
      );
    }
  }

  if (p.isToday && p.strain != null && rz != null && out.length < 3) {
    final t = strainTargetFor(rz)!;
    final s = p.strain!;
    if (s > t.hi) {
      out.add('Нагрузка ${dec1(s)} уже выше цели — дальше восстанавливайтесь.');
    } else if (s >= t.lo) {
      out.add('Нагрузка ${dec1(s)} — в целевом коридоре.');
    } else if (p.hour >= 11) {
      out.add('Нагрузка пока ${dec1(s)} — до цели ещё ${dec1(t.lo - s)}.');
    }
  }
  return out.join(' ');
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Короткая причина для итога прошедшего дня.
String? _driverShort(String? driver, double? sign) {
  if (driver == null || sign == null || sign == 0) return null;
  final up = sign > 0;
  return switch (driver) {
    'hrv' => up ? 'ВСР выше нормы' : 'ВСР ниже нормы',
    'rhr' => up ? 'пульс покоя ниже обычного' : 'пульс покоя выше нормы',
    'resp' => up ? 'спокойное дыхание во сне' : 'учащённое дыхание во сне',
    'temp' => up ? null : 'температура кожи выше обычного',
    _ => null,
  };
}

String? _driverPhrase(String? driver, double? sign) {
  if (driver == null || sign == null || sign == 0) return null;
  final up = sign > 0;
  return switch (driver) {
    'hrv' =>
      up
          ? 'Главный плюс — вариабельность пульса выше вашей нормы.'
          : 'Тянет вниз вариабельность пульса — ниже вашей нормы.',
    'rhr' =>
      up
          ? 'Пульс покоя ниже обычного — хороший знак.'
          : 'Пульс покоя выше обычного — следите за самочувствием.',
    'resp' =>
      up
          ? 'Дыхание во сне спокойнее обычного.'
          : 'Дыхание во сне чаще обычного.',
    'temp' =>
      up
          ? 'Температура кожи в норме.'
          : 'Температура кожи выше обычного — возможна перегрузка или начало простуды.',
    _ => null,
  };
}

// ───────────────────── B1′: состояние ночи, отбой, форматы ─────────────────────

/// Где сейчас ночь для колец «Сон» и «Восстановление» (ТЗ v2 §10.1).
enum NightPhase {
  /// Ночь посчитана (или это прошлый день).
  done,

  /// Ночь ещё идёт и данные с браслета свежие — «идёт сон».
  asleep,

  /// Ночь не закрыта, а данные устарели > 10 мин (или идёт синхронизация) —
  /// «считаю»: забираем записи с браслета и пересчитываем.
  computing,

  /// Ночи нет (не надет / не дошла до 12:00) — «нет данных».
  none,
}

/// Порог «данные устарели» для перехода «идёт сон» → «считаю».
const Duration kNightStale = Duration(minutes: 10);

/// [recoveryState] — состояние Edge (`night_in_progress` | `provisional` |
/// `final` | null); [hasNight] — у дня есть длительность сна; [dataEdge] —
/// время последней записи с браслета; [syncing] — идёт синхронизация.
NightPhase ritmNightPhase({
  required bool hasNight,
  required String? recoveryState,
  required DateTime now,
  DateTime? dataEdge,
  bool syncing = false,
  bool isToday = true,
}) {
  if (!isToday) return hasNight ? NightPhase.done : NightPhase.none;
  final stale = dataEdge == null || now.difference(dataEdge) > kNightStale;
  if (recoveryState == 'night_in_progress') {
    return syncing || stale ? NightPhase.computing : NightPhase.asleep;
  }
  if (hasNight) return NightPhase.done;
  // Ночи нет: до полудня — если данные не дошли, это «считаю», а не «нет».
  if (now.hour < 12 && (syncing || (dataEdge != null && stale))) {
    return NightPhase.computing;
  }
  return NightPhase.none;
}

/// Рекомендованный отбой (минуты от полуночи): подъём − потребность −
/// латентность засыпания (по умолчанию 15 мин). Null без подъёма/потребности.
///
/// [awakeMin] — сколько обычно лежишь без сна (засыпание + пробуждения за
/// ночь, по эффективности сна): если известно, отбой = подъём − потребность −
/// бодрствование (латентность уже внутри).
int? ritmBedtime({
  int? wakeMinOfDay,
  num? needMin,
  num? latencyMin,
  num? awakeMin,
}) {
  if (wakeMinOfDay == null || needMin == null || needMin <= 0) return null;
  final lat = awakeMin != null
      ? awakeMin.round().clamp(0, 180)
      : (latencyMin ?? 15).round().clamp(0, 90);
  return (wakeMinOfDay - needMin.round() - lat) % 1440;
}

/// Минуты без сна в кровати при потребности [needMin] и эффективности сна
/// [effPct] (медиана последних ночей): need / eff − need.
int? awakeForNeed(num? needMin, num? effPct) {
  if (needMin == null || effPct == null || effPct < 60 || effPct > 100) {
    return null;
  }
  return (needMin * (100 / effPct - 1)).round();
}

/// «7 512» — разряды через узкий неразрывный пробел (U+202F).
String thousands(num v) {
  final n = v.round();
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '−' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('\u202F');
    b.write(s[i]);
  }
  return b.toString();
}

/// «72%» — без пробела.
String pct(num v) => '${v.round()}%';

/// Знак дельты по-русски: «+4», «−2», «0».
String signed(num v, {bool decimal = false}) {
  final t = decimal ? dec1(v.abs()) : v.abs().round().toString();
  if (v > 0) return '+$t';
  if (v < 0) return '−$t';
  return decimal ? '0,0' : '0';
}
