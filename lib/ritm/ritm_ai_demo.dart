// «Ритм» B6½ — демо Помощника для скриншотов (только DEBUG + RITM_DEMO).
//
// Без сети и без ключа: «модель» строит ответ из того же снимка, что ушёл бы в
// OpenAI, — поэтому все числа совпадают с экранами. Один пункт «Утра» нарочно
// с чужой цифрой: на скрине видно, что механическая проверка его скрыла.
// Журнал расходов засеян неделей типичного использования на gpt-5.4-mini
// (цены — таблица kRitmAiPrices; это пример, не счёт OpenAI).

import 'dart:convert';

import 'ritm_ai.dart';

String _f(num v) {
  final s = v is int || v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
  return s.replaceAll('.', ',');
}

Map<String, dynamic>? _snapFrom(String user) {
  final i = user.indexOf('{');
  if (i < 0) return null;
  try {
    return (jsonDecode(user.substring(i)) as Map).cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

Map _m(Object? v) => v is Map ? v : const {};

/// Ответ демо-«модели» по снимку.
Map<String, dynamic> ritmAiDemoAnswer(RitmAiKind kind, Map<String, dynamic> s) {
  final rec = _m(s['recovery']);
  final sl = _m(s['sleep']);
  final ni = _m(s['night']);
  final no = _m(s['norms_30d']);
  final st = _m(s['strain']);
  final to = _m(s['tonight']);
  final reasons = <Map<String, dynamic>>[];
  void add(String claim, String metric, Object? value, [num? baseline]) {
    if (value == null) return;
    reasons.add({'claim': claim, 'metric': metric, 'value': value, 'baseline': baseline});
  }

  final hrv = ni['hrv_ms'] as num?, hrvN = no['hrv_ms'] as num?;
  final rhr = ni['resting_hr_bpm'] as num?, rhrN = no['resting_hr_bpm'] as num?;
  final resp = ni['resp_rpm'] as num?, respN = no['resp_rpm'] as num?;
  final lo = st['target_lo'], hi = st['target_hi'];
  final corridor = lo == null ? 'Нагрузка по самочувствию' : 'Нагрузка сегодня ${_f(lo)}–${_f(hi)}';

  switch (kind) {
    case RitmAiKind.week:
      final w = _m(s['this_week_median']);
      final p = _m(s['prev_4_weeks_median']);
      void cmp(String key, String name, String unit, {bool lowerBetter = false, bool neutral = false}) {
        final a = w[key], b = p[key];
        if (a is! num) return;
        if (b is! num) {
          add('$name — ${_f(a)}$unit (медиана недели)', 'this_week_median.$key', a);
          return;
        }
        // Сравниваем то, что видно в тексте (после округления).
        final d = num.parse(_f(a).replaceAll(',', '.')) - num.parse(_f(b).replaceAll(',', '.'));
        final word = d == 0
            ? 'как обычно'
            : neutral
            ? (d > 0 ? 'больше обычного' : 'меньше обычного')
            : ((d > 0) != lowerBetter ? 'лучше обычного' : 'хуже обычного');
        add('$name ${_f(a)}$unit против ${_f(b)}$unit за 4 недели — $word', 'this_week_median.$key', a, b);
      }

      cmp('sleep_pct', 'Сон', ' %');
      cmp('consistency_pct', 'Регулярность', ' %');
      cmp('recovery_pct', 'Восстановление', ' %');
      cmp('strain', 'Нагрузка', '', neutral: true);
      cmp('resting_hr_bpm', 'Пульс покоя', '', lowerBetter: true);
      cmp('hrv_ms', 'ВСР', ' мс');
      final days = (s['days'] as List?) ?? const [];
      var maxI = -1;
      num maxV = -1;
      for (var i = 0; i < days.length; i++) {
        final v = _m(days[i])['strain'];
        if (v is num && v > maxV) (maxI, maxV) = (i, v);
      }
      if (maxI >= 0) {
        add('Самый тяжёлый день недели — Нагрузка ${_f(maxV)}', 'days.$maxI.strain', maxV);
      }
      final sp = _m(s['this_week_median'])['consistency_pct'];
      return {
        'headline': 'Неделя: сон ниже обычного, нагрузка ровная',
        'reasons': reasons,
        'action': sp is num
            ? 'Фокус недели — регулярность: ложиться в одно время (сейчас ${_f(sp)} %)'
            : 'Фокус недели — ложиться в одно время',
        'confidence': 'medium',
      };
    case RitmAiKind.bedtime:
      final bt = to['bedtime'], need = to['need_hm'];
      add('Долг сна ${sl['debt_hm']} — ночь длиннее обычной закроет его', 'sleep.debt_hm', sl['debt_hm']);
      if (st['today_so_far'] is num) {
        add('Нагрузка сегодня ${_f(st['today_so_far'] as num)} добавляет к потребности', 'strain.today_so_far', st['today_so_far']);
      }
      add(to['alarm'] == true ? 'Подъём в ${to['wake']} — по будильнику' : 'Подъём в ${to['wake']} — как сегодня', 'tonight.wake', to['wake']);
      return {
        'headline': 'Отбой в $bt, чтобы закрыть $need',
        'reasons': reasons,
        'action': 'За час до $bt — без экрана и тяжёлой еды',
        'confidence': 'high',
      };
    case RitmAiKind.ask:
      final q = '${s['question'] ?? ''}'.toLowerCase();
      final screen = '${s['screen'] ?? ''}';
      if (q.contains('лечь') || q.contains('выспаться')) {
        add('Отбой в ${to['bedtime']} закроет потребность ${to['need_hm']}', 'tonight.bedtime', to['bedtime']);
        add('Долг сна ${sl['debt_hm']} — его и закрываем', 'sleep.debt_hm', sl['debt_hm']);
        return {
          'headline': 'Лягте в ${to['bedtime']} — подъём в ${to['wake']}',
          'reasons': reasons,
          'action': 'Будильник на ${to['wake']}, за час до сна — без экрана',
          'confidence': 'high',
        };
      }
      if (q.contains('против обычн')) {
        if (hrv != null && hrvN != null) add('ВСР в глубоком сне ${_f(hrv)} мс против нормы ${_f(hrvN)} мс', 'night.hrv_ms', hrv, hrvN);
        if (rhr != null && rhrN != null) add('Пульс покоя ${_f(rhr)} против ${_f(rhrN)} обычно', 'night.resting_hr_bpm', rhr, rhrN);
        final sc = sl['score_pct'], scN = no['sleep_score_pct'];
        if (sc is num && scN is num) add('Сон ${_f(sc)} % против ${_f(scN)} % обычно', 'sleep.score_pct', sc, scN);
        return {
          'headline': 'Ночь лучше обычной по сердцу, чуть короче по сну',
          'reasons': reasons,
          'action': '$corridor — запас есть',
          'confidence': 'medium',
        };
      }
      if (screen == 'strain' || q.contains('нагрузк')) {
        final now = st['today_so_far'];
        if (now is num) add('Набрано ${_f(now)} из коридора ${_f(lo ?? 0)}–${_f(hi ?? 0)}', 'strain.today_so_far', now);
        if (rec['pct'] is num) add('Восстановление ${_f(rec['pct'] as num)} % — «${rec['zone']}»', 'recovery.pct', rec['pct']);
        return {
          'headline': lo == null ? 'Нагрузка — по самочувствию' : 'Можно ещё: коридор ${_f(lo)}–${_f(hi)}',
          'reasons': reasons,
          'action': 'Интервальная тренировка доведёт день до коридора',
          'confidence': 'medium',
        };
      }
      if (screen == 'night' || q.contains('просып')) {
        final sf = _m(s['screen_facts']);
        if (sf['awakenings_long'] is num) {
          add('Долгих пробуждений: ${sf['awakenings_long']}, коротких: ${sf['awakenings_short']}', 'screen_facts.awakenings_long', sf['awakenings_long']);
        }
        if (resp != null && respN != null) add('Дыхание ${_f(resp)} при норме ${_f(respN)} — ровное', 'night.resp_rpm', resp, respN);
        add('Отбой был в ${sl['bedtime']}, подъём в ${sl['wake']}', 'sleep.bedtime', sl['bedtime']);
        return {
          'headline': 'Пробуждения короткие — ночь цельная',
          'reasons': reasons,
          'action': 'Ложитесь в то же время — регулярность держит ночь ровной',
          'confidence': 'medium',
        };
      }
      // «Почему …?» — Восстановление / Сон.
      if (screen == 'sleep') {
        add('Спали ${sl['asleep_hm']} из нужных ${sl['need_hm']}', 'sleep.asleep_hm', sl['asleep_hm']);
        final parts = _m(sl['parts']);
        if (parts['consistency_pct'] is num) {
          add('Регулярность ${_f(parts['consistency_pct'] as num)} % — отбой гуляет', 'sleep.parts.consistency_pct', parts['consistency_pct']);
        }
        if (parts['efficiency_pct'] is num) {
          add('Эффективность ${_f(parts['efficiency_pct'] as num)} % — доля сна от времени в постели', 'sleep.parts.efficiency_pct', parts['efficiency_pct']);
        }
        return {
          'headline': 'Сон ${_f(sl['score_pct'] as num)} % — не хватило длительности',
          'reasons': reasons,
          'action': 'Сегодня отбой в ${to['bedtime'] ?? 'обычное время'}',
          'confidence': 'high',
        };
      }
      if (hrv != null && hrvN != null) add('ВСР в глубоком сне ${_f(hrv)} мс — выше вашей нормы ${_f(hrvN)} мс', 'night.hrv_ms', hrv, hrvN);
      if (rhr != null && rhrN != null) add('Пульс покоя ${_f(rhr)} — ниже нормы ${_f(rhrN)}', 'night.resting_hr_bpm', rhr, rhrN);
      add('Сон ${sl['asleep_hm']} из ${sl['need_hm']} немного тянет вниз', 'sleep.asleep_hm', sl['asleep_hm']);
      return {
        'headline': 'Восстановление ${_f(rec['pct'] as num? ?? 0)} % держит ВСР',
        'reasons': reasons,
        'action': corridor,
        'confidence': 'high',
      };
    case RitmAiKind.morning:
    case RitmAiKind.chat:
      if (hrv != null && hrvN != null) add('ВСР в глубоком сне ${_f(hrv)} мс — на ${_f(hrv - hrvN)} мс выше вашей нормы ${_f(hrvN)}', 'night.hrv_ms', hrv, hrvN);
      if (rhr != null && rhrN != null) add('Пульс покоя ${_f(rhr)} — ниже нормы ${_f(rhrN)}: сердце отдохнуло', 'night.resting_hr_bpm', rhr, rhrN);
      add('Спали ${sl['asleep_hm']} из нужных ${sl['need_hm']}', 'sleep.asleep_hm', sl['asleep_hm']);
      if (resp != null && respN != null) add('Дыхание ${_f(resp)} — как обычно (${_f(respN)})', 'night.resp_rpm', resp, respN);
      // Нарочно чужая цифра: в снимке глубокий сон другой — пункт скроется.
      add('Глубокого сна 2:10 — больше обычного', 'sleep.stages_estimate.deep_min', 130, no['deep_min'] as num?);
      return {
        'headline': 'Восстановление ${_f(rec['pct'] as num? ?? 0)} % — «${rec['zone']}»: ВСР выше нормы, сна чуть меньше нужного',
        'reasons': reasons,
        'action': '$corridor: Восстановление позволяет интервалы',
        'confidence': 'medium',
      };
  }
}

/// Транспорт демо: ответ по снимку, usage ≈ как у gpt-5.4-mini.
RitmAiTransport ritmAiDemoTransport() =>
    ({required String system, required String user, required RitmAiKind kind}) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final s = _snapFrom(user) ?? const <String, dynamic>{};
      final ans = jsonEncode(ritmAiDemoAnswer(kind, s));
      return (
        text: ans,
        // «Утро» — те же токены, что в журнале демо (s96/s97 ↔ s109).
        usage: kind == RitmAiKind.morning
            ? const {'input_tokens': 2480, 'input_tokens_details': {'cached_tokens': 1100}, 'output_tokens': 310}
            : {
          'input_tokens': ((system.length + user.length) / 3.2).round(),
          'input_tokens_details': {'cached_tokens': (system.length / 3.2).round()},
          'output_tokens': (ans.length / 3.2).round(),
        },
        model: kRitmAiDefaultModel,
      );
    };

/// Журнал демо: 7 дней обычного использования (Утро + 3 вопроса в день).
List<RitmAiLogEntry> ritmAiDemoLog(DateTime now) {
  final out = <RitmAiLogEntry>[];
  for (var back = 6; back >= 0; back--) {
    final d = DateTime(now.year, now.month, now.day - back);
    out.add(RitmAiLogEntry(
      // Сегодня «Утро» сделано при открытии (время демо), прошлые дни — в 07:12.
      ts: (back == 0 ? now : d.add(const Duration(hours: 7, minutes: 12))).millisecondsSinceEpoch,
      kind: RitmAiKind.morning,
      model: kRitmAiDefaultModel,
      usage: (input: 2480, cached: 1100, output: 310),
      ok: true,
      sent: back == 0 ? null : '{}',
    ));
    if (back == 0) continue; // сегодня — пока только «Утро» (оно же в кэше)
    for (var q = 0; q < 3; q++) {
      out.add(RitmAiLogEntry(
        ts: d.add(Duration(hours: 9 + q * 4, minutes: 5 + q * 11)).millisecondsSinceEpoch,
        kind: q == 0 ? RitmAiKind.ask : RitmAiKind.chat,
        model: kRitmAiDefaultModel,
        usage: back == 3 && q == 2 ? null : (input: 4100, cached: 2300, output: 420),
        ok: !(back == 3 && q == 2),
        error: back == 3 && q == 2 ? 'offline' : null,
      ));
    }
    if (back == 5) {
      out.add(RitmAiLogEntry(
        ts: DateTime(d.year, d.month, d.day, 19).millisecondsSinceEpoch,
        kind: RitmAiKind.week,
        model: kRitmAiDefaultModel,
        usage: (input: 3200, cached: 1100, output: 520),
        ok: true,
      ));
    }
  }
  return out;
}
