// «Ритм» B6½ — Помощник v2: экраны (ТЗ v3 §9 «Ещё → Помощник», §10; SLEEP_AI §5.8).
//
// • Карточка «Утро» под кольцами главной (одна строка + «Подробнее»): только при
//   ключе и закрытой ночи; офлайн — кэш с датой; 401/429 — карточка в настройки.
// • «Спросить» внизу экранов Сон / Ночь / Восстановление / Нагрузка: 3 чипа +
//   свой вопрос; ответ — проверенные пункты; «Что видела модель».
// • «Итоги недели» и «Отбой» — экраны и локальные уведомления (вс 19:00, 20:30).
// • «Ещё → Помощник»: ключ, три кнопки модели с «≈ $/мес», переключатели,
//   расход по `usage`, журнал запросов 30 дней, «Что отправляется».

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../coach/coach_config.dart';
import '../notify/notification_event.dart' show NotifCategory;
import '../notify/notification_service.dart';
import '../ui2/screens/coach.dart' show CoachScreen, CoachSetup;
import '../ui2/screens/home_screen.dart' show go;
import 'ritm_ai.dart';
import 'ritm_ai_demo.dart';
import 'ritm_demo.dart' show kRitmDemo, ritmDemoNow, ritmDemoRings, demoStrainBack;
import 'ritm_scenario.dart' show kRitmScenario;
import 'ritm_rings_store.dart' show RitmRingsDay, RitmRingsStore;
import 'ritm_scores.dart' show hmm, plural;
import 'ritm_sleep.dart' show TonightPlan, planBedtime;
import 'ritm_ui.dart';

// ───────────────────────── запуск ─────────────────────────

/// Демо-состояния для скриншотов: 'offline' | 'key' (карточка «Утро»/«Спросить»).
final ritmAiDemoState = ValueNotifier<String?>(null);

/// Демо: «Спросить» сам прокручивает экран к себе (скриншоты низа экранов).
bool ritmAiDemoRevealAsk = false;

/// План «Сегодня ночью», который показывает главная (один на всё приложение:
/// «Отбой», «Спросить», уведомление 20:30 — то же время, что на главной).
TonightPlan? ritmAiHomePlan;

TonightPlan? _planFor(RitmRingsDay r, DateTime now) => ritmAiHomePlan ?? ritmTonightPlan(r, now);

/// Один раз при старте: настройки, журнал, кэш, политика чата, модель по
/// умолчанию; в демо — транспорт без сети и засеянный журнал.
Future<void> ritmAiInit(BuildContext c) async {
  CoachConfig? cfg;
  try {
    cfg = c.read<CoachConfig>();
  } catch (_) {}
  if (kRitmDemo) {
    kRitmAiMemoryOnly = true;
    RitmAi.clock = () => ritmDemoNow() ?? DateTime.now();
    RitmAi.debugTransport = ritmAiDemoTransport();
    // Чат в демо — «подключён» (экран чата без запросов; ключ-заглушка только в симуляторе).
    if (cfg != null && !cfg.configured) {
      try {
        await cfg.save(model: kRitmAiDefaultModel, apiKey: 'sk-demo-ritm');
      } catch (_) {}
    }
    RitmAiLog.debugReset(ritmAiDemoLog(ritmDemoNow() ?? DateTime.now()));
    RitmAiLog.frozen = true;
    RitmAiCache.debugReset();
  }
  await RitmAiPrefs.load();
  await RitmAiLog.load();
  await RitmAiCache.load();
  applyChatPolicy();
  // Модель по умолчанию — «Экономно» (gpt-5.4-mini), если пользователь её не задал.
  if (!kRitmDemo && cfg != null && cfg.model.isEmpty && cfg.apiBase == CoachConfig.defaultBaseUrl) {
    try {
      await cfg.save(model: kRitmAiDefaultModel);
    } catch (_) {}
  }
}

/// Есть ли помощник (ключ + модель) — в демо всегда.
bool ritmAiReady(BuildContext c, {bool listen = true}) {
  // FIX84: сценарий реального расчёта — без демо-ответов помощника.
  if (kRitmScenario) return false;
  if (kRitmDemo) return true;
  try {
    final cfg = listen ? c.watch<CoachConfig>() : c.read<CoachConfig>();
    return cfg.configured;
  } catch (_) {
    return false;
  }
}

CoachConfig? _cfg(BuildContext c) {
  try {
    return c.read<CoachConfig>();
  } catch (_) {
    return null;
  }
}

String _model(BuildContext c) {
  if (kRitmDemo) return kRitmAiDefaultModel;
  final m = _cfg(c)?.model ?? '';
  return m.isEmpty ? kRitmAiDefaultModel : m;
}

/// Кольца дня [day] (null — сегодня): демо или кэш колец.
RitmRingsDay? ritmAiRings(String? day) {
  final now = ritmDemoNow() ?? DateTime.now();
  if (kRitmDemo) return ritmDemoRings(DateTime(now.year, now.month, now.day));
  final id = day ?? _id(now);
  return RitmRingsStore.dayResult(id);
}

double? ritmAiStrainYesterday(String day) {
  if (kRitmDemo) return demoStrainBack(1);
  final d = DateTime.parse(day);
  final y = RitmRingsStore.dayResult(_id(DateTime(d.year, d.month, d.day - 1)));
  return y?.inputs.strain?.strain;
}

String _id(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _when(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${ritmShortDate(d)}, ${_hm(d)}';
}

/// Нет ли сети (connectivity_plus; в демо — по [ritmAiDemoState]).
Future<bool> ritmAiOffline() async {
  if (kRitmDemo) return ritmAiDemoState.value == 'offline';
  try {
    final r = await Connectivity().checkConnectivity();
    return r.every((x) => x == ConnectivityResult.none);
  } catch (_) {
    return false;
  }
}

// ───────────────────────── уведомления ─────────────────────────

class RitmAiSchedule {
  RitmAiSchedule._();
  static const int idWeek = NotificationService.idRitmWeek;
  static const int idBedtime = NotificationService.idRitmBedtime;

  /// Переставить «Итоги недели» (вс 19:00) и «Отбой» (сегодня 20:30, текст —
  /// по плану ночи; без плана — не ставим, чтобы не обещать чужое время).
  static Future<void> apply({TonightPlan? plan, bool aiReady = true, DateTime? now}) async {
    if (kRitmDemo) return;
    final svc = NotificationService.instance;
    try {
      if (RitmAiPrefs.weekly.value && aiReady) {
        await svc.scheduleWeekly(
          id: idWeek,
          category: NotifCategory.reminders,
          title: 'Итоги недели',
          body: 'Помощник подведёт итоги 7 дней — откройте разбор',
          weekday: DateTime.sunday,
          hour: 19,
          minute: 0,
          route: kRouteRitmWeek,
        );
      } else {
        await svc.cancel(idWeek);
      }
      final n = now ?? DateTime.now();
      final at = DateTime(n.year, n.month, n.day, 20, 30);
      if (RitmAiPrefs.bedtime.value && plan != null && at.isAfter(n)) {
        final b = planBedtime(plan);
        await svc.scheduleOnce(
          id: idBedtime,
          category: NotifCategory.reminders,
          title: 'Отбой',
          body: 'Отбой в ${_hm(b)}, чтобы закрыть ${hmm(plan.need)}',
          at: at,
          route: kRouteRitmBedtime,
        );
      } else if (!RitmAiPrefs.bedtime.value) {
        await svc.cancel(idBedtime);
      }
    } catch (_) {}
  }
}

/// Маршруты тапа по уведомлениям.
const String kRouteRitmWeek = '/ritm/week';
const String kRouteRitmBedtime = '/ritm/bedtime';

// ───────────────────────── общие кусочки ─────────────────────────

class _AiHead extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const _AiHead(this.text, {this.trailing});
  @override
  Widget build(BuildContext c) => Row(
    children: [
      const Icon(LucideIcons.sparkles, size: 16, color: RC.brandA),
      const SizedBox(width: 8),
      Expanded(child: Text(text.toUpperCase(), style: RT.cap, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ?trailing,
    ],
  );
}

class _Chip extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const _Chip(this.text, {this.onTap});
  @override
  Widget build(BuildContext c) {
    final on = onTap != null;
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      child: Opacity(
        opacity: on ? 1 : .45,
        child: Material(
        color: on ? RC.cardHi : RC.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: on ? const Color(0x00000000) : RC.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(text, style: RT.label.copyWith(color: on ? RC.ink : RC.ink3)),
          ),
        ),
      ),
      ),
    );
  }
}

/// Карточка ошибки: ключ не принят / лимит / нет сети.
class _AiErrorCard extends StatelessWidget {
  final RitmAiError e;
  const _AiErrorCard(this.e);
  @override
  Widget build(BuildContext c) => RCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AiHead(switch (e.code) {
          'key' => 'Ключ не принят',
          'limit' => 'Лимит OpenAI',
          'offline' => 'Нет сети',
          _ => 'Помощник не ответил',
        }),
        const SizedBox(height: 8),
        Text(switch (e.code) {
          'key' => 'OpenAI не принял ключ. Проверьте его — автоматически повторим не раньше чем через час.',
          'limit' => 'Исчерпан лимит запросов OpenAI. Автоматически повторим не раньше чем через час.',
          'offline' => 'Подключитесь к интернету — разбор обновится сам.',
          _ => e.message,
        }, style: RT.body),
        if (e.code == 'key' || e.code == 'limit') ...[
          const SizedBox(height: 12),
          RButton(LucideIcons.keyRound, 'Ключ и модель', onTap: () => go(c, const RitmAssistantSettings())),
        ],
      ],
    ),
  );
}

// ───────────────────────── «Утро» на главной ─────────────────────────

class RitmMorningCard extends StatefulWidget {
  final RitmRingsDay? rings;
  final TonightPlan? plan;
  const RitmMorningCard({super.key, required this.rings, this.plan});
  @override
  State<RitmMorningCard> createState() => _RitmMorningCardState();
}

class _RitmMorningCardState extends State<RitmMorningCard> {

  RitmAiResult? _res;
  RitmAiError? _err;
  bool _busy = false;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    ritmAiDemoState.addListener(_kick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _kick());
  }

  @override
  void didUpdateWidget(RitmMorningCard old) {
    super.didUpdateWidget(old);
    if (old.rings?.inputs.day != widget.rings?.inputs.day || old.rings?.recovery.value != widget.rings?.recovery.value) {
      _kick();
    }
  }

  @override
  void dispose() {
    ritmAiDemoState.removeListener(_kick);
    super.dispose();
  }

  Map<String, dynamic>? _snapshot() {
    final r = widget.rings;
    if (r == null || r.recovery.value == null) return null;
    return ritmAiSnapshot(
      r,
      plan: widget.plan,
      strainYesterday: ritmAiStrainYesterday(r.inputs.day),
      curvesAllowed: RitmAiPrefs.curves.value,
    );
  }

  Future<void> _kick({bool manual = false}) async {
    if (!mounted || _busy) return;
    final r = widget.rings;
    if (r == null || r.recovery.value == null || !ritmAiReady(context, listen: false)) return;
    final cfg = _cfg(context);
    await RitmAiCache.load();
    final day = r.inputs.day;
    final demo = kRitmDemo ? ritmAiDemoState.value : null;
    final cached = RitmAiCache.get(RitmAiKind.morning, day);
    if (cached != null && demo == null) {
      setState(() => (_res = cached, _err = null, _stale = false));
      return;
    }
    if (demo == 'key') {
      setState(() => (_res = null, _err = const RitmAiError('key', 'demo'), _stale = false));
      return;
    }
    if (demo == 'offline' || await ritmAiOffline()) {
      final last = _demoStaleOrLatest(day);
      setState(() => (_res = last, _err = last == null ? const RitmAiError('offline', '') : null, _stale = last != null));
      return;
    }
    if (!manual && !RitmAiPrefs.morningAuto.value) {
      setState(() => (_res = null, _err = null));
      return;
    }
    final snap = _snapshot();
    if (snap == null) return;
    setState(() => _busy = true);
    try {
      final res = await RitmAi.run(RitmAiKind.morning, day, snap, config: cfg, auto: !manual);
      if (mounted) setState(() => (_res = res, _err = null, _stale = false));
    } catch (e) {
      final err = RitmAi.classify(e);
      final last = RitmAiCache.latest(RitmAiKind.morning);
      if (mounted) {
        setState(() {
          _err = err.code == 'offline' && last != null ? null : err;
          _res = err.code == 'offline' ? last : null;
          _stale = err.code == 'offline' && last != null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Офлайн — последний сохранённый разбор (с его настоящей датой и временем).
  RitmAiResult? _demoStaleOrLatest(String day) {
    final last = RitmAiCache.latest(RitmAiKind.morning);
    if (!kRitmDemo || last == null) return last;
    return last;
  }

  @override
  Widget build(BuildContext c) {
    final r = widget.rings;
    if (widget.plan != null) ritmAiHomePlan = widget.plan;
    if (r == null || r.recovery.value == null || !ritmAiReady(c)) return const SizedBox.shrink();
    final e = _err;
    if (e != null) {
      return Padding(padding: const EdgeInsets.only(top: RS.cardGap), child: _AiErrorCard(e));
    }
    final res = _res;
    Widget body;
    VoidCallback? tap;
    if (res == null) {
      body = _busy
          ? const Row(
              children: [
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: RC.ink3)),
                SizedBox(width: 10),
                Expanded(child: Text('Помощник разбирает ночь…', style: RT.body)),
              ],
            )
          : Row(
              children: [
                const Expanded(child: Text('Разобрать ночь и Восстановление', style: RT.body)),
                RButton(null, 'Разобрать', height: 36, onTap: () => _kick(manual: true)),
              ],
            );
    } else {
      final a = res.answer;
      final d = DateTime.fromMillisecondsSinceEpoch(res.at);
      tap = () => go(c, RitmAiAnswerScreen(result: res, stale: _stale));
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.line ?? 'Разбор готов', style: RT.title.copyWith(fontSize: 16, height: 1.3), maxLines: 3, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Text(
            _stale
                ? 'Разбор от ${_when(d.millisecondsSinceEpoch)} · обновится при сети'
                : '${a.shown.length} ${plural(a.shown.length, 'причина', 'причины', 'причин')} с цифрами · Подробнее',
            style: RT.small.copyWith(color: _stale ? RC.yellow : RC.ink3),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: RS.cardGap),
      child: RCard(
        onTap: tap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AiHead('Утро', trailing: tap == null ? null : const Icon(LucideIcons.chevronRight, size: 16, color: RC.ink3)),
            const SizedBox(height: 10),
            body,
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── ответ подробно ─────────────────────────

/// Пункты ответа, действие, скрытые и «Что видела модель» (для любого сценария).
class RitmAiAnswerView extends StatelessWidget {
  final RitmAiResult result;
  final bool stale;
  final bool compact;
  const RitmAiAnswerView({super.key, required this.result, this.stale = false, this.compact = false});

  @override
  Widget build(BuildContext c) {
    final a = result.answer;
    final flat = ritmAiFlatten(result.sent);
    String chip(RitmAiReason r) {
      final v = r.value is num ? _fmt(r.value as num) : '${r.value}';
      final unit = _unit(r.metric);
      final base = r.baseline == null ? '' : ' · норма ${_fmt(r.baseline!)}$unit';
      return '${ritmAiFieldRu(r.metric, result.sent)} $v$unit$base';
    }

    final hiddenWhy = [for (final r in a.reasons) if (!r.ok) _hiddenLine(r, result.sent)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact) ...[
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AiHead(stale ? 'Разбор от ${_when(result.at)}' : _when(result.at),
                    trailing: Text(result.model, style: RT.small)),
                const SizedBox(height: 10),
                Text(a.line ?? 'Нет проверенного ответа', style: RT.title.copyWith(fontSize: 18, height: 1.3)),
                // Неделя: фокус — сразу под итогом (первый экран).
                if (result.kind == RitmAiKind.week && a.actionOk) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(LucideIcons.target, size: 16, color: RC.brandA),
                      const SizedBox(width: 8),
                      Expanded(child: Text(a.action, style: RT.body.copyWith(color: RC.ink))),
                    ],
                  ),
                ],
                if (stale) ...[
                  const SizedBox(height: 8),
                  Text('Нет сети — показан последний разбор, обновится при сети', style: RT.small.copyWith(color: RC.yellow)),
                ],
              ],
            ),
          ),
          const SizedBox(height: RS.cardGap),
        ] else ...[
          Text(a.line ?? 'Нет проверенного ответа', style: RT.title.copyWith(fontSize: 16, height: 1.3)),
          const SizedBox(height: 10),
        ],
        if (a.shown.isNotEmpty)
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[const RCardHead('Почему', trailing: null), const SizedBox(height: 4)],
                for (var i = 0; i < a.shown.length; i++) ...[
                  if (i > 0) const Divider(height: 1, thickness: 1, color: RC.line),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.shown[i].claim, style: RT.body.copyWith(color: RC.ink)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(LucideIcons.badgeCheck, size: 13, color: RC.green),
                            const SizedBox(width: 6),
                            Expanded(child: Text(chip(a.shown[i]), style: RT.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (a.actionOk && (compact || result.kind != RitmAiKind.week)) ...[
          const SizedBox(height: RS.cardGap),
          RCard(
            color: RC.cardHi,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RCardHead(result.kind == RitmAiKind.week ? 'Фокус недели' : 'На сегодня', trailing: null),
                const SizedBox(height: 8),
                Text(a.action, style: RT.body.copyWith(color: RC.ink)),
              ],
            ),
          ),
        ],
        if (a.hidden > 0) ...[
          const SizedBox(height: RS.cardGap),
          RCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(LucideIcons.shieldAlert, size: 16, color: RC.yellow),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Скрыт ${a.hidden} ${plural(a.hidden, 'пункт', 'пункта', 'пунктов')}: '
                    '${hiddenWhy.toSet().join('; ')}. Приложение показывает только то, '
                    'что совпало с отправленными данными.',
                    style: RT.small.copyWith(color: RC.ink2),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: RS.cardGap),
        RGroup(
          rows: [
            RRow(
              icon: LucideIcons.fileJson,
              title: 'Что видела модель',
              sub: '${flat.length} ${plural(flat.length, 'поле', 'поля', 'полей')} · только агрегаты',
              onTap: () => go(c, RitmAiSentScreen(result: result)),
            ),
            if (!compact)
              RRow(
                icon: LucideIcons.messageCircle,
                title: 'Спросить дальше',
                sub: 'Чат с помощником',
                onTap: () => go(c, CoachScreen(initialMessage: a.line == null ? null : 'Расскажи подробнее: ${a.line}')),
              ),
          ],
        ),
        if (!compact) ...[
          const SizedBox(height: 10),
          const Text('Не диагноз и не лечение. Стадии сна — оценка.', style: RT.small, textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

/// Строка скрытого пункта: «Глубокий сон (оценка): у модели 130, в данных 92».
String _hiddenLine(RitmAiReason r, Map<String, dynamic> sent) {
  final why = _whyRu(r.why ?? '');
  if ((r.why ?? '').startsWith('value') || (r.why ?? '').startsWith('чужая норма')) {
    return '${ritmAiFieldRu(r.metric, sent)}: $why';
  }
  return why;
}

String _num(String v) => num.tryParse(v) == null ? v : v.replaceAll('.', ',');

String _whyRu(String why) {
  if (why.startsWith('чужая цифра')) return 'цифры «${why.substring(12)}» нет в данных';
  if (why.startsWith('value')) {
    final m = RegExp(r'^value (.+) ≠ (.+)$').firstMatch(why);
    return m == null ? 'число не совпало с данными' : 'у модели ${_num(m.group(1)!)}, в данных ${_num(m.group(2)!)}';
  }
  if (why.startsWith('нет поля')) return 'такого показателя нет в данных';
  if (why.startsWith('чужая норма')) return 'норма не совпала с данными';
  if (why == 'нет числа') return 'пункт без числа';
  return why;
}

String _fmt(num v) {
  final s = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
  return s.replaceAll('.', ',');
}

String _unit(String metric) {
  if (metric.endsWith('_pct')) return ' %';
  if (metric.endsWith('_ms')) return ' мс';
  if (metric.endsWith('_bpm')) return ' уд/мин';
  if (metric.endsWith('_min')) return ' мин';
  if (metric.endsWith('_c')) return ' °C';
  return '';
}

class RitmAiAnswerScreen extends StatelessWidget {
  final RitmAiResult result;
  final bool stale;
  final double demoScroll;
  const RitmAiAnswerScreen({super.key, required this.result, this.stale = false, this.demoScroll = 0});
  @override
  Widget build(BuildContext c) {
    final ctl = ScrollController();
    if (demoScroll > 0) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (ctl.hasClients) ctl.jumpTo(ctl.position.maxScrollExtent * demoScroll);
      });
    }
    return RPage(
      title: ritmAiKindRu(result.kind),
      large: true,
      controller: ctl,
      children: [RitmAiAnswerView(result: result, stale: stale)],
    );
  }
}

// ───────────────────────── «Что видела модель» ─────────────────────────

class RitmAiSentScreen extends StatelessWidget {
  final RitmAiResult? result;
  final String? json;
  final String? meta;
  const RitmAiSentScreen({super.key, this.result, this.json, this.meta});

  @override
  Widget build(BuildContext c) {
    final r = result;
    final text = r?.sentPretty ?? _pretty(json ?? '{}');
    final u = r?.usage;
    final cost = u == null ? null : ritmAiCost(r!.model, u);
    final head = meta ??
        (r == null
            ? ''
            : '${ritmAiKindRu(r.kind)} · ${_when(r.at)} · ${r.model}'
                  '${u == null ? '' : ' · ${u.input + u.output} токенов'}${cost == null ? '' : ' · ${ritmUsd(cost)}'}');
    return RPage(
      title: 'Что видела модель',
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (head.isNotEmpty) ...[Text(head, style: RT.small), const SizedBox(height: 8)],
              const Text(
                'Ровно этот JSON ушёл в OpenAI по вашему ключу, вместе с правилами ответа. '
                'Ни имени, ни даты рождения, ни координат, ни посекундных записей, ни ЭКГ.',
                style: RT.body,
              ),
            ],
          ),
        ),
        const SizedBox(height: RS.cardGap),
        RCard(
          color: const Color(0xFF15191E),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier'], fontSize: 12, height: 1.4, color: RC.ink2),
          ),
        ),
      ],
    );
  }

  static String _pretty(String s) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {
      return s;
    }
  }
}

// ───────────────────────── «Спросить» ─────────────────────────

/// Экраны, где есть «Спросить» (контекст + 3 чипа).
enum RitmAskScreenKind { sleep, night, recovery, strain }

String _screenRu(RitmAskScreenKind k) => switch (k) {
  RitmAskScreenKind.sleep => 'Сон',
  RitmAskScreenKind.night => 'Ночь',
  RitmAskScreenKind.recovery => 'Восстановление',
  RitmAskScreenKind.strain => 'Нагрузка',
};

List<String> ritmAskChips(RitmAskScreenKind k) => switch (k) {
  RitmAskScreenKind.sleep => const ['Почему такой сон?', 'Во сколько лечь сегодня?', 'Как эта ночь против обычных?'],
  RitmAskScreenKind.night => const ['Почему я просыпался?', 'Во сколько лечь сегодня?', 'Как эта ночь против обычных?'],
  RitmAskScreenKind.recovery => const ['Почему такое Восстановление?', 'Что сделать сегодня?', 'Как это утро против обычных?'],
  RitmAskScreenKind.strain => const ['Сколько ещё нагрузки сегодня?', 'Почему нагрузка такая?', 'Как этот день против обычных?'],
};

/// Карточка внизу экрана: 3 чипа + «Свой вопрос».
class RitmAskBar extends StatefulWidget {
  final RitmAskScreenKind screen;
  final String? day;
  final Map<String, Object?> facts;

  /// Демо: прокрутить экран к карточке.
  final bool demoReveal;
  const RitmAskBar({super.key, required this.screen, this.day, this.facts = const {}, this.demoReveal = false});
  @override
  State<RitmAskBar> createState() => _RitmAskBarState();
}

class _RitmAskBarState extends State<RitmAskBar> {
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    unawaited(ritmAiOffline().then((v) {
      if (mounted) setState(() => _offline = v);
    }));
    if (widget.demoReveal || (kRitmDemo && ritmAiDemoRevealAsk)) {
      for (final ms in const [900, 1800]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted) Scrollable.ensureVisible(context, alignment: .9);
        });
      }
    }
  }

  void _ask(BuildContext c, String? q) =>
      go(c, RitmAskScreen(screen: widget.screen, day: widget.day, facts: widget.facts, initial: q));

  @override
  Widget build(BuildContext c) {
    if (!ritmAiReady(c)) return const SizedBox.shrink();
    final off = _offline;
    return Padding(
      padding: const EdgeInsets.only(top: RS.cardGap),
      child: RCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AiHead('Спросить помощника', trailing: off ? Text('нет сети', style: RT.small) : null),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final q in ritmAskChips(widget.screen)) _Chip(q, onTap: off ? null : () => _ask(c, q))],
            ),
            const SizedBox(height: 12),
            RButton(LucideIcons.messageCirclePlus, 'Свой вопрос', onTap: off ? null : () => _ask(c, null)),
          ],
        ),
      ),
    );
  }
}

typedef _Qa = ({String q, RitmAiResult? res, RitmAiError? err});

class RitmAskScreen extends StatefulWidget {
  final RitmAskScreenKind screen;
  final String? day;
  final Map<String, Object?> facts;
  final String? initial;
  const RitmAskScreen({super.key, required this.screen, this.day, this.facts = const {}, this.initial});
  @override
  State<RitmAskScreen> createState() => _RitmAskScreenState();
}

class _RitmAskScreenState extends State<RitmAskScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Qa> _items = [];
  bool _busy = false;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    unawaited(ritmAiOffline().then((v) {
      if (!mounted) return;
      setState(() => _offline = v);
      if (!v && widget.initial != null) unawaited(_send(widget.initial!));
    }));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _ctx {
    final r = ritmAiRings(widget.day);
    final d = r == null ? null : DateTime.parse(r.inputs.day);
    final when = d == null
        ? ''
        : widget.screen == RitmAskScreenKind.sleep || widget.screen == RitmAskScreenKind.night
        ? ', ночь ${DateTime(d.year, d.month, d.day - 1).day}→${ritmShortDate(d)}'
        : ', ${ritmShortDate(d)}';
    return 'Экран «${_screenRu(widget.screen)}»$when';
  }

  Future<void> _send(String q) async {
    final t = q.trim();
    if (t.isEmpty || _busy) return;
    final r = ritmAiRings(widget.day);
    _input.clear();
    if (r == null) {
      setState(() => _items.add((q: t, res: null, err: const RitmAiError('error', 'нет данных этого дня'))));
      return;
    }
    final now = ritmDemoNow() ?? DateTime.now();
    final snap = ritmAiSnapshot(
      r,
      kind: RitmAiKind.ask,
      plan: _planFor(r, now),
      strainYesterday: ritmAiStrainYesterday(r.inputs.day),
      screen: widget.screen.name,
      question: t,
      curvesAllowed: RitmAiPrefs.curves.value,
    );
    if (widget.facts.isNotEmpty) snap['screen_facts'] = widget.facts;
    setState(() => _busy = true);
    final cfg = _cfg(context);
    try {
      final res = await RitmAi.run(RitmAiKind.ask, '${widget.screen.name}:${now.millisecondsSinceEpoch}', snap, config: cfg);
      if (mounted) setState(() => _items.add((q: t, res: res, err: null)));
    } catch (e) {
      if (mounted) setState(() => _items.add((q: t, res: null, err: RitmAi.classify(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  Widget build(BuildContext c) {
    final off = _offline;
    final chips = ritmAskChips(widget.screen);
    final list = ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        Text(_ctx, style: RT.small),
        if (off) ...[
          const SizedBox(height: 6),
          Text('Нет сети — вопросы недоступны, пока не появится интернет.', style: RT.small.copyWith(color: RC.yellow)),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final q in chips) _Chip(q, onTap: off || _busy ? null : () => _send(q))],
        ),
        for (final it in _items) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 300),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: RC.cardHi, borderRadius: BorderRadius.circular(16)),
              child: Text(it.q, style: RT.body.copyWith(color: RC.ink)),
            ),
          ),
          const SizedBox(height: 10),
          if (it.res != null)
            RCard(child: RitmAiAnswerView(result: it.res!, compact: true))
          else if (it.err != null)
            _AiErrorCard(it.err!),
        ],
        if (_busy) ...[
          const SizedBox(height: 16),
          const Row(
            children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: RC.ink3)),
              SizedBox(width: 10),
              Text('Помощник считает по вашим данным…', style: RT.body),
            ],
          ),
        ],
        const SizedBox(height: 16),
        RButton(
          LucideIcons.messagesSquare,
          'Продолжить в чате',
          kind: RButtonKind.ghost,
          onTap: off ? null : () => go(c, CoachScreen(initialMessage: _items.isEmpty ? null : _items.last.q)),
        ),
      ],
    );
    return RPage(
      title: 'Спросить',
      body: Column(
        children: [
          Expanded(child: list),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              decoration: const BoxDecoration(color: RC.card, border: Border(top: BorderSide(color: RC.line))),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !off,
                      maxLength: 300,
                      minLines: 1,
                      maxLines: 3,
                      style: RT.body.copyWith(color: RC.ink),
                      cursorColor: RC.brandA,
                      decoration: InputDecoration(
                        hintText: off ? 'Нет сети — вопрос не отправить' : 'Свой вопрос про этот экран',
                        hintStyle: RT.body.copyWith(color: RC.ink3),
                        border: InputBorder.none,
                        counterText: '',
                        isDense: true,
                      ),
                      onSubmitted: off ? null : _send,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Отправить',
                    onPressed: off || _busy ? null : () => _send(_input.text),
                    icon: Icon(LucideIcons.arrowUp, color: off ? RC.ink3 : RC.ink),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── «Итоги недели» и «Отбой» ─────────────────────────

/// 7 дней + 28 до них из кэша колец (в демо — синтетика в тон главной).
({List<RitmWeekDay> week, List<RitmWeekDay> prev}) ritmAiWeekDays(DateTime now) {
  if (kRitmDemo) return _demoWeek(now);
  final week = <RitmWeekDay>[], prev = <RitmWeekDay>[];
  for (var back = 34; back >= 0; back--) {
    final r = RitmRingsStore.dayResult(_id(DateTime(now.year, now.month, now.day - back)));
    if (r == null) continue;
    (back <= 6 ? week : prev).add(ritmWeekDayOf(r));
  }
  return (week: week, prev: prev);
}

({List<RitmWeekDay> week, List<RitmWeekDay> prev}) _demoWeek(DateTime now) {
  final today = ritmDemoRings(DateTime(now.year, now.month, now.day));
  const sleep = [84, 75, 60, 82, 79, 88, 81];
  const tst = [452, 372, 301, 441, 428, 476, 437];
  const cons = [81, 74, 70, 78, 80, 83, 79];
  const rhr = [51, 54, 56, 53, 52, 51, 53];
  const hrv = [52, 44, 39, 46, 47, 50, 45];
  final week = <RitmWeekDay>[
    for (var back = 6; back >= 0; back--)
      (
        day: _id(DateTime(now.year, now.month, now.day - back)),
        sleepPct: sleep[back],
        asleepMin: tst[back],
        consistencyPct: cons[back],
        recoveryPct: back == 0 ? today.recovery.value : (back == 1 ? today.prevRecovery : null),
        strain: demoStrainBack(back),
        rhr: rhr[back],
        hrv: hrv[back],
      ),
  ];
  final prev = <RitmWeekDay>[
    for (var back = 34; back >= 7; back--)
      (
        day: _id(DateTime(now.year, now.month, now.day - back)),
        sleepPct: 82 + (back * 7) % 9,
        asleepMin: 440 + (back * 13) % 50,
        consistencyPct: 80 + (back * 5) % 8,
        recoveryPct: 55 + (back * 11) % 30,
        strain: 8.0 + (back * 3) % 7,
        rhr: 52 + (back % 3),
        hrv: 43 + (back * 3) % 6,
      ),
  ];
  return (week: week, prev: prev);
}

/// Экран сценария с кэшем по ключу (неделя / вечер) и кнопкой «Обновить».
class RitmAiScenarioScreen extends StatefulWidget {
  final RitmAiKind kind;
  const RitmAiScenarioScreen({super.key, required this.kind});
  @override
  State<RitmAiScenarioScreen> createState() => _RitmAiScenarioScreenState();
}

class _RitmAiScenarioScreenState extends State<RitmAiScenarioScreen> {
  RitmAiResult? _res;
  RitmAiError? _err;
  bool _busy = false;
  bool _stale = false;

  DateTime get _now => ritmDemoNow() ?? DateTime.now();

  String get _key => widget.kind == RitmAiKind.week ? ritmWeekKey(_now) : _id(_now);

  Map<String, dynamic>? _snapshot() {
    if (widget.kind == RitmAiKind.week) {
      final w = ritmAiWeekDays(_now);
      if (w.week.isEmpty) return null;
      return ritmAiWeekSnapshot(w.week, w.prev);
    }
    final r = ritmAiRings(null);
    if (r == null) return null;
    return ritmAiSnapshot(
      r,
      kind: RitmAiKind.bedtime,
      plan: _planFor(r, _now),
      strainYesterday: ritmAiStrainYesterday(r.inputs.day),
      curvesAllowed: RitmAiPrefs.curves.value,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool refresh = false}) async {
    final cfg = _cfg(context);
    await RitmAiCache.load();
    final cached = RitmAiCache.get(widget.kind, _key);
    if (cached != null && !refresh) {
      setState(() => _res = cached);
      return;
    }
    if (!mounted) return;
    if (!ritmAiReady(context, listen: false)) {
      setState(() => _err = const RitmAiError('nokey', ''));
      return;
    }
    if (await ritmAiOffline()) {
      final last = RitmAiCache.latest(widget.kind);
      setState(() => (_res = last, _stale = last != null, _err = last == null ? const RitmAiError('offline', '') : null));
      return;
    }
    final snap = _snapshot();
    if (snap == null) {
      setState(() => _err = const RitmAiError('error', 'ещё нет данных — нужна хотя бы одна записанная ночь'));
      return;
    }
    if (!mounted) return;
    setState(() => (_busy = true, _err = null));
    try {
      final res = await RitmAi.run(widget.kind, _key, snap, config: cfg);
      if (mounted) setState(() => (_res = res, _stale = false));
    } catch (e) {
      if (mounted) setState(() => _err = RitmAi.classify(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final res = _res;
    return RPage(
      title: ritmAiKindRu(widget.kind),
      large: true,
      action: res == null || _busy
          ? null
          : IconButton(
              tooltip: 'Обновить',
              onPressed: () => _load(refresh: true),
              icon: const Icon(LucideIcons.refreshCw, size: 20, color: RC.ink2),
            ),
      children: [
        if (_busy)
          const RCard(
            child: Row(
              children: [
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: RC.ink3)),
                SizedBox(width: 10),
                Expanded(child: Text('Помощник считает по вашим данным…', style: RT.body)),
              ],
            ),
          )
        else if (_err != null)
          _AiErrorCard(_err!.code == 'nokey' ? const RitmAiError('key', 'Укажите ключ OpenAI') : _err!)
        else if (res != null)
          RitmAiAnswerView(result: res, stale: _stale),
        const SizedBox(height: RS.cardGap),
        Text(
          widget.kind == RitmAiKind.week
              ? 'Приходит в воскресенье в 19:00. 7 дней против медиан 4 прошлых недель.'
              : 'Уведомление в 20:30 считается на телефоне без ИИ; разбор «почему» — по кнопке.',
          style: RT.small,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ───────────────────────── «Ещё → Помощник» ─────────────────────────

class RitmAssistantSettings extends StatefulWidget {
  final double demoScroll;
  const RitmAssistantSettings({super.key, this.demoScroll = 0});
  @override
  State<RitmAssistantSettings> createState() => _RitmAssistantSettingsState();
}

class _RitmAssistantSettingsState extends State<RitmAssistantSettings> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(RitmAiPrefs.load().then((_) => RitmAiLog.load()).then((_) {
      if (mounted) setState(() {});
    }));
    if (widget.demoScroll > 0) {
      for (final ms in const [900, 1800]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent * widget.demoScroll);
        });
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pick(RitmAiPreset p) async {
    if (p.model == null) {
      go(context, const CoachSetup());
      return;
    }
    final cfg = _cfg(context);
    if (cfg == null || kRitmDemo) return;
    try {
      await cfg.save(model: p.model);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Widget _switch(ValueNotifier<bool> n, IconData icon, String title, String sub) => ValueListenableBuilder<bool>(
    valueListenable: n,
    builder: (c, v, _) => RRow(
      icon: icon,
      title: title,
      sub: sub,
      trailing: RSwitch(
        value: v,
        onChanged: (x) async {
          final ready = ritmAiReady(context, listen: false);
          await RitmAiPrefs.set(n, x);
          if (n == RitmAiPrefs.weekly || n == RitmAiPrefs.bedtime) {
            final r = ritmAiRings(null);
            final now = DateTime.now();
            unawaited(RitmAiSchedule.apply(plan: r == null ? null : _planFor(r, now), aiReady: ready));
          }
          if (mounted) setState(() {});
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext c) {
    var ready = kRitmDemo;
    var model = _model(c);
    var base = 'OpenAI';
    if (!kRitmDemo) {
      try {
        final cfg = c.watch<CoachConfig>();
        ready = cfg.configured;
        model = cfg.model.isEmpty ? kRitmAiDefaultModel : cfg.model;
        base = cfg.apiBase == CoachConfig.defaultBaseUrl ? 'OpenAI' : Uri.tryParse(cfg.apiBase)?.host ?? cfg.apiBase;
      } catch (_) {}
    }
    final preset = ritmAiPresetOf(model);
    final now = ritmDemoNow() ?? DateTime.now();
    final week = RitmAiLog.spent(DateTime(now.year, now.month, now.day - 6));
    final month = RitmAiLog.spent(DateTime(now.year, now.month));
    final log = RitmAiLog.entries.value;
    return RPage(
      title: 'Помощник',
      controller: _scroll,
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  RitmMark(size: 28),
                  SizedBox(width: 10),
                  Text('Помощник Ритма', style: RT.title),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                ready
                    ? 'Подключён · $base · $model. Разбирает утро, отвечает на вопросы с экранов, подводит итоги недели. Каждый пункт — с цифрой из ваших данных; непроверенное не показывается.'
                    : 'Укажите свой ключ OpenAI — помощник будет разбирать утро и отвечать по вашим данным. Ключ хранится в связке ключей телефона, на сервер «Ритма» не уходит.',
                style: RT.body,
              ),
              const SizedBox(height: 14),
              if (ready) ...[
                RButton(LucideIcons.messageCircle, 'Открыть чат', kind: RButtonKind.primary, onTap: () => go(c, const CoachScreen())),
                const SizedBox(height: 8),
              ],
              RButton(LucideIcons.keyRound, ready ? 'Ключ и адрес' : 'Указать ключ', onTap: () => go(c, const CoachSetup())),
            ],
          ),
        ),
        const SizedBox(height: RS.sectionGap),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('МОДЕЛЬ', style: RT.cap.copyWith(color: RC.ink2)),
        ),
        Row(
          children: [
            for (var i = 0; i < kRitmAiPresets.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _presetTile(kRitmAiPresets[i], kRitmAiPresets[i].id == preset, model)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('≈ \$/мес — «Утро» каждый день и 3 вопроса в день, цены OpenAI на 15.10.2026.', style: RT.small),
        ),
        const SizedBox(height: RS.sectionGap),
        RGroup(
          title: 'Расход по ответам OpenAI',
          rows: [
            RRow(
              icon: LucideIcons.wallet,
              title: 'За 7 дней ≈ ${ritmUsd(week.usd)}',
              sub: '${week.calls} ${plural(week.calls, 'запрос', 'запроса', 'запросов')} · ${_k(week.input)} вход / ${_k(week.output)} выход${week.partial ? ' · есть модели без цены' : ''}',
              chevron: false,
            ),
            RRow(
              icon: LucideIcons.calendar,
              title: 'С начала месяца ≈ ${ritmUsd(month.usd)}',
              sub: 'Счётчик по полю usage; сверяйте с platform.openai.com → Usage',
              chevron: false,
            ),
            RRow(
              icon: LucideIcons.scrollText,
              title: 'Журнал запросов',
              sub: '${log.length} ${plural(log.length, 'запись', 'записи', 'записей')} за 30 дней · хранится на телефоне',
              onTap: () => go(c, const RitmAiLogScreen()),
            ),
          ],
        ),
        const SizedBox(height: RS.sectionGap),
        RGroup(
          title: 'Сценарии',
          rows: [
            _switch(RitmAiPrefs.morningAuto, LucideIcons.sunrise, 'Утро автоматически', 'После закрытия ночи — карточка на главной'),
            _switch(RitmAiPrefs.weekly, LucideIcons.calendarCheck, 'Итоги недели', 'Воскресенье, 19:00 — уведомление'),
            _switch(RitmAiPrefs.bedtime, LucideIcons.moon, 'Отбой', '20:30 — «Отбой в …, чтобы закрыть …»'),
            RRow(
              icon: LucideIcons.listChecks,
              title: 'Открыть итоги недели',
              onTap: () => go(c, const RitmAiScenarioScreen(kind: RitmAiKind.week)),
            ),
            RRow(
              icon: LucideIcons.bedDouble,
              title: 'Открыть «Отбой»',
              onTap: () => go(c, const RitmAiScenarioScreen(kind: RitmAiKind.bedtime)),
            ),
          ],
        ),
        const SizedBox(height: RS.sectionGap),
        RGroup(
          title: 'Доступ к данным',
          rows: [
            _switch(RitmAiPrefs.curves, LucideIcons.activity, 'Кривые ночи для чата', 'Пульс и ВСР по минутам, гипнограмма. По умолчанию выкл.'),
            _switch(RitmAiPrefs.ecg, LucideIcons.heartPulse, 'ЭКГ для чата', 'Итоги записей и сама запись. По умолчанию выкл.'),
            RRow(
              icon: LucideIcons.fileJson,
              title: 'Что отправляется',
              sub: 'Только агрегаты — список полей',
              onTap: () => go(c, const RitmAiWhatSentScreen()),
            ),
            RRow(
              icon: LucideIcons.trash2,
              iconColor: RC.red,
              title: 'Очистить журнал и разборы',
              sub: 'Историю чата очищает кнопка в самом чате',
              onTap: () => _confirmClear(c),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'Данные уходят в OpenAI по вашему ключу; по умолчанию OpenAI не обучается на данных API (openai.com/enterprise-privacy). Не диагноз и не лечение.',
          style: RT.small,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _presetTile(RitmAiPreset p, bool on, String model) => Semantics(
    button: true,
    selected: on,
    label: '${p.title}, ${p.month}',
    excludeSemantics: true,
    child: Material(
      color: on ? RC.cardHi : RC.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RS.rTile),
        side: BorderSide(color: on ? RC.brandA : RC.line, width: on ? 1.5 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(RS.rTile),
        onTap: () => _pick(p),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.title, style: RT.title.copyWith(fontSize: 15)),
              const SizedBox(height: 4),
              Text(p.model ?? (on ? model : 'любая модель'), style: RT.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(p.month, style: RT.small.copyWith(color: on ? RC.ink : RC.ink3)),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _confirmClear(BuildContext c) async {
    final ok = await showRSheet<bool>(
      c,
      (sc) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Очистить журнал и разборы?', style: RT.title),
          const SizedBox(height: 8),
          const Text('Удалятся журнал запросов и сохранённые «Утро», «Итоги недели», «Отбой». Расход за прошлые дни обнулится.', style: RT.body),
          const SizedBox(height: 16),
          RButton(LucideIcons.trash2, 'Очистить', kind: RButtonKind.primary, onTap: () => Navigator.of(sc).pop(true)),
          const SizedBox(height: 8),
          RButton(null, 'Отмена', kind: RButtonKind.ghost, onTap: () => Navigator.of(sc).pop(false)),
        ],
      ),
    );
    if (ok != true) return;
    await RitmAiLog.clear();
    await RitmAiCache.clear();
    if (mounted) setState(() {});
  }
}

String _k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1).replaceAll('.', ',')} тыс.' : '$n';

/// «Что отправляется» — список полей снимка и чего нет.
class RitmAiWhatSentScreen extends StatelessWidget {
  const RitmAiWhatSentScreen({super.key});
  @override
  Widget build(BuildContext c) {
    Widget rows(List<(String, String)> xs) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final x in xs)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 132, child: Text(x.$1, style: RT.label)),
                Expanded(child: Text(x.$2, style: RT.small.copyWith(color: RC.ink2))),
              ],
            ),
          ),
      ],
    );
    return RPage(
      title: 'Что отправляется',
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Утро, Спросить, Отбой', trailing: null),
              const SizedBox(height: 8),
              rows(const [
                ('Восстановление', '%, зона словом, вчера, вклад факторов, ночей в норме'),
                ('Сон', 'оценка и 4 части, спали / потребность / долг, отбой и подъём'),
                ('Стадии', 'глубокий, быстрый, лёгкий — с пометкой «оценка» и уверенностью'),
                ('Ночь', 'пульс покоя, ВСР, дыхание, отклонение температуры'),
                ('Нормы', 'средние за 30 ночей'),
                ('Нагрузка', 'сегодня, вчера, коридор на день'),
                ('Сегодня ночью', 'потребность, отбой, подъём'),
                ('Экран', 'какой экран и ваш вопрос'),
              ]),
            ],
          ),
        ),
        const SizedBox(height: RS.cardGap),
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Итоги недели', trailing: null),
              const SizedBox(height: 8),
              rows(const [
                ('7 дней', 'сон %, спали, регулярность, Восстановление, Нагрузка, пульс покоя, ВСР'),
                ('4 недели до', 'медианы тех же показателей'),
              ]),
            ],
          ),
        ),
        const SizedBox(height: RS.cardGap),
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Не отправляется никогда', trailing: null),
              const SizedBox(height: 8),
              rows(const [
                ('Кто вы', 'имя, фото, дата рождения, рост, вес'),
                ('Где вы', 'координаты и маршруты'),
                ('Сырые данные', 'посекундный пульс, интервалы RR, акселерометр'),
                ('ЭКГ', 'только если включить «ЭКГ для чата»'),
                ('Кривые ночи', 'только в чат и только если включить переключатель'),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text('Перед каждым разбором можно открыть «Что видела модель» — там ровно отправленный JSON.', style: RT.small, textAlign: TextAlign.center),
      ],
    );
  }
}

/// Журнал запросов (30 дней, на телефоне).
class RitmAiLogScreen extends StatelessWidget {
  const RitmAiLogScreen({super.key});
  @override
  Widget build(BuildContext c) {
    final xs = [...RitmAiLog.entries.value]..sort((a, b) => b.ts.compareTo(a.ts));
    final groups = <String, List<RitmAiLogEntry>>{};
    for (final e in xs) {
      groups.putIfAbsent(ritmShortDate(DateTime.fromMillisecondsSinceEpoch(e.ts)), () => []).add(e);
    }
    return RPage(
      title: 'Журнал запросов',
      children: [
        if (xs.isEmpty) const RCard(child: Text('Запросов пока не было.', style: RT.body)),
        for (final g in groups.entries) ...[
          RGroup(
            title: g.key,
            rows: [
              for (final e in g.value)
                RRow(
                  icon: e.ok ? LucideIcons.check : LucideIcons.x,
                  iconColor: e.ok ? RC.green : RC.red,
                  title: '${_hm(DateTime.fromMillisecondsSinceEpoch(e.ts))} · ${ritmAiKindRu(e.kind)}',
                  sub: [
                    e.model,
                    if (e.usage != null) '${_k(e.usage!.input)} / ${_k(e.usage!.output)} ток.',
                    if (e.usd != null) ritmUsd(e.usd!),
                    if (!e.ok) switch (e.error) {
                      'offline' => 'нет сети',
                      'key' => 'ключ не принят',
                      'limit' => 'лимит',
                      _ => 'ошибка',
                    },
                    if (e.hidden > 0) 'скрыто ${e.hidden}',
                  ].join(' · '),
                  onTap: e.sent == null || e.sent == '{}'
                      ? null
                      : () => go(c, RitmAiSentScreen(json: e.sent, meta: '${ritmAiKindRu(e.kind)} · ${_when(e.ts)} · ${e.model}')),
                ),
            ],
          ),
          const SizedBox(height: RS.cardGap),
        ],
        const Text('Хранится 30 дней только на телефоне.', style: RT.small, textAlign: TextAlign.center),
      ],
    );
  }
}
