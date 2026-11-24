// «Ритм» B6½ — Помощник v2: движок (ТЗ v3 §4.4 A1–A6, §10; SLEEP_AI §5).
//
// Сценарии «Утро», «Спросить», «Итоги недели», «Отбой» — один запрос на ключе
// пользователя (BYOK, CoachConfig + CoachEngine.postChat), структурированный
// ответ {headline, reasons[{claim, metric, value, baseline}], action,
// confidence} и МЕХАНИЧЕСКАЯ проверка: пункт, чьей цифры нет в отправленном
// снимке, не показывается. Чат (кнопка у таб-бара) — инструменты Edge с русской
// надстройкой и выключенными по умолчанию кривыми ночи и ЭКГ.
//
// Наружу уходит только снимок агрегатов (≈ 600–900 токенов): ни имени, ни даты
// рождения, ни координат, ни сырых потоков, ни ЭКГ-волн. Экран «Что видела
// модель» показывает ровно отправленный JSON (тот же объект, что ушёл в запрос).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coach/coach_config.dart';
import '../coach/coach_engine.dart';
import '../coach/coach_db.dart' show CoachDbPolicy;
import 'ritm_rings.dart' show kRecMinNights;
import 'ritm_rings_store.dart' show RitmRingsDay;
import 'ritm_scores.dart' show recoveryZone, recoveryWord, strainTargetFor, hmm;
import 'ritm_sleep.dart' show TonightPlan, planBedtime, planNeedOf;

// ───────────────────────── модели и цены ─────────────────────────

/// Сценарии — для журнала, кэша и подсказки.
enum RitmAiKind { morning, ask, week, bedtime, chat }

String ritmAiKindRu(RitmAiKind k) => switch (k) {
  RitmAiKind.morning => 'Утро',
  RitmAiKind.ask => 'Спросить',
  RitmAiKind.week => 'Итоги недели',
  RitmAiKind.bedtime => 'Отбой',
  RitmAiKind.chat => 'Чат',
};

/// Модель по умолчанию — «Экономно» (ТЗ v3 §10).
const String kRitmAiDefaultModel = 'gpt-5.4-mini';

/// Три кнопки выбора модели: «Экономно · Умно · Свой».
typedef RitmAiPreset = ({String id, String title, String? model, String month});
const List<RitmAiPreset> kRitmAiPresets = [
  (id: 'economy', title: 'Экономно', model: 'gpt-5.4-mini', month: '≈ 1,1 \$/мес'),
  (id: 'smart', title: 'Умно', model: 'gpt-5.2', month: '≈ 2,8 \$/мес'),
  (id: 'custom', title: 'Свой', model: null, month: 'по тарифу'),
];

/// Какая кнопка горит для модели [model].
String ritmAiPresetOf(String model) {
  final m = model.trim();
  for (final p in kRitmAiPresets) {
    if (p.model == m) return p.id;
  }
  return 'custom';
}

/// Цены OpenAI на 15.10.2026, $ за 1 млн токенов: вход / кэш входа / выход
/// (SLEEP_AI §5.5). Неизвестная модель — расход только в токенах.
const Map<String, (double, double, double)> kRitmAiPrices = {
  'gpt-5.4-mini': (0.75, 0.075, 4.5),
  'gpt-5-mini': (0.25, 0.025, 2.0),
  'gpt-5.2': (1.75, 0.175, 14.0),
  'gpt-5.4': (2.5, 0.25, 15.0),
};

(double, double, double)? ritmAiPriceOf(String model) {
  final m = model.trim().toLowerCase();
  // Самый длинный префикс: «gpt-5.4-mini-2026-…» → gpt-5.4-mini, не gpt-5.4.
  String? best;
  for (final k in kRitmAiPrices.keys) {
    if ((m == k || m.startsWith('$k-')) && (best == null || k.length > best.length)) best = k;
  }
  return best == null ? null : kRitmAiPrices[best];
}

/// Токены из поля `usage` ответа (Chat Completions или Responses).
typedef RitmAiUsage = ({int input, int cached, int output});

RitmAiUsage? ritmAiParseUsage(Object? u) {
  if (u is! Map) return null;
  int n(Object? x) => x is num ? x.toInt() : 0;
  final input = n(u['input_tokens'] ?? u['prompt_tokens']);
  final output = n(u['output_tokens'] ?? u['completion_tokens']);
  final det = u['input_tokens_details'] ?? u['prompt_tokens_details'];
  final cached = det is Map ? n(det['cached_tokens']) : 0;
  if (input == 0 && output == 0) return null;
  return (input: input, cached: cached, output: output);
}

/// Стоимость запроса в $ или null (цена модели неизвестна).
double? ritmAiCost(String model, RitmAiUsage u) {
  final p = ritmAiPriceOf(model);
  if (p == null) return null;
  final fresh = math.max(0, u.input - u.cached);
  return (fresh * p.$1 + u.cached * p.$2 + u.output * p.$3) / 1e6;
}

/// «0,04 $» / «< 0,01 $».
String ritmUsd(double v) {
  if (v > 0 && v < 0.005) return '< 0,01 \$';
  return '${v.toStringAsFixed(2).replaceAll('.', ',')} \$';
}

// ───────────────────────── настройки ─────────────────────────

/// Переключатели доступа и сценариев (ТЗ v3 §9 «Ещё → Помощник»).
class RitmAiPrefs {
  RitmAiPrefs._();
  static const _kCurves = 'ritm_ai_curves';
  static const _kEcg = 'ritm_ai_ecg';
  static const _kMorning = 'ritm_ai_morning';
  static const _kWeek = 'ritm_ai_week';
  static const _kBedtime = 'ritm_ai_bedtime';
  static const _kBlockUntil = 'ritm_ai_block_until';
  static const _kBlockWhy = 'ritm_ai_block_why';

  /// Кривые ночи (v_series/v_hypnogram) — выкл. по умолчанию.
  static final curves = ValueNotifier<bool>(false);

  /// ЭКГ (сводки и волна) — выкл. по умолчанию.
  static final ecg = ValueNotifier<bool>(false);

  /// «Утро» автоматически — вкл.
  static final morningAuto = ValueNotifier<bool>(true);

  /// «Итоги недели» (вс 19:00) — вкл.
  static final weekly = ValueNotifier<bool>(true);

  /// «Отбой» (20:30) — вкл.
  static final bedtime = ValueNotifier<bool>(true);

  /// Ключ не принят / лимит: до какого момента не повторять автоматически.
  static int blockUntilMs = 0;
  static String blockWhy = '';
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      curves.value = p.getBool(_kCurves) ?? false;
      ecg.value = p.getBool(_kEcg) ?? false;
      morningAuto.value = p.getBool(_kMorning) ?? true;
      weekly.value = p.getBool(_kWeek) ?? true;
      bedtime.value = p.getBool(_kBedtime) ?? true;
      blockUntilMs = p.getInt(_kBlockUntil) ?? 0;
      blockWhy = p.getString(_kBlockWhy) ?? '';
    } catch (_) {}
    applyChatPolicy();
  }

  static Future<void> set(ValueNotifier<bool> n, bool v) async {
    n.value = v;
    final key = identical(n, curves)
        ? _kCurves
        : identical(n, ecg)
        ? _kEcg
        : identical(n, morningAuto)
        ? _kMorning
        : identical(n, weekly)
        ? _kWeek
        : _kBedtime;
    try {
      (await SharedPreferences.getInstance()).setBool(key, v);
    } catch (_) {}
    applyChatPolicy();
  }

  static Future<void> block(String why, {Duration d = const Duration(hours: 1), DateTime? now}) async {
    blockUntilMs = (now ?? DateTime.now()).add(d).millisecondsSinceEpoch;
    blockWhy = why;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kBlockUntil, blockUntilMs);
      await p.setString(_kBlockWhy, why);
    } catch (_) {}
  }

  static Future<void> unblock() async {
    blockUntilMs = 0;
    blockWhy = '';
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kBlockUntil);
      await p.remove(_kBlockWhy);
    } catch (_) {}
  }

  static bool blocked([DateTime? now]) => (now ?? DateTime.now()).millisecondsSinceEpoch < blockUntilMs;
}

/// Русская надстройка над `kCoachSystemPrompt` для чата (A1).
const String kRitmChatOverlay = '''
ПРАВИЛА «РИТМА» (важнее всего выше):
- Отвечай ТОЛЬКО по-русски, коротко, на «вы». Названия: «Восстановление» (не readiness/recovery), «Нагрузка» (не strain), «ВСР» (не HRV/RMSSD), «пульс покоя», «ваша норма» (не baseline).
- Каждая оценка — с числом и личной нормой; числа — только те, что вернули инструменты в этом разговоре.
- Не повторяй то, что уже на экране, — объясняй «почему» и что делать.
- Не диагноз и не лечение; без слов «фибрилляция», «апноэ», AHI. Нерегулярный ритм — «покажите врачу».
- Стадии сна — это оценка; если уверенность низкая, выводов о глубоком и быстром сне не делай. REM называй «быстрый сон».
- Если данных нет — скажи, чего не хватает.
- Восстановление: 67–100 — «Готов», 34–66 — «Умеренно», 0–33 — «Отдых». Нагрузка 0–21.''';

/// Политика чата Edge: русская надстройка, статусы по-русски, выключенные
/// инструменты/представления по переключателям (кривые ночи, ЭКГ).
void applyChatPolicy() {
  CoachEngine.systemOverlay = kRitmChatOverlay;
  CoachEngine.statusLines = const [
    'Смотрю вашу ночь…',
    'Сверяю с вашей нормой…',
    'Считаю по дням…',
    'Читаю сводки…',
  ];
  CoachEngine.giveUpText = 'Не получилось уложиться в несколько шагов — попробуйте спросить уже.';
  CoachEngine.deniedTools = {if (!RitmAiPrefs.ecg.value) 'get_ecg_reading'};
  CoachDbPolicy.denied = {
    if (!RitmAiPrefs.curves.value) ...{'v_series', 'v_hypnogram'},
    if (!RitmAiPrefs.ecg.value) 'v_ecg_readings',
  };
  CoachEngine.usageSink = (model, usage, tag) {
    final u = ritmAiParseUsage(usage);
    if (u == null) return;
    final kind = RitmAiKind.values.where((k) => k.name == tag).firstOrNull ?? RitmAiKind.chat;
    // Структурированные сценарии пишут журнал сами (со снимком).
    if (kind != RitmAiKind.chat) return;
    unawaited(RitmAiLog.add(RitmAiLogEntry(
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      model: model,
      usage: u,
      ok: true,
    )));
  };
}

// ───────────────────────── снимок ─────────────────────────

num _r(num? v, [int dp = 0]) {
  if (v == null) return 0;
  final s = num.parse(v.toStringAsFixed(dp));
  return dp == 0 ? s.round() : s;
}

String _hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const _drvRu = {'hrv': 'ВСР', 'rhr': 'пульс покоя', 'resp': 'дыхание', 'sleep': 'сон', 'temp': 'температура'};

/// План «Сегодня ночью» по кольцам дня — ОДИН для главной, «Сна», «Утра» и
/// «Отбоя». FIX84: подъём — будильник в ближайшие сутки, иначе ОБЫЧНОЕ время
/// подъёма (медиана пробуждений), а не время последнего пробуждения;
/// потребность — с долгом не больше +60 мин за ночь ([planNeedOf]).
TonightPlan? ritmTonightPlan(
  RitmRingsDay r,
  DateTime now, {
  DateTime? alarmAt,
  int? effPct,
  int latency = 10,
}) {
  final t = r.tonight;
  if (t == null) return null;
  DateTime? wake = alarmAt;
  if (wake == null) {
    var u = r.usualWake;
    if (u == null && r.inputs.night.wakeTs != null) {
      final w = DateTime.fromMillisecondsSinceEpoch(r.inputs.night.wakeTs! * 1000);
      final m = w.hour * 60 + w.minute;
      if (m >= 180 && m <= 780) u = m;
    }
    if (u == null) return null;
    var c = DateTime(now.year, now.month, now.day, u ~/ 60, u % 60);
    if (!c.isAfter(now)) c = DateTime(now.year, now.month, now.day + 1, u ~/ 60, u % 60);
    wake = c;
  }
  return (
    wake: wake,
    alarm: alarmAt != null,
    need: planNeedOf(t),
    eff: (effPct ?? r.inputs.eff ?? 90).round().clamp(60, 100),
    latency: latency,
  );
}

/// Снимок для «Утра» / «Спросить» / «Отбоя» — только агрегаты. Поля, которых
/// нет, не пишутся, а перечисляются в `missing` (модель должна сказать, чего
/// не хватает, а не додумывать).
Map<String, dynamic> ritmAiSnapshot(
  RitmRingsDay r, {
  RitmAiKind kind = RitmAiKind.morning,
  TonightPlan? plan,
  double? strainYesterday,
  String? screen,
  String? question,
  bool curvesAllowed = false,
}) {
  final missing = <String>[];
  final out = <String, dynamic>{
    'scenario': kind.name,
    'date': r.inputs.day,
    'screen': ?screen,
    'question': ?question,
  };
  // Восстановление: число + зона словом (авторитет для тона).
  final rec = r.recovery;
  if (rec.value != null) {
    final z = recoveryZone(rec.value);
    out['recovery'] = {
      'pct': rec.value,
      'zone': z == null ? null : recoveryWord(z),
      if (r.prevRecovery != null) 'yesterday_pct': r.prevRecovery,
      'nights_in_norm': rec.nights,
      if (rec.preliminary) 'preliminary': true,
      if (rec.drivers.isNotEmpty)
        'drivers_pp': {for (final d in rec.drivers) d.key: _r(d.points, 1)},
    };
  } else {
    missing.add(switch (rec.why) {
      'short_night' => 'recovery: ночь короче 3 ч',
      'calibrating' => 'recovery: калибровка (${rec.nights} из $kRecMinNights ночей)',
      _ => 'recovery: нет данных ночи',
    });
  }
  // Сон.
  final x = r.inputs;
  final tst = x.night.tstMin > 0 ? x.night.tstMin : null;
  final sleep = <String, dynamic>{};
  final sc = r.sleepScore;
  if (sc != null) {
    sleep['score_pct'] = _r(sc.pct);
    sleep['zone'] = sc.word;
    sleep['parts'] = {
      'duration_pct': _r(sc.s),
      if (sc.c != null) 'consistency_pct': _r(sc.c),
      if (sc.e != null) 'efficiency_pct': _r(sc.e),
      if (sc.x != null) 'stress_pct': _r(sc.x),
    };
  }
  if (tst != null) {
    sleep['asleep_min'] = tst;
    sleep['asleep_hm'] = hmm(tst);
  }
  final need = r.need?.need ?? x.needMin;
  if (need != null) {
    sleep['need_min'] = _r(need);
    sleep['need_hm'] = hmm(need);
  }
  final debt = r.need?.debt ?? x.debtMin;
  if (debt != null) {
    sleep['debt_min'] = _r(debt);
    sleep['debt_hm'] = hmm(debt);
  }
  if (x.night.onsetTs != null) sleep['bedtime'] = _hhmm(DateTime.fromMillisecondsSinceEpoch(x.night.onsetTs! * 1000));
  if (x.night.wakeTs != null) sleep['wake'] = _hhmm(DateTime.fromMillisecondsSinceEpoch(x.night.wakeTs! * 1000));
  // Уверенность стадий — как бейдж «оценка» на «Ночи»: пульс есть ≥ 85 % ночи.
  final conf = x.deepMin == null && x.remMin == null ? null : (x.night.hrValidFrac >= .85 ? 'med' : 'low');
  if (conf != null) {
    sleep['stages_estimate'] = {
      if (x.deepMin != null) 'deep_min': _r(x.deepMin),
      if (x.remMin != null) 'rem_min': _r(x.remMin),
      if (x.lightMin != null) 'light_min': _r(x.lightMin),
    };
    sleep['stages_confidence'] = conf;
  }
  if (sleep.isEmpty) {
    missing.add('sleep: ночь не записана');
  } else {
    out['sleep'] = sleep;
  }
  // Ночь: пульс покоя, ВСР (последний глубокий сон), дыхание, температура.
  final night = <String, dynamic>{
    if (x.night.rhrSleepMean != null) 'resting_hr_bpm': _r(x.night.rhrSleepMean),
    if (x.night.rmssdSwsLast != null) 'hrv_ms': _r(x.night.rmssdSwsLast),
    if (x.resp != null) 'resp_rpm': _r(x.resp, 1),
    if (x.tempDev != null) 'temp_dev_c': _r(x.tempDev, 1),
  };
  if (night.isNotEmpty) out['night'] = night;
  if (x.night.rmssdSwsLast == null) missing.add('night.hrv_ms: нет окон ВСР');
  // Нормы 30 ночей.
  final n = r.norms;
  final norms = <String, dynamic>{
    if (n['rhr'] != null) 'resting_hr_bpm': _r(n['rhr']),
    if (n['hrv'] != null) 'hrv_ms': _r(n['hrv']),
    if (n['resp'] != null) 'resp_rpm': _r(n['resp'], 1),
    if (n['sleep'] != null) 'sleep_score_pct': _r(n['sleep']),
    if (n['deep'] != null) 'deep_min': _r(n['deep']),
    if (n['rem'] != null) 'rem_min': _r(n['rem']),
  };
  if (norms.isNotEmpty) {
    norms['nights'] = 30;
    out['norms_30d'] = norms;
  }
  // Нагрузка и коридор на сегодня.
  final zone = recoveryZone(rec.value);
  final t = strainTargetFor(zone);
  out['strain'] = {
    if (x.strain != null) 'today_so_far': _r(x.strain!.strain, 1),
    'yesterday': ?(strainYesterday == null ? null : _r(strainYesterday, 1)),
    if (t != null) 'target_lo': _r(t.lo, 0),
    if (t != null) 'target_hi': _r(t.hi, 0),
    'scale_max': 21,
  };
  // Сегодня ночью.
  if (plan != null) {
    final b = planBedtime(plan);
    out['tonight'] = {
      'need_min': plan.need,
      'need_hm': hmm(plan.need),
      'bedtime': _hhmm(b),
      'wake': _hhmm(plan.wake),
      if (plan.alarm) 'alarm': true,
    };
  }
  if (!curvesAllowed) out['curves'] = 'выключены пользователем';
  if (missing.isNotEmpty) out['missing'] = missing;
  return out;
}

/// День для «Итогов недели».
typedef RitmWeekDay = ({
  String day,
  int? sleepPct,
  int? asleepMin,
  int? consistencyPct,
  int? recoveryPct,
  double? strain,
  int? rhr,
  int? hrv,
});

RitmWeekDay ritmWeekDayOf(RitmRingsDay r) => (
  day: r.inputs.day,
  sleepPct: r.sleepScore?.pct.round(),
  asleepMin: r.inputs.night.tstMin > 0 ? r.inputs.night.tstMin : null,
  consistencyPct: r.sleepScore?.c?.round(),
  recoveryPct: r.recovery.value,
  strain: r.inputs.strain == null ? null : (r.inputs.strain!.strain * 10).round() / 10,
  rhr: r.inputs.night.rhrSleepMean?.round(),
  hrv: r.inputs.night.rmssdSwsLast?.round(),
);

num? _median(Iterable<num?> xs) {
  final v = [for (final x in xs) ?x]..sort();
  if (v.isEmpty) return null;
  final m = v.length ~/ 2;
  return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
}

/// Снимок «Итогов недели»: 7 дней × метрики + медианы 4 предыдущих недель.
Map<String, dynamic> ritmAiWeekSnapshot(List<RitmWeekDay> week, List<RitmWeekDay> prev28) {
  Map<String, dynamic> row(RitmWeekDay d) => {
    'date': d.day,
    'sleep_pct': ?d.sleepPct,
    'asleep_hm': ?(d.asleepMin == null ? null : hmm(d.asleepMin!)),
    'consistency_pct': ?d.consistencyPct,
    'recovery_pct': ?d.recoveryPct,
    'strain': ?d.strain,
    'resting_hr_bpm': ?d.rhr,
    'hrv_ms': ?d.hrv,
  };
  Map<String, dynamic> med(List<RitmWeekDay> xs) => {
    'sleep_pct': ?_med0(xs.map((d) => d.sleepPct)),
    'asleep_hm': ?(_median(xs.map((d) => d.asleepMin)) == null ? null : hmm(_median(xs.map((d) => d.asleepMin))!)),
    'consistency_pct': ?_med0(xs.map((d) => d.consistencyPct)),
    'recovery_pct': ?_med0(xs.map((d) => d.recoveryPct)),
    'strain': ?(_median(xs.map((d) => d.strain)) == null ? null : _r(_median(xs.map((d) => d.strain))!, 1)),
    'resting_hr_bpm': ?_med0(xs.map((d) => d.rhr)),
    'hrv_ms': ?_med0(xs.map((d) => d.hrv)),
  };
  final missing = <String>[];
  final withRec = week.where((d) => d.recoveryPct != null).length;
  if (withRec < week.length) missing.add('recovery_pct: есть за $withRec из ${week.length} дней');
  if (prev28.isEmpty) missing.add('weeks_before: нет 4 прошлых недель');
  return {
    'scenario': 'week',
    'from': week.isEmpty ? null : week.first.day,
    'to': week.isEmpty ? null : week.last.day,
    'days': [for (final d in week) row(d)],
    'this_week_median': med(week),
    if (prev28.isNotEmpty) 'prev_4_weeks_median': med(prev28),
    if (prev28.isNotEmpty) 'prev_days': prev28.length,
    if (prev28.isNotEmpty) 'weeks_before': 4,
    'missing': ?(missing.isEmpty ? null : missing),
  };
}

num? _med0(Iterable<num?> xs) {
  final m = _median(xs);
  return m == null ? null : _r(m);
}

// ───────────────────────── проверка ответа ─────────────────────────

/// Пункт ответа после проверки.
class RitmAiReason {
  final String claim, metric;
  final Object? value;
  final num? baseline;
  final bool ok;

  /// Почему скрыт (для журнала и «скрыт 1 пункт»).
  final String? why;
  const RitmAiReason(this.claim, this.metric, this.value, this.baseline, {this.ok = true, this.why});

  Map<String, dynamic> toJson() => {'claim': claim, 'metric': metric, 'value': value, 'baseline': baseline};
}

/// Проверенный ответ.
class RitmAiAnswer {
  final String headline;
  final bool headlineOk;
  final List<RitmAiReason> reasons;
  final String action;
  final bool actionOk;
  final String confidence;
  const RitmAiAnswer({
    required this.headline,
    required this.headlineOk,
    required this.reasons,
    required this.action,
    required this.actionOk,
    required this.confidence,
  });

  List<RitmAiReason> get shown => [for (final r in reasons) if (r.ok) r];
  int get hidden => reasons.length - shown.length;

  /// Строка для карточки: заголовок модели, если прошёл проверку, иначе —
  /// первый проверенный пункт.
  String? get line => headlineOk && headline.isNotEmpty ? headline : shown.firstOrNull?.claim;
}

/// Все листья снимка: путь → значение.
Map<String, Object?> ritmAiFlatten(Object? m, [String prefix = '']) {
  final out = <String, Object?>{};
  if (m is Map) {
    m.forEach((k, v) {
      final p = prefix.isEmpty ? '$k' : '$prefix.$k';
      if (v is Map || v is List) {
        out.addAll(ritmAiFlatten(v, p));
      } else {
        out[p] = v;
      }
    });
  } else if (m is List) {
    for (var i = 0; i < m.length; i++) {
      final v = m[i];
      final p = '$prefix.$i';
      if (v is Map || v is List) {
        out.addAll(ritmAiFlatten(v, p));
      } else {
        out[p] = v;
      }
    }
  }
  return out;
}

bool _near(num a, num b) => (a - b).abs() <= math.max(0.5, b.abs() * 0.01);

num? _num(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim().replaceAll(',', '.').replaceAll('−', '-'));
  return null;
}

final _numRe = RegExp(r'\d{1,2}:\d{2}|\d+(?:[.,]\d+)?');
const _medical = ['фибрилляц', 'апноэ', 'ahi', 'диагноз:', 'аритми'];

/// Проверяет ответ модели по отправленному снимку (A5). Пункт виден, только
/// если: метрика — поле снимка; value равно значению поля; baseline (если
/// есть) — число из снимка; каждое число в тексте — из снимка или разница
/// value−baseline этого пункта; в тексте есть хотя бы одно число; нет
/// медицинских ярлыков; при `stages_confidence: low` — ни слова о стадиях.
RitmAiAnswer ritmAiVerify(Map raw, Map<String, dynamic> snapshot) {
  final flat = ritmAiFlatten(snapshot);
  final nums = <num>[];
  final strs = <String>{};
  flat.forEach((k, v) {
    final n = v is num ? v : null;
    if (n != null) nums.add(n);
    if (v is String && RegExp(r'\d').hasMatch(v)) strs.add(v.trim());
  });
  final lowStages = flat.entries.any((e) => e.key.endsWith('stages_confidence') && e.value == 'low');

  bool numberKnown(String tok, List<num> extra) {
    if (tok.contains(':')) {
      if (strs.contains(tok)) return true;
      // «7:05» и «07:05» — одно и то же время.
      final p = tok.split(':');
      final alt = '${int.parse(p[0])}:${p[1]}';
      final alt2 = '${p[0].padLeft(2, '0')}:${p[1]}';
      return strs.contains(alt) || strs.contains(alt2);
    }
    final v = _num(tok);
    if (v == null) return false;
    return nums.any((n) => _near(v, n)) || extra.any((n) => _near(v, n));
  }

  String? textProblem(String text, List<num> extra, {bool needNumber = false}) {
    final low = text.toLowerCase();
    for (final w in _medical) {
      if (low.contains(w)) return 'медицинский ярлык';
    }
    if (lowStages && RegExp(r'глубок|rem|быстр[а-я]* сон|фаз').hasMatch(low)) {
      return 'стадии: низкая уверенность';
    }
    final toks = _numRe.allMatches(text).map((m) => m.group(0)!).toList();
    if (needNumber && toks.isEmpty) return 'нет числа';
    for (final t in toks) {
      if (!numberKnown(t, extra)) return 'чужая цифра $t';
    }
    return null;
  }

  Object? lookup(String metric) {
    final m = metric.trim();
    if (flat.containsKey(m)) return flat[m];
    // Модель может опустить префикс раздела: «hrv_ms» → единственное поле.
    final tail = [for (final k in flat.keys) if (k == m || k.endsWith('.$m')) k];
    return tail.length == 1 ? flat[tail.first] : _missing;
  }

  final reasons = <RitmAiReason>[];
  for (final e in (raw['reasons'] as List? ?? const [])) {
    if (e is! Map) continue;
    final claim = '${e['claim'] ?? ''}'.trim();
    final metric = '${e['metric'] ?? ''}'.trim();
    final value = e['value'];
    final baseline = _num(e['baseline']);
    String? why;
    final snapV = lookup(metric);
    if (claim.isEmpty) {
      why = 'пусто';
    } else if (identical(snapV, _missing)) {
      why = 'нет поля $metric';
    } else {
      final a = _num(value), b = _num(snapV);
      final same = a != null && b != null ? _near(a, b) : '$value'.trim() == '$snapV'.trim();
      if (!same) why = 'value $value ≠ $snapV';
    }
    if (why == null && baseline != null && !nums.any((n) => _near(baseline, n))) {
      why = 'чужая норма $baseline';
    }
    final a = _num(value);
    final extra = <num>[
      if (a != null && baseline != null) ...[
        (a - baseline).abs(),
        if (baseline != 0) ((a - baseline) / baseline * 100).abs().round(),
      ],
    ];
    why ??= textProblem(claim, extra, needNumber: true);
    if (why == null && lowStages && RegExp(r'deep|rem|stages').hasMatch(metric)) {
      why = 'стадии: низкая уверенность';
    }
    reasons.add(RitmAiReason(claim, metric, value, baseline, ok: why == null, why: why));
  }
  final headline = '${raw['headline'] ?? ''}'.trim();
  final action = '${raw['action'] ?? ''}'.trim();
  final allExtra = <num>[
    for (final r in reasons)
      if (r.ok && _num(r.value) != null && r.baseline != null) (_num(r.value)! - r.baseline!).abs(),
  ];
  return RitmAiAnswer(
    headline: headline,
    headlineOk: headline.isNotEmpty && textProblem(headline, allExtra) == null,
    reasons: reasons,
    action: action,
    actionOk: action.isNotEmpty && textProblem(action, allExtra) == null,
    confidence: '${raw['confidence'] ?? ''}',
  );
}

const Object _missing = Object();

/// Разбор текста ответа: JSON (возможно, в ``` … ```) → Map.
Map<String, dynamic>? ritmAiParseJson(String text) {
  var t = text.trim();
  if (t.startsWith('```')) {
    final nl = t.indexOf('\n');
    t = nl < 0 ? '' : t.substring(nl + 1);
    if (t.endsWith('```')) t = t.substring(0, t.length - 3);
  }
  final a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try {
    final j = jsonDecode(t.substring(a, b + 1));
    return j is Map ? j.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

// ───────────────────────── подсказка ─────────────────────────

const String kRitmAiSystem = '''
Ты — помощник фитнес-приложения «Ритм» (браслет WHOOP + Apple Watch). Пишешь по-русски, коротко, на «вы».
ЖЁСТКИЕ ПРАВИЛА:
1. Используй ТОЛЬКО числа из присланного снимка (JSON). Каждое число в тексте — ровно как в снимке: длительности в формате Ч:ММ из полей *_hm, время суток ЧЧ:ММ, проценты и пульс — целые как в снимке. Разрешена ещё разница value−baseline того же пункта. Других чисел не пиши.
2. Каждый пункт reasons — одна причина «почему» с числом и личной нормой: metric — путь поля в снимке (например "night.hrv_ms"), value — значение этого поля, baseline — норма из norms_30d (или null).
3. recovery.zone — авторитет для тона: «Отдых» и «Умеренно» не называй хорошим восстановлением.
4. Не повторяй экран — объясняй причины и что делать сегодня.
5. Не ставь диагнозов; без слов «фибрилляция», «апноэ», AHI. Стадии сна — «оценка»; если sleep.stages_confidence = "low" — ни слова о глубоком сне и REM.
6. Если чего-то нет (missing) — скажи, чего не хватает, без догадок.
7. action — одно действие на сегодня: коридор нагрузки strain.target_lo–target_hi (без запретов «не тренируйтесь»).
Отвечай строго JSON: {"headline": "одна строка ≤ 110 знаков", "reasons": [{"claim","metric","value","baseline"}], "action": "…", "confidence": "high|medium|low"}.''';

String ritmAiTask(RitmAiKind kind) => switch (kind) {
  RitmAiKind.morning => 'Сценарий «Утро»: разбор ночи и Восстановления. headline — суть одной строкой; reasons — 3–5 причин; action — коридор нагрузки на сегодня.',
  RitmAiKind.ask => 'Сценарий «Спросить»: ответь на question с экрана screen. headline — прямой ответ; reasons — 2–4 причины с числами; action — что сделать сегодня.',
  RitmAiKind.week => 'Сценарий «Итоги недели»: что изменилось за 7 дней против медиан 4 прошлых недель. headline — главное; reasons — 6–8 строк (metric — путь вида "this_week_median.sleep_pct" или "days.3.strain", baseline — из prev_4_weeks_median); action — ОДИН фокус на неделю.',
  RitmAiKind.bedtime => 'Сценарий «Отбой»: headline строго вида «Отбой в ЧЧ:ММ, чтобы закрыть Ч:ММ» из tonight.bedtime и tonight.need_hm; reasons — 1–3 причины (долг, нагрузка, подъём); action — короткий совет на вечер.',
  RitmAiKind.chat => '',
};

/// JSON-схема структурированного ответа (structured outputs).
const Map<String, dynamic> kRitmAiSchema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['headline', 'reasons', 'action', 'confidence'],
  'properties': {
    'headline': {'type': 'string'},
    'reasons': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['claim', 'metric', 'value', 'baseline'],
        'properties': {
          'claim': {'type': 'string'},
          'metric': {'type': 'string'},
          'value': {'type': ['number', 'string']},
          'baseline': {'type': ['number', 'null']},
        },
      },
    },
    'action': {'type': 'string'},
    'confidence': {
      'type': 'string',
      'enum': ['high', 'medium', 'low'],
    },
  },
};

// ───────────────────────── журнал и кэш ─────────────────────────

class RitmAiLogEntry {
  final int ts;
  final RitmAiKind kind;
  final String model;
  final RitmAiUsage? usage;
  final bool ok;
  final String? error;

  /// Ровно отправленный снимок (для структурированных сценариев).
  final String? sent;
  final int hidden;
  const RitmAiLogEntry({
    required this.ts,
    required this.kind,
    required this.model,
    this.usage,
    required this.ok,
    this.error,
    this.sent,
    this.hidden = 0,
  });

  double? get usd => usage == null ? null : ritmAiCost(model, usage!);

  Map<String, dynamic> toJson() => {
    'ts': ts,
    'kind': kind.name,
    'model': model,
    if (usage != null) 'u': [usage!.input, usage!.cached, usage!.output],
    'ok': ok,
    'err': ?error,
    'sent': ?sent,
    if (hidden > 0) 'hidden': hidden,
  };

  static RitmAiLogEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final u = j['u'];
    return RitmAiLogEntry(
      ts: (j['ts'] as num?)?.toInt() ?? 0,
      kind: RitmAiKind.values.where((k) => k.name == j['kind']).firstOrNull ?? RitmAiKind.chat,
      model: '${j['model'] ?? ''}',
      usage: u is List && u.length == 3
          ? (input: (u[0] as num).toInt(), cached: (u[1] as num).toInt(), output: (u[2] as num).toInt())
          : null,
      ok: j['ok'] == true,
      error: j['err'] as String?,
      sent: j['sent'] as String?,
      hidden: (j['hidden'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Локальный журнал запросов (30 дней) — он же счётчик расходов.
class RitmAiLog {
  RitmAiLog._();
  static final entries = ValueNotifier<List<RitmAiLogEntry>>(const []);
  static bool _loaded = false;
  static const keepDays = 30;

  static Future<File?> _file() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return File('${d.path}/ritm_ai_log.json');
    } catch (_) {
      return null;
    }
  }

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is List) entries.value = _prune([for (final e in j) ?RitmAiLogEntry.fromJson(e)]);
    } catch (_) {}
  }

  static List<RitmAiLogEntry> _prune(List<RitmAiLogEntry> xs, [DateTime? now]) {
    final cut = (now ?? DateTime.now()).subtract(const Duration(days: keepDays)).millisecondsSinceEpoch;
    return [for (final e in xs) if (e.ts >= cut) e];
  }

  /// Демо: журнал засеян одним снимком и не растёт между кадрами.
  static bool frozen = false;

  static Future<void> add(RitmAiLogEntry e) async {
    if (frozen) return;
    await load();
    entries.value = _prune([...entries.value, e]);
    await _save();
  }

  static Future<void> clear() async {
    entries.value = const [];
    await _save();
  }

  static Future<void> _save() async {
    if (kRitmAiMemoryOnly) return;
    try {
      final f = await _file();
      await f?.writeAsString(jsonEncode([for (final e in entries.value) e.toJson()]));
    } catch (_) {}
  }

  /// Расход за период: токены и $ (только по моделям с известной ценой).
  static ({int input, int output, double usd, int calls, bool partial}) spent(DateTime from, [DateTime? to]) {
    var i = 0, o = 0, n = 0;
    var usd = 0.0;
    var partial = false;
    final a = from.millisecondsSinceEpoch, b = (to ?? DateTime(9999)).millisecondsSinceEpoch;
    for (final e in entries.value) {
      if (e.ts < a || e.ts >= b || e.usage == null) continue;
      n++;
      i += e.usage!.input;
      o += e.usage!.output;
      final c = e.usd;
      if (c == null) {
        partial = true;
      } else {
        usd += c;
      }
    }
    return (input: i, output: o, usd: usd, calls: n, partial: partial);
  }

  /// Тесты и демо.
  static void debugReset([List<RitmAiLogEntry> xs = const []]) {
    _loaded = true;
    entries.value = xs;
  }
}

/// Тесты и демо: журнал и кэш только в памяти.
bool kRitmAiMemoryOnly = false;

/// Кэш ответа сценария (офлайн: «разбор за 14.10»).
class RitmAiResult {
  final RitmAiKind kind;
  final String key;
  final Map<String, dynamic> raw;
  final Map<String, dynamic> sent;
  final String model;
  final int at;
  final RitmAiUsage? usage;
  const RitmAiResult({
    required this.kind,
    required this.key,
    required this.raw,
    required this.sent,
    required this.model,
    required this.at,
    this.usage,
  });

  RitmAiAnswer get answer => ritmAiVerify(raw, sent);

  /// Ровно отправленный JSON (то, что видела модель).
  String get sentPretty => const JsonEncoder.withIndent('  ').convert(sent);

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'key': key,
    'raw': raw,
    'sent': sent,
    'model': model,
    'at': at,
    if (usage != null) 'u': [usage!.input, usage!.cached, usage!.output],
  };

  static RitmAiResult? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final u = j['u'];
      return RitmAiResult(
        kind: RitmAiKind.values.firstWhere((k) => k.name == j['kind']),
        key: '${j['key']}',
        raw: (j['raw'] as Map).cast<String, dynamic>(),
        sent: (j['sent'] as Map).cast<String, dynamic>(),
        model: '${j['model'] ?? ''}',
        at: (j['at'] as num).toInt(),
        usage: u is List && u.length == 3
            ? (input: (u[0] as num).toInt(), cached: (u[1] as num).toInt(), output: (u[2] as num).toInt())
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class RitmAiCache {
  RitmAiCache._();
  static final Map<String, RitmAiResult> _m = {};
  static bool _loaded = false;
  static final revision = ValueNotifier<int>(0);

  static Future<File?> _file() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return File('${d.path}/ritm_ai_cache.json');
    } catch (_) {
      return null;
    }
  }

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is List) {
        for (final e in j) {
          final r = RitmAiResult.fromJson(e);
          if (r != null) _m['${r.kind.name}:${r.key}'] = r;
        }
      }
    } catch (_) {}
  }

  static RitmAiResult? get(RitmAiKind k, String key) => _m['${k.name}:$key'];

  /// Последний ответ сценария (для офлайна — с датой).
  static RitmAiResult? latest(RitmAiKind k) {
    RitmAiResult? best;
    for (final r in _m.values) {
      if (r.kind == k && (best == null || r.at > best.at)) best = r;
    }
    return best;
  }

  static Future<void> put(RitmAiResult r) async {
    _m['${r.kind.name}:${r.key}'] = r;
    // Храним последние 40 ответов.
    if (_m.length > 40) {
      final ks = _m.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in ks.take(_m.length - 40)) {
        _m.remove(e.key);
      }
    }
    revision.value++;
    if (kRitmAiMemoryOnly) return;
    try {
      final f = await _file();
      await f?.writeAsString(jsonEncode([for (final v in _m.values) v.toJson()]));
    } catch (_) {}
  }

  static Future<void> clear() async {
    _m.clear();
    revision.value++;
    try {
      final f = await _file();
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Тесты и демо.
  static void debugReset() {
    _loaded = true;
    _m.clear();
  }
}

// ───────────────────────── запрос ─────────────────────────

/// Ошибка сценария, понятная экрану.
class RitmAiError implements Exception {
  /// 'key' (401/403) | 'limit' (429) | 'offline' | 'nokey' | 'error'.
  final String code;
  final String message;
  const RitmAiError(this.code, this.message);
  @override
  String toString() => message;

  String get ru => switch (code) {
    'key' => 'Ключ не принят — проверьте его в «Ещё → Помощник»',
    'limit' => 'Лимит OpenAI — повторим не раньше чем через час',
    'offline' => 'Нет сети',
    'nokey' => 'Укажите ключ в «Ещё → Помощник»',
    _ => 'Помощник не ответил: $message',
  };
}

/// Один вызов модели: (system, user, схема) → текст ответа + usage.
typedef RitmAiTransport =
    Future<({String text, Object? usage, String model})> Function({
      required String system,
      required String user,
      required RitmAiKind kind,
    });

/// Таймаут запроса (§5.7): 60 с, одна повторная попытка.
const Duration kRitmAiTimeout = Duration(seconds: 60);

RitmAiTransport ritmAiOpenAiTransport(CoachConfig cfg) =>
    ({required String system, required String user, required RitmAiKind kind}) async {
      final model = cfg.model.isEmpty ? kRitmAiDefaultModel : cfg.model;
      final msg = await CoachEngine.postChat(cfg, {
        'model': model,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'temperature': 0.2,
        'response_format': {
          'type': 'json_schema',
          'json_schema': {'name': 'ritm_answer', 'strict': true, 'schema': kRitmAiSchema},
        },
        CoachEngine.kTagKey: kind.name,
      }).timeout(kRitmAiTimeout);
      return (text: '${msg['content'] ?? ''}', usage: msg[CoachEngine.kUsageKey], model: model);
    };

/// Сценарии Помощника.
class RitmAi {
  RitmAi._();

  /// Подмена транспорта (тесты, демо).
  static RitmAiTransport? debugTransport;

  /// Часы (демо — 09:41 как в строке состояния).
  static DateTime Function() clock = DateTime.now;

  /// Идущие запросы по ключу кэша: второй вызов ждёт первый («Утро» не уходит дважды).
  static final Map<String, Future<RitmAiResult>> _inflight = {};
  static final busy = ValueNotifier<Set<String>>(const {});

  static String userPrompt(RitmAiKind kind, Map<String, dynamic> snapshot) =>
      '${ritmAiTask(kind)}\nСнимок (JSON):\n${jsonEncode(snapshot)}';

  static RitmAiError classify(Object e) {
    if (e is RitmAiError) return e;
    if (e is CoachException) {
      final s = e.status;
      if (s == 401 || s == 403) return RitmAiError('key', e.message);
      if (s == 429) return RitmAiError('limit', e.message);
      return RitmAiError('error', e.message);
    }
    if (e is TimeoutException || e is SocketException || e is HttpException) {
      return RitmAiError('offline', '$e');
    }
    final t = '$e';
    if (t.contains('ClientException') || t.contains('Failed host lookup') || t.contains('SocketException')) {
      return RitmAiError('offline', t);
    }
    return RitmAiError('error', t);
  }

  /// Запустить сценарий: снимок → модель → проверка → кэш и журнал.
  /// [auto] — автоматический запуск («Утро» после закрытия ночи): уважает
  /// блокировку после 401/429 (не чаще раза в час).
  static Future<RitmAiResult> run(
    RitmAiKind kind,
    String key,
    Map<String, dynamic> snapshot, {
    CoachConfig? config,
    bool auto = false,
    DateTime? now,
  }) async {
    await RitmAiLog.load();
    await RitmAiCache.load();
    final t = debugTransport ?? (config == null ? null : ritmAiOpenAiTransport(config));
    if (t == null || (debugTransport == null && !(config?.configured ?? false))) {
      throw const RitmAiError('nokey', 'нет ключа');
    }
    if (auto && RitmAiPrefs.blocked(now ?? clock())) {
      throw RitmAiError(RitmAiPrefs.blockWhy.isEmpty ? 'limit' : RitmAiPrefs.blockWhy, 'пауза после ошибки');
    }
    final id = '${kind.name}:$key';
    final running = _inflight[id];
    if (running != null) return running;
    final f = _run(kind, key, snapshot, t, config, now ?? clock());
    _inflight[id] = f;
    busy.value = {..._inflight.keys};
    try {
      return await f;
    } finally {
      _inflight.remove(id);
      busy.value = {..._inflight.keys};
    }
  }

  static Future<RitmAiResult> _run(
    RitmAiKind kind,
    String key,
    Map<String, dynamic> snapshot,
    RitmAiTransport t,
    CoachConfig? config,
    DateTime now,
  ) async {
    final sentText = jsonEncode(snapshot);
    final model = config?.model.isNotEmpty == true ? config!.model : kRitmAiDefaultModel;
    {
      ({String text, Object? usage, String model})? reply;
      Object? last;
      for (var attempt = 0; attempt < 2 && reply == null; attempt++) {
        try {
          reply = await t(system: kRitmAiSystem, user: userPrompt(kind, snapshot), kind: kind);
        } catch (e) {
          last = e;
          final c = classify(e);
          // Повтор — только при сетевой ошибке/таймауте, не при 4xx.
          if (c.code != 'offline') break;
        }
      }
      if (reply == null) {
        final c = classify(last ?? const RitmAiError('error', 'пустой ответ'));
        if (c.code == 'key' || c.code == 'limit') await RitmAiPrefs.block(c.code, now: now);
        await RitmAiLog.add(RitmAiLogEntry(
          ts: now.millisecondsSinceEpoch,
          kind: kind,
          model: model,
          ok: false,
          error: c.code,
          sent: sentText,
        ));
        throw c;
      }
      final raw = ritmAiParseJson(reply.text);
      final usage = ritmAiParseUsage(reply.usage);
      if (raw == null) {
        await RitmAiLog.add(RitmAiLogEntry(
          ts: now.millisecondsSinceEpoch,
          kind: kind,
          model: reply.model,
          usage: usage,
          ok: false,
          error: 'не JSON',
          sent: sentText,
        ));
        throw const RitmAiError('error', 'ответ не в формате JSON');
      }
      await RitmAiPrefs.unblock();
      final res = RitmAiResult(
        kind: kind,
        key: key,
        raw: raw,
        // Тот же объект, что ушёл в запрос (через JSON — без ссылок на живые данные).
        sent: (jsonDecode(sentText) as Map).cast<String, dynamic>(),
        model: reply.model,
        at: now.millisecondsSinceEpoch,
        usage: usage,
      );
      await RitmAiLog.add(RitmAiLogEntry(
        ts: res.at,
        kind: kind,
        model: reply.model,
        usage: usage,
        ok: true,
        sent: sentText,
        hidden: res.answer.hidden,
      ));
      if (kind != RitmAiKind.ask) await RitmAiCache.put(res);
      return res;
    }
  }
}

/// Ключ недели: дата понедельника.
String ritmWeekKey(DateTime d) => _day(DateTime(d.year, d.month, d.day - (d.weekday - 1)));

/// «16 окт».
String ritmShortDate(DateTime d) =>
    '${d.day} ${const ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'][d.month - 1]}';

/// Подписи полей снимка по-русски (для пунктов и «Что отправляется»).
const Map<String, String> kRitmAiFieldRu = {
  'recovery.pct': 'Восстановление',
  'recovery.yesterday_pct': 'Восстановление вчера',
  'sleep.score_pct': 'Сон',
  'sleep.asleep_hm': 'Спали',
  'sleep.asleep_min': 'Спали',
  'sleep.need_hm': 'Потребность',
  'sleep.need_min': 'Потребность',
  'sleep.debt_hm': 'Долг сна',
  'sleep.debt_min': 'Долг сна',
  'sleep.bedtime': 'Отбой',
  'sleep.wake': 'Подъём',
  'sleep.parts.duration_pct': 'Длительность',
  'sleep.parts.consistency_pct': 'Регулярность',
  'sleep.parts.efficiency_pct': 'Эффективность',
  'sleep.parts.stress_pct': 'Ночной стресс',
  'sleep.stages_estimate.deep_min': 'Глубокий (оценка)',
  'sleep.stages_estimate.rem_min': 'Быстрый сон (оценка)',
  'night.resting_hr_bpm': 'Пульс покоя',
  'night.hrv_ms': 'ВСР в глубоком сне',
  'night.resp_rpm': 'Дыхание',
  'night.temp_dev_c': 'Температура',
  'strain.today_so_far': 'Нагрузка сегодня',
  'strain.yesterday': 'Нагрузка вчера',
  'strain.target_lo': 'Коридор нагрузки',
  'strain.target_hi': 'Коридор нагрузки',
  'tonight.bedtime': 'Отбой сегодня',
  'tonight.need_hm': 'Потребность на ночь',
  'this_week_median.sleep_pct': 'Сон, медиана недели',
  'this_week_median.recovery_pct': 'Восстановление, медиана',
  'this_week_median.strain': 'Нагрузка, медиана',
  'this_week_median.resting_hr_bpm': 'Пульс покоя, медиана',
  'this_week_median.hrv_ms': 'ВСР, медиана',
  'this_week_median.consistency_pct': 'Регулярность, медиана',
  'this_week_median.asleep_hm': 'Спали, медиана',
};

const Map<String, String> _tailRu = {
  'strain': 'Нагрузка',
  'sleep_pct': 'Сон',
  'recovery_pct': 'Восстановление',
  'hrv_ms': 'ВСР',
  'resting_hr_bpm': 'Пульс покоя',
  'consistency_pct': 'Регулярность',
  'asleep_hm': 'Спали',
};

/// Подпись поля по-русски; для дней недели — с датой из снимка [sent].
String ritmAiFieldRu(String metric, [Map<String, dynamic>? sent]) {
  if (kRitmAiFieldRu[metric] case final s?) return s;
  final day = RegExp(r'^days\.(\d+)\.(\w+)$').firstMatch(metric);
  if (day != null) {
    final label = _tailRu[day.group(2)] ?? day.group(2)!;
    final days = sent?['days'];
    final i = int.parse(day.group(1)!);
    final d = days is List && i < days.length && days[i] is Map ? DateTime.tryParse('${days[i]['date']}') : null;
    return d == null ? label : '$label, ${ritmShortDate(d)}';
  }
  if (metric.startsWith('prev_4_weeks_median.')) return '${_tailRu[metric.split('.').last] ?? metric}, 4 недели';
  final tail = metric.split('.').last;
  for (final e in kRitmAiFieldRu.entries) {
    if (e.key.endsWith('.$tail')) return e.value;
  }
  if (RegExp(r'^recovery\.drivers_pp\.').hasMatch(metric)) {
    return 'Вклад: ${_drvRu[tail] ?? tail}';
  }
  return metric;
}
