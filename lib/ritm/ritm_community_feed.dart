// «Ритм» B5 — итог дня для «Сообщества» из колец v3 (ТЗ v2 §7).
//
// На сервер уходят ТОЛЬКО четыре числа и тренировки (тип, минуты, нагрузка):
// оценка сна v2 (%), Восстановление (%), Нагрузка дня и недели. Пульса, ВСР,
// ЭКГ, стресса и биовозраста в [RDaySummary] нет по построению.

import 'ritm_community_api.dart' show RDaySummary, RWorkout, ritmWorkoutKey;
import 'ritm_rings_store.dart' show RitmRingsDay, RitmRingsStore, RingDayInputs;

/// Нагрузка недели: сумма Нагрузок 7 дней, заканчивая [day] (как «неделя» колец).
double? strainWeekOf(String day, List<RingDayInputs> all) {
  final end = DateTime.parse(day);
  var sum = 0.0, n = 0;
  for (final x in all) {
    final back = end.difference(DateTime.parse(x.day)).inHours / 24;
    if (back < -.5 || back > 6.5) continue;
    final s = x.strain?.strain;
    if (s != null) {
      sum += s;
      n++;
    }
  }
  return n == 0 ? null : double.parse(sum.toStringAsFixed(1));
}

/// Сессии дня Edge (`type`, `duration_min`, `start_ts`, `strain`) → тренировки ленты.
List<RWorkout> ritmFeedWorkouts(List<Map<String, dynamic>> sessions) => [
  for (final s in sessions)
    if (((s['duration_min'] as num?) ?? 0) >= 1)
      RWorkout(
        ritmWorkoutKey(s['type']?.toString()),
        (s['duration_min'] as num).round().clamp(1, 1440),
        strain: (s['strain'] as num?)?.toDouble().clamp(0, 21).toDouble(),
        endTs: (s['end_ts'] as num?)?.toInt() ??
            ((s['start_ts'] as num?) == null
                ? null
                : (s['start_ts'] as num).toInt() + (s['duration_min'] as num).round() * 60),
      ),
];

/// Итог дня из колец v3 + сессий.
RDaySummary ritmDaySummary(
  RitmRingsDay d, {
  List<Map<String, dynamic>> sessions = const [],
  List<RingDayInputs>? all,
}) => RDaySummary(
  date: d.inputs.day,
  sleepPct: d.sleepScore?.pct.round(),
  recovery: d.recovery.value,
  strainDay: d.inputs.strain?.strain == null ? null : double.parse(d.inputs.strain!.strain.toStringAsFixed(1)),
  strainWeek: strainWeekOf(d.inputs.day, all ?? RitmRingsStore.days),
  workouts: ritmFeedWorkouts(sessions),
);
