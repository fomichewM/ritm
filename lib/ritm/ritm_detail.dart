// «Ритм» — экраны показателей (ТЗ v2 §3, §5, §4.3, сборка B2):
// Сон · Восстановление · Нагрузка (герой-кольцо Ø140/7 + карточки),
// Монитор стресса (число, график дня, «Подышать» с ВСР до/после),
// Монитор здоровья подробно (графики 30 дней с коридорами).
// Данные — те же, что у Edge (`getDaySleepV2`, `getDayStrain`, `getInsights`,
// `metric_series`), всё в токенах RC. Демо — только DEBUG (ritm_demo.dart).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../data/day_label.dart' show todayLabel;
import '../state/app_state.dart';
import '../ui2/screens/calm_breathing.dart' show CalmBreathing;
import '../ui2/screens/health_screen.dart' show HealthData;
import '../ui2/screens/home_screen.dart'
    show envValue, go, pointsOf, repoOf;
import '../ui2/screens/metric_detail.dart' show MetricDetail;
import 'ritm_calc.dart';
import 'ritm_charts.dart';
import 'ritm_demo.dart' as demo;
import 'ritm_health.dart' show RitmHealthModel;
import 'ritm_rings.dart' show kRingTheta;
import 'ritm_rings_store.dart' show RitmRingsDay;
import 'ritm_scores.dart';
import 'ritm_night.dart';
import 'ritm_seed.dart';
import 'ritm_sleep.dart';
import 'ritm_stress.dart';
import 'ritm_ui.dart';
import 'ritm_watch.dart';
import 'ritm_watch_store.dart' show RitmWatchStore;

// ───────────────────────── общее ─────────────────────────

const _months = [
  'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
  'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
];
const _wdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

/// «Вт, 14 окт» (§1.6).
String ruDate(DateTime d) => '${_wdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

String hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

DateTime _dayOf(String? id, DateTime now) =>
    (id == null ? null : DateTime.tryParse(id)) ??
    DateTime(now.year, now.month, now.day);

/// Шапка экрана показателя: дата + герой-кольцо Ø140/7 + строка под ним.
class _Hero extends StatelessWidget {
  final String date;
  final GaugeState g;
  final String label;
  final String? sub;
  const _Hero({required this.date, required this.g, required this.label, this.sub});
  @override
  Widget build(BuildContext c) => Column(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Text(date, style: RT.label.copyWith(color: RC.ink2)),
      ),
      const SizedBox(height: 16),
      Center(child: RitmGauge(s: g, label: label, size: 140, stroke: 7)),
      if (sub != null) ...[
        const SizedBox(height: 8),
        Text(sub!, textAlign: TextAlign.center, style: RT.body.copyWith(color: RC.ink2)),
      ],
      const SizedBox(height: RS.sectionGap),
    ],
  );
}

Widget _kv(String k, String v, {Color? dot, String? note}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 7),
  child: Row(
    children: [
      if (dot != null) ...[RDot(dot), const SizedBox(width: 10)],
      Expanded(child: Text(k, style: RT.body.copyWith(color: RC.ink))),
      if (note != null) ...[
        Text(note, style: RT.small),
        const SizedBox(width: 10),
      ],
      Text(v, style: RT.num.copyWith(fontSize: 17)),
    ],
  ),
);

Widget _loadingCard() => Container(
  height: 160,
  decoration: BoxDecoration(
    color: RC.card,
    borderRadius: BorderRadius.circular(RS.rCard),
  ),
);

// ───────────────────────── Сон ─────────────────────────

class RitmSleepView {
  final int? tst, need, awake, light, deep, rem, inBed;
  final int? effPct, wakes, latency;
  final int? debt, strainAdd, napCredit;
  final int? watchMin;

  /// B4¾: окно сна, короткие пробуждения, оценка v2, план «Сегодня ночью».
  final DateTime? onset, wake;
  final int? wakesShort;
  final SleepScore? score;
  final String stagesConf;

  /// Потребность на ближайшую ночь и подъём (по умолчанию — как сегодня).
  final int? tonightNeed;
  final DateTime? tonightWake;
  const RitmSleepView({
    this.tst,
    this.need,
    this.awake,
    this.light,
    this.deep,
    this.rem,
    this.inBed,
    this.effPct,
    this.wakes,
    this.latency,
    this.debt,
    this.strainAdd,
    this.napCredit,
    this.watchMin,
    this.onset,
    this.wake,
    this.wakesShort,
    this.score,
    this.stagesConf = 'low',
    this.tonightNeed,
    this.tonightWake,
  });

  RitmSleepView withScore(SleepScore? sc, [NeedResult? nd]) => sc == null && nd == null
      ? this
      : RitmSleepView(
          tst: tst,
          need: nd?.need.round() ?? need,
          awake: awake,
          light: light,
          deep: deep,
          rem: rem,
          inBed: inBed,
          effPct: effPct,
          wakes: wakes,
          latency: latency,
          debt: nd?.debt.round() ?? debt,
          strainAdd: nd?.strainAdd.round() ?? strainAdd,
          napCredit: nd?.napCredit.round() ?? napCredit,
          watchMin: watchMin,
          onset: onset,
          wake: wake,
          wakesShort: wakesShort,
          score: sc ?? score,
          stagesConf: stagesConf,
          tonightNeed: tonightNeed,
          tonightWake: tonightWake,
        );

  /// База = потребность − долг − надбавка за нагрузку + кредит дневного сна.
  int? get base => need == null
      ? null
      : need! - (debt ?? 0) - (strainAdd ?? 0) + (napCredit ?? 0);

  static int? _i(Object? v) => v is num ? v.round() : null;

  static RitmSleepView of(
    Map<String, dynamic> v2,
    Map<String, dynamic> insights, {
    int? wakes,
    int? latency,
    int? watchMin,
    int? wakesShort,
    String stagesConf = 'low',
  }) {
    final coach = insights['sleep_coach'];
    final needSec = envValue(coach is Map ? coach['need'] : null)?['need_sec'];
    final debtH = envValue(insights['sleep_debt'])?['debt_hours'];
    final eff = v2['efficiency'];
    return RitmSleepView(
      tst: _i(v2['total_asleep_min'] ?? v2['duration_min']),
      need: needSec is num ? (needSec / 60).round() : _i(v2['need_min']),
      awake: _i(v2['awake_min']),
      light: _i(v2['light_min']),
      deep: _i(v2['deep_min']),
      rem: _i(v2['rem_min']),
      inBed: _i(v2['in_bed_min']),
      effPct: eff is num ? (eff <= 1 ? eff * 100 : eff).round() : null,
      wakes: wakes,
      latency: latency,
      debt: debtH is num ? (debtH * 60).round() : null,
      strainAdd: coach is Map ? _i(coach['strain_bonus_min']) : null,
      napCredit: coach is Map ? _i(coach['nap_credit_min']) : null,
      watchMin: watchMin,
      onset: _ts(v2['onset_ts']),
      wake: _ts(v2['wake_ts']),
      wakesShort: wakesShort,
      stagesConf: stagesConf,
      tonightNeed: needSec is num ? (needSec / 60).round() : _i(v2['need_min']),
      tonightWake: _ts(v2['wake_ts'])?.add(const Duration(days: 1)),
    );
  }

  static DateTime? _ts(Object? t) => t is num ? DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000) : null;
}

/// Значение ряда `metric_series` за день [day] (или null).
Future<num?> _seriesAt(dynamic repo, String key, String day) async {
  try {
    for (final p in pointsOf(await repo.getChart(key))) {
      final d = DateTime.fromMillisecondsSinceEpoch(p.t * 1000);
      if (todayLabel(d) == day) return p.v;
    }
  } catch (_) {}
  return null;
}

class RitmSleepScreen extends StatefulWidget {
  final String? day;
  final GaugeState hero;
  final RitmSleepView? data;

  /// Оценка сна v2 дня из колец (4 составляющие).
  final SleepScore? score;

  /// План на вечер с главной (подъём, потребность на ночь) — один отбой везде.
  final TonightPlan? plan;

  /// Долг за 14 ночей (мин) и «обычно» стадий ('light', 'deep', 'rem') из колец.
  final List<double> debtHist;
  final Map<String, double> norms;

  /// Потребность/долг «Ритма» (§7.4.2) из колец.
  final NeedResult? needRes;

  /// Только демо-скриншоты: прокрутка при открытии.
  final double demoScroll;
  const RitmSleepScreen({super.key, this.day, required this.hero, this.data, this.score,
    this.needRes,
    this.plan,
    this.debtHist = const [],
    this.norms = const {},
    this.demoScroll = 0,
  });
  @override
  State<RitmSleepScreen> createState() => _RitmSleepScreenState();
}

class _RitmSleepScreenState extends State<RitmSleepScreen> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  RitmSleepView? _v;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _v = (widget.data ?? demo.ritmDemoSleepView())?.withScore(widget.score, widget.needRes);
    if (widget.demoScroll > 0) {
      for (final ms in const [900, 1800]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(math.min(widget.demoScroll, _scroll.position.maxScrollExtent));
          }
        });
      }
    }
    if (_v != null) {
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) return setState(() => _loading = false);
    final day = widget.day ?? todayLabel(DateTime.now());
    try {
      final v2 = await repo.getDaySleepV2(day);
      final ins = widget.day == null ? await repo.getInsights() : <String, dynamic>{};
      final wakesS = await _seriesAt(repo, 'awakenings', day);
      // Пробуждения ≥ 5 мин и короткие — по гипнограмме (§7.4.3).
      ({int long, int short, int awakeMin})? aw;
      var conf = 'low';
      try {
        final s = await repo.getDaySleep(day) as Map;
        final runs = stageRunsOf(s['hypnogram']);
        if (runs.isNotEmpty) aw = awakeningsOf(runs);
        final nd = RitmNightData.of(sleep: s, heart: await repo.getDayHeart(day) as Map, hrv: const {});
        conf = nd?.stagesConf ?? 'low';
      } catch (_) {}
      final wakes = aw?.long ?? wakesS;
      final sol = await _seriesAt(repo, 'sol_min', day);
      int? watch;
      if (widget.day == null && RitmWatchReader.asked) {
        watch = (await RitmWatchReader().lastNight()).sleepMin;
      }
      if (!mounted) return;
      setState(() {
        _v = RitmSleepView.of(
          v2,
          ins,
          wakes: wakes?.round(),
          latency: sol?.round(),
          watchMin: watch,
          wakesShort: aw?.short,
          stagesConf: conf,
        ).withScore(widget.score, widget.needRes);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final v = _v;
    final now = DateTime.now();
    final g = widget.hero;
    final sub = v?.tst != null && v?.need != null
        ? '${hmm(v!.tst!)} из ${hmm(v.need!)}'
        : null;
    return RPage(
      controller: _scroll,
      title: 'Сон',
      large: true,
      children: [
        _Hero(
          date: widget.day == null ? 'Сегодня, ${ruDate(now)}' : ruDate(_dayOf(widget.day, now)),
          g: g,
          label: 'Сон',
          sub: sub,
        ),
        if (v == null)
          _loading
              ? _loadingCard()
              : const RCard(child: Text('Ночь ещё не посчитана.', style: RT.body))
        else ...[
          if (v.onset != null && v.wake != null) ...[
            Center(
              child: Text(
                'Отбой ${_hm(v.onset!)} → подъём ${_hm(v.wake!)}',
                key: const Key('sleep-window'),
                style: RT.body.copyWith(color: RC.ink),
              ),
            ),
            const SizedBox(height: RS.cardGap),
          ],
          if (v.score != null) ...[_parts(v.score!), const SizedBox(height: RS.cardGap)],
          _stages(v),
          const SizedBox(height: RS.cardGap),
          RButton(
            LucideIcons.activity,
            'Разобрать ночь',
            height: 44,
            onTap: () => Navigator.of(c).push(
              MaterialPageRoute<void>(builder: (_) => RitmNightScreen(day: widget.day)),
            ),
          ),
          const SizedBox(height: RS.cardGap),
          if (_planOf(v) != null) ...[_tonight(_planOf(v)!), const SizedBox(height: RS.cardGap)],
          _need(v),
          if (_debtHist.length >= 3) ...[const SizedBox(height: RS.cardGap), _debt14(_debtHist)],
          const SizedBox(height: RS.cardGap),
          _quality(v),
          if (v.watchMin != null && v.tst != null) ...[
            const SizedBox(height: RS.cardGap),
            _watch(v),
          ],
          if (widget.data == null && !demo.kRitmDemo) ...[
            const SizedBox(height: RS.cardGap),
            RGroup(
              rows: [
                RRow(
                  icon: LucideIcons.pencil,
                  title: 'Изменить время сна',
                  sub: 'Если браслет ошибся с отбоем или подъёмом',
                  onTap: () => _editWindow(v),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  List<double> get _debtHist =>
      widget.debtHist.isNotEmpty ? widget.debtHist : (demo.kRitmDemo ? demo.ritmDemoRings(DateTime.now()).debtHist : const []);

  Map<String, double> get _norms =>
      widget.norms.isNotEmpty ? widget.norms : (demo.kRitmDemo ? demo.ritmDemoRings(DateTime.now()).norms : const {});

  /// Долг сна за 14 ночей (§7.4.2): столбики, последний — эта ночь.
  Widget _debt14(List<double> xs) {
    final mx = math.max(60.0, xs.reduce(math.max));
    return RCard(
      key: const Key('sleep-debt14'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RCardHead('Долг сна · ${xs.length} ночей', trailing: null),
          const SizedBox(height: RS.tileHead),
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < xs.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Container(
                        height: math.max(3, xs[i] / mx * 56),
                        decoration: BoxDecoration(
                          color: i == xs.length - 1
                              ? (xs[i] >= 60 ? RC.yellow : RC.sleepBlue)
                              : RC.sleepBlue.withValues(alpha: .45),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Сейчас ${hmm(xs.last.round())}. Долг копится от недосыпа к базовой потребности и тает, '
            'когда спите больше неё.',
            style: RT.small,
          ),
        ],
      ),
    );
  }

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Правка окна сна: два выбора времени → setSleepOverride (пересчёт ночи).
  Future<void> _editWindow(RitmSleepView v) async {
    final app = context.read<AppState>();
    final on0 = v.onset ?? DateTime.now().subtract(const Duration(hours: 9));
    final wk0 = v.wake ?? DateTime.now();
    final bed = await showTimePicker(
      context: context,
      helpText: 'Когда уснули',
      initialTime: TimeOfDay.fromDateTime(on0),
    );
    if (bed == null || !mounted) return;
    final up = await showTimePicker(
      context: context,
      helpText: 'Когда проснулись',
      initialTime: TimeOfDay.fromDateTime(wk0),
    );
    if (up == null || !mounted) return;
    final w = DateTime(wk0.year, wk0.month, wk0.day, up.hour, up.minute);
    var o = DateTime(wk0.year, wk0.month, wk0.day, bed.hour, bed.minute);
    if (!o.isBefore(w)) o = o.subtract(const Duration(days: 1));
    final day = widget.day ?? todayLabel(DateTime.now());
    await app.setSleepOverride(day, o, w);
    if (mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  /// Четыре составляющие оценки сна v2 (§7.4.1) — полоски с весами.
  Widget _parts(SleepScore sc) {
    final t = kSleepTheta;
    Widget bar(String name, double? v, double w, String? note) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, style: RT.body.copyWith(color: RC.ink))),
              Text(v == null ? '—' : '${v.round()}\u00a0%', style: RT.num.copyWith(fontSize: 17)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: v == null ? 0 : (v / 100).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: RC.ringTrack,
              valueColor: AlwaysStoppedAnimation(
                v == null ? RC.ink3 : (v >= 85 ? RC.sleepBlue : (v >= 70 ? RC.yellow : RC.red)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(note ?? 'вес ${(w * 100).round()}\u00a0%', style: RT.small),
        ],
      ),
    );
    return RCard(
      key: const Key('sleep-parts'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RCardHead('Из чего ${sc.pct.round()}\u00a0%', trailing: null),
          const SizedBox(height: 4),
          bar('Достаточность', sc.s, t.wS, 'сон к потребности · вес ${(t.wS * 100).round()}\u00a0%'),
          bar('Регулярность', sc.c, t.wC,
              sc.c == null ? 'нужно 3 ночи подряд' : 'отбой и подъём как в прошлые дни · вес ${(t.wC * 100).round()}\u00a0%'),
          bar('Эффективность', sc.e, t.wE, 'доля сна от времени в кровати · вес ${(t.wE * 100).round()}\u00a0%'),
          bar('Ночной стресс', sc.x, t.wX,
              sc.x == null ? 'появится с ВСР за ночь' : '100 — спокойная ночь · вес ${(t.wX * 100).round()}\u00a0%'),
        ],
      ),
    );
  }

  TonightPlan? _planOf(RitmSleepView v) =>
      widget.plan ??
      (v.tonightNeed != null && v.tonightWake != null
          ? (wake: v.tonightWake!, alarm: false, need: v.tonightNeed!, eff: v.effPct ?? 90, latency: v.latency ?? 10)
          : null);

  /// «Сегодня ночью»: когда лечь для 100 / 85 / 70 % потребности (§7.4.2).
  Widget _tonight(TonightPlan p) {
    Widget row(String name, double target, Color col) {
      final b = bedtimeFor(wake: p.wake, needMin: p.need, target: target, effPct: p.eff, latencyMin: p.latency);
      return _kv(name, _hm(b), dot: col, note: '${(target * 100).round()}\u00a0%');
    }

    return RCard(
      key: const Key('sleep-tonight'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Сегодня ночью', trailing: null),
          const SizedBox(height: 4),
          Text(
            'Потребность на ночь ${hmm(p.need)} · встать в ${_hm(p.wake)}${p.alarm ? ' (будильник)' : ''}',
            style: RT.body,
          ),
          const SizedBox(height: 4),
          row('Пик формы', 1, RC.green),
          row('Хорошо', .85, RC.yellow),
          row('Минимум', .70, RC.red),
        ],
      ),
    );
  }


  Widget _stages(RitmSleepView v) {
    final has = (v.light ?? 0) + (v.deep ?? 0) + (v.rem ?? 0) > 0;
    Widget leg(Color col, String n, int? m, [double? norm]) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RDot(col),
              const SizedBox(width: 6),
              Flexible(child: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis, style: RT.small)),
            ],
          ),
          const SizedBox(height: 4),
          Text(m == null ? '—' : hmm(m), style: RT.num.copyWith(fontSize: 17)),
          if (norm != null) Text('обычно ${hmm(norm.round())}', style: RT.micro),
        ],
      ),
    );
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RCardHead(
            'Стадии',
            trailingWidget: has ? Text(v.stagesConf == 'med' ? 'оценка' : 'оценка ±', style: RT.small) : null,
            trailing: null,
          ),
          const SizedBox(height: RS.tileHead),
          if (!has)
            const Text('Стадии за эту ночь не посчитаны.', style: RT.body)
          else ...[
            StageBar(
              awake: v.awake ?? 0,
              light: v.light ?? 0,
              deep: v.deep ?? 0,
              rem: v.rem ?? 0,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                leg(StageBar.awakeC, 'Бодрств.', v.awake),
                leg(StageBar.lightC, 'Лёгкий', v.light, _norms['light']),
                leg(StageBar.deepC, 'Глубокий', v.deep, _norms['deep']),
                leg(StageBar.remC, 'Быстрый', v.rem, _norms['rem']),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _need(RitmSleepView v) {
    final n = v.need;
    final parts = <String>[
      if (v.base != null) 'база ${hmm(v.base!)}',
      if ((v.debt ?? 0) > 0) 'долг ${hmm(v.debt!)}',
      if ((v.strainAdd ?? 0) > 0) 'нагрузка ${hmm(v.strainAdd!)}',
    ];
    final minus = (v.napCredit ?? 0) > 0 ? ' − дневной сон ${hmm(v.napCredit!)}' : '';
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Потребность', trailing: null),
          const SizedBox(height: RS.tileHead),
          Text(n == null ? '—' : hmm(n), style: RT.num),
          const SizedBox(height: 4),
          Text(
            n == null
                ? 'Ритм учится вашей потребности во сне — нужно несколько ночей.'
                : '= ${parts.join(' + ')}$minus',
            style: RT.body,
          ),
        ],
      ),
    );
  }

  Widget _quality(RitmSleepView v) => RCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const RCardHead('Качество', trailing: null),
        const SizedBox(height: 4),
        _kv('Эффективность', v.effPct == null ? '—' : '${v.effPct}%'),
        _kv(
          'Пробуждения ≥ 5 мин',
          v.wakes == null ? '—' : '${v.wakes}',
          note: v.wakesShort == null ? null : '+ ${v.wakesShort} коротких',
        ),
        _kv('Засыпание', v.latency == null ? '—' : '${v.latency} мин'),
        _kv('В кровати', v.inBed == null ? '—' : hmm(v.inBed!)),
      ],
    ),
  );

  Widget _watch(RitmSleepView v) {
    final a = reconcileSleep(v.tst!, v.watchMin!);
    final col = switch (a) {
      Agree.match => RC.green,
      Agree.differ => RC.yellow,
      Agree.check => RC.red,
    };
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Сверка с Apple Watch', trailing: null),
          const SizedBox(height: RS.tileHead),
          Row(
            children: [
              RDot(col),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Браслет ${hmm(v.tst!)} · Watch ${hmm(v.watchMin!)} · ${agreeWord(a, sleep: true)}',
                  style: RT.body.copyWith(color: RC.ink),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Восстановление ─────────────────────────

class RitmRecoveryScreen extends StatefulWidget {
  final GaugeState hero;
  final HealthData? data;

  /// B4½: кольца v3 дня (5 факторов, реальные вклады, калибровка).
  final RitmRingsDay? rings;

  /// Только демо-скриншоты: открыть прокрученным вниз.
  final bool demoScrollEnd;
  const RitmRecoveryScreen({super.key, required this.hero, this.data, this.rings, this.demoScrollEnd = false});
  @override
  State<RitmRecoveryScreen> createState() => _RitmRecoveryScreenState();
}

class _RitmRecoveryScreenState extends State<RitmRecoveryScreen> {
  HealthData? _d;
  bool _loading = true;
  final _scroll = ScrollController();

  @override
  void dispose() {
    if (demo.kRitmDemo) demo.ritmDemoStep.removeListener(_demoStep);
    _scroll.dispose();
    super.dispose();
  }

  // Демо-шаг 58: тот же экран, прокрутка к «Вклад в это утро» (без закрыть/открыть).
  void _demoStep() {
    if (demo.ritmDemoStep.value == 58 && mounted && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  @override
  void initState() {
    super.initState();
    if (demo.kRitmDemo) demo.ritmDemoStep.addListener(_demoStep);
    if (widget.demoScrollEnd) {
      // Демо: после анимации входа и загрузки (несколько попыток — высота растёт).
      for (final ms in [900, 1800, 3000]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    }
    _d = widget.data ?? demo.ritmDemoHealth();
    if (_d != null) {
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) return setState(() => _loading = false);
    try {
      final d = await HealthData.load(repo);
      if (mounted) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final d = _d;
    final g = widget.hero;
    return RPage(
      controller: _scroll,
      title: 'Восстановление',
      large: true,
      children: [
        _Hero(
          date: 'Сегодня, ${ruDate(DateTime.now())}',
          g: g,
          label: 'Восстановление',
          sub: g.calibrating
              ? 'Ритм изучает вашу норму: ${g.have} из ${g.need} ночей'
              : null,
        ),
        if (widget.rings?.recovery.value != null) ...[
          _factorsV3(widget.rings!),
          if (d != null) ...[
            const SizedBox(height: RS.cardGap),
            _hrvCorridor(d),
          ],
          const SizedBox(height: RS.cardGap),
          _howV3(widget.rings!),
        ] else ...[
          if (d == null)
            _loading ? _loadingCard() : const SizedBox.shrink()
          else ...[
            _factors(d),
            const SizedBox(height: RS.cardGap),
            _hrvCorridor(d),
          ],
          const SizedBox(height: RS.cardGap),
          _howV3(null),
        ],
      ],
    );
  }

  // B4½: 5 факторов §7.2 — значение ночи, «обычно», цвет по z.
  Widget _factorsV3(RitmRingsDay r) {
    final x = r.inputs;
    // Сон — оценка v2 (то же, что кольцо «Сон» и вход Восстановления).
    final sp = r.sleepScore?.pct ?? x.sleepPct;
    final z = {for (final d in r.recovery.drivers) d.key: d.z};
    Color col(String k) {
      final v = z[k];
      if (v == null) return RC.ink3;
      return v >= -0.5 ? RC.green : (v >= -1.5 ? RC.yellow : RC.red);
    }

    String arrow(double? v, double? m) {
      if (v == null || m == null || (v - m).abs() < m * .03) return '';
      return v > m ? ' ↑' : ' ↓';
    }

    final n = r.norms;
    final hrv = x.night.rmssdSwsLast, rhr = x.night.rhrSleepMean;
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Факторы ночи', trailing: null),
          const SizedBox(height: 4),
          _kv(
            'ВСР в глубоком сне',
            hrv == null ? '—' : '${hrv.round()} мс${arrow(hrv, n['hrv'])}',
            dot: col('hrv'),
            note: n['hrv'] == null ? null : 'обычно ${n['hrv']!.round()}${x.night.swsFound ? '' : ' · глубокий сон не найден — последние 5 мин сна'}',
          ),
          _kv(
            'Пульс покоя за сон',
            rhr == null ? '—' : '${rhr.round()}${arrow(rhr, n['rhr'])}',
            dot: col('rhr'),
            note: n['rhr'] == null ? null : 'обычно ${n['rhr']!.round()}',
          ),
          _kv(
            'Дыхание',
            x.resp == null ? '—' : dec1(x.resp!),
            dot: col('resp'),
            note: n['resp'] == null ? null : 'обычно ${dec1(n['resp']!)}',
          ),
          if (z.containsKey('temp') && x.tempDev != null)
            _kv(
              'Температура кожи',
              '${x.tempDev! >= 0 ? '+' : '−'}${dec1(x.tempDev!.abs())} °C',
              dot: col('temp'),
              note: 'к норме',
            ),
          _kv(
            'Сон',
            sp == null ? '—' : '${sp.round()}%',
            dot: sp == null ? RC.ink3 : RC.zone(sleepZone(sp)),
            note: n['sleep'] == null ? null : 'обычно ${n['sleep']!.round()}%',
          ),
        ],
      ),
    );
  }

  // «Как считается» — реальные вклады, веса, калибровка, качество ночи.
  Widget _howV3(RitmRingsDay? r) {
    const names = {
      'hrv': 'ВСР',
      'rhr': 'Пульс покоя',
      'resp': 'Дыхание',
      'sleep': 'Сон',
      'temp': 'Температура',
    };
    final th = kRingTheta;
    final rows = <Widget>[];
    if (r != null) {
      final ds = [...r.recovery.drivers]..sort((a, b) => b.points.abs().compareTo(a.points.abs()));
      for (final d in ds) {
        final p = d.points.round();
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(child: Text(names[d.key] ?? d.key, style: RT.body.copyWith(color: RC.ink))),
                Text('вес ${d.weight.toStringAsFixed(2).replaceAll('.', ',')}', style: RT.small),
                SizedBox(
                  width: 64,
                  child: Text(
                    p == 0 ? '0' : '${p > 0 ? '+' : '−'}${p.abs()}',
                    textAlign: TextAlign.right,
                    style: RT.body.copyWith(color: p > 0 ? RC.green : (p < 0 ? RC.red : RC.ink3)),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    final q = r?.inputs.night;
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Как считается', trailing: null),
          const SizedBox(height: RS.tileHead),
          const Text(
            'Ночь сравнивается с вашей нормой за 30 ночей: ВСР в глубоком сне (вес 0,45), пульс покоя за сон (0,20), '
            'дыхание (0,10), сон (0,15) и температура кожи (0,10 — когда норма устоялась). Отклонения складываются '
            'и переводятся в 0–100 %: 67 % и выше — готов, 34–66 % — умеренно, ниже — восстановитесь. '
            'Сон короче 60\u00a0% потребности — не выше 66\u00a0%.',
            style: RT.body,
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('ВКЛАД В ЭТО УТРО, ПУНКТЫ', style: RT.micro),
            ...rows,
            const SizedBox(height: 8),
            Text(
              'Ночь «как обычно» дала бы ${(100 / (1 + math.exp(-kRingTheta.recB))).round()}\u00a0%; '
              'вклады — сдвиг от неё к сегодняшним ${r!.recovery.value}\u00a0% (округлены).',
              style: RT.small,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            th.calibrated
                ? 'Формула откалибрована по вашему экспорту WHOOP за ${th.windowDays} '
                    '${plural(th.windowDays, 'день', 'дня', 'дней')} (${ruDate(DateTime.parse(th.calibratedAt))}): '
                    'на проверочной трети ошибка в среднем ${dec1(th.recMae ?? 0)} п.п., зона совпала в 80\u00a0% дней. '
                    'Сверка датчиков «Ритма» с WHOOP — после экспорта с общими днями.'
                : 'Формула ещё не откалибрована по WHOOP.',
            style: RT.small,
          ),
          if (q != null) ...[
            const SizedBox(height: 4),
            Text(
              'Качество ночи: браслет видел ${(q.observedFrac * 100).round()} % окна, '
              'пульс есть в ${(q.hrValidFrac * 100).round()} % минут.',
              style: RT.small,
            ),
          ],
        ],
      ),
    );
  }

  Widget _factors(HealthData d) {
    List<double> hist(String k) {
      final s = [for (final p in d.points(k)) p.v];
      return s.length > 30 ? s.sublist(s.length - 30) : s;
    }

    double? med(String k) => percentile(hist(k), .5);
    final hrv = d.hrv.value?.toDouble(), rhr = d.daily('resting_hr').value?.toDouble();
    final resp = d.resp.value?.toDouble();
    final st = d.today['skin_temp'];
    final temp = st is Map ? (st['dev_c'] as num?)?.toDouble() : null;
    final mh = med('hrv'), mr = med('resting_hr'), mp = med('resp_rate');
    String arrow(double? v, double? m, {bool upGood = true}) {
      if (v == null || m == null) return '';
      if ((v - m).abs() < (m * .03)) return '';
      final up = v > m;
      return up ? '↑' : '↓';
    }

    Color col(double? v, double? m, {required bool upGood, double tol = .03}) {
      if (v == null || m == null) return RC.ink3;
      final rel = (v - m) / m;
      if (rel.abs() < tol) return RC.green;
      final good = upGood ? rel > 0 : rel < 0;
      return good ? RC.green : (rel.abs() > tol * 3 ? RC.red : RC.yellow);
    }

    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Факторы ночи', trailing: null),
          const SizedBox(height: 4),
          _kv(
            'ВСР',
            hrv == null ? '—' : '${hrv.round()} мс ${arrow(hrv, mh)}',
            dot: col(hrv, mh, upGood: true, tol: .05),
            note: mh == null ? null : 'обычно ${mh.round()}',
          ),
          _kv(
            'Пульс покоя',
            rhr == null ? '—' : '${rhr.round()} ${arrow(rhr, mr)}',
            dot: col(rhr, mr, upGood: false),
            note: mr == null ? null : 'обычно ${mr.round()}',
          ),
          _kv(
            'Дыхание',
            resp == null ? '—' : dec1(resp),
            dot: col(resp, mp, upGood: false),
            note: mp == null ? null : 'обычно ${dec1(mp)}',
          ),
          _kv(
            'Температура кожи',
            temp == null ? '—' : '${temp >= 0 ? '+' : '−'}${dec1(temp.abs())} °C',
            dot: temp == null
                ? RC.ink3
                : (temp > .5 ? RC.red : (temp >= .3 ? RC.yellow : RC.green)),
          ),
        ],
      ),
    );
  }

  Widget _hrvCorridor(HealthData d) {
    final pts = d.points('hrv');
    final today = d.hrv.value?.toDouble();
    final now = DateTime.now();
    final hasToday = pts.isNotEmpty &&
        DateUtils.isSameDay(
          DateTime.fromMillisecondsSinceEpoch(pts.last.t * 1000),
          now,
        );
    // Сегодняшняя ночь — то же число, что в «Факторах ночи».
    final all = [
      for (final p in hasToday ? pts.sublist(0, pts.length - 1) : pts) p.v,
      ?today ?? (hasToday ? pts.last.v : null),
    ];
    final last30 = all.length > 30 ? all.sublist(all.length - 30) : all;
    final last7 = all.length > 7 ? all.sublist(all.length - 7) : all;
    final lo = last30.length >= kMonMin ? percentile(last30, .1) : null;
    final hi = last30.length >= kMonMin ? percentile(last30, .9) : null;
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('ВСР за всю ночь · 7 ночей', trailing: null),
          const SizedBox(height: 4),
          Text(
            lo == null
                ? 'Коридор появится после $kMonMin ночей'
                : 'Обычно за ночь ${lo.round()}–${hi!.round()} мс. В Восстановление идёт ВСР последнего '
                    'глубокого сна (строка выше) — это другой замер, его норма своя.',
            style: RT.small,
          ),
          const SizedBox(height: 10),
          CorridorChart(
            values: last7,
            lo: lo,
            hi: hi,
            height: 120,
            highIsGood: true,
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Нагрузка ─────────────────────────

class RitmStrainView {
  final List<({int t, double v})> curve;
  final List<({String name, String time, double? strain})> sessions;
  final List<int?> zones; // минуты z1..z5
  final int? kcal;
  const RitmStrainView({
    this.curve = const [],
    this.sessions = const [],
    this.zones = const [null, null, null, null, null],
    this.kcal,
  });
}

String _sessionTime(Map<String, dynamic> s) {
  final a = (s['start_ts'] as num?)?.toInt();
  final dur = (s['duration_min'] as num?)?.round();
  if (a == null) return '';
  final st = DateTime.fromMillisecondsSinceEpoch(a * 1000);
  if (dur == null) return hhmm(st);
  final en = st.add(Duration(minutes: dur));
  return '${hhmm(st)}–${hhmm(en)} · $dur мин';
}

class RitmStrainScreen extends StatefulWidget {
  final String? day;
  final GaugeState hero;
  final String? sub;
  final RitmStrainView? data;
  final String Function(String?)? sportName;
  const RitmStrainScreen({
    super.key,
    this.day,
    required this.hero,
    this.sub,
    this.data,
    this.sportName,
  });
  @override
  State<RitmStrainScreen> createState() => _RitmStrainScreenState();
}

class _RitmStrainScreenState extends State<RitmStrainScreen> {
  RitmStrainView? _v;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _v = widget.data ?? demo.ritmDemoStrainView();
    if (_v != null) {
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) return setState(() => _loading = false);
    final day = widget.day ?? todayLabel(DateTime.now());
    try {
      final m = await repo.getDayStrain(day);
      final from = _dayOf(day, DateTime.now());
      final sessions = await repo.getSessions(
        from: from.millisecondsSinceEpoch ~/ 1000,
        to: from.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
        includeDetected: false,
      );
      final curve = <({int t, double v})>[
        for (final e in (m['curve'] as List? ?? const []))
          if (e is Map && e['t'] is num && e['v'] is num)
            (t: (e['t'] as num).toInt(), v: (e['v'] as num).toDouble()),
      ];
      final z = m['zones'];
      final zones = <int?>[
        for (var i = 1; i <= 5; i++)
          z is Map ? (z['z$i'] as num?)?.round() : null,
      ];
      final kcal = m['calories_total'] ?? m['calories'];
      if (!mounted) return;
      setState(() {
        _v = RitmStrainView(
          curve: curve,
          sessions: [
            for (final s in sessions)
              (
                name: widget.sportName?.call(s['type']?.toString()) ?? 'Тренировка',
                time: _sessionTime(s),
                strain: (s['strain'] as num?)?.toDouble(),
              ),
          ],
          zones: zones,
          kcal: kcal is num ? kcal.round() : (kcal is Map ? (kcal['value'] as num?)?.round() : null),
        );
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final v = _v;
    final now = DateTime.now();
    final day = _dayOf(widget.day, now);
    final start = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch ~/ 1000;
    final end = widget.day == null
        ? (demo.ritmDemoNow() ?? now).millisecondsSinceEpoch ~/ 1000
        : start + 86400;
    return RPage(
      title: 'Нагрузка',
      large: true,
      children: [
        _Hero(
          date: widget.day == null ? 'Сегодня, ${ruDate(now)}' : ruDate(day),
          g: widget.hero,
          label: 'Нагрузка',
          sub: widget.hero.calibrating
              ? 'Изучаем вашу обычную дневную активность: ещё ${(widget.hero.need ?? 3) - (widget.hero.have ?? 0)} ${plural((widget.hero.need ?? 3) - (widget.hero.have ?? 0), 'день', 'дня', 'дней')}'
              : widget.sub,
        ),
        if (v == null)
          _loading ? _loadingCard() : const SizedBox.shrink()
        else ...[
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const RCardHead('Нагрузка за день', trailing: null),
                const SizedBox(height: RS.tileHead),
                StrainCurveChart(curve: v.curve, dayStart: start, end: end),
              ],
            ),
          ),
          const SizedBox(height: RS.cardGap),
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const RCardHead('Тренировки', trailing: null),
                const SizedBox(height: 4),
                if (v.sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('Сегодня тренировок не было.', style: RT.body),
                  ),
                for (final s in v.sessions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: s.strain == null ? RC.cardHi : RC.strain(s.strain!),
                            borderRadius: BorderRadius.circular(RS.rTile),
                          ),
                          child: Text(
                            s.strain == null ? '—' : dec1(s.strain!),
                            style: RT.title.copyWith(fontSize: 15),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.name, style: RT.title),
                              Text(s.time, style: RT.small),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: RS.cardGap),
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const RCardHead('Зоны пульса за день', trailing: null),
                const SizedBox(height: RS.tileHead),
                ZoneBars(minutes: v.zones),
              ],
            ),
          ),
          const SizedBox(height: RS.cardGap),
          RCard(
            child: _kv(
              'Калории за день',
              v.kcal == null ? '—' : thousands(v.kcal!),
              note: 'ккал ±25%',
            ),
          ),
        ],
      ],
    );
  }
}

// ───────────────────────── Монитор стресса ─────────────────────────

/// Последняя сессия дыхания с замером до/после: (до, после) мс.
({double pre, double post, DateTime at})? lastBreathPair(
  List<Map<String, dynamic>> rows,
) {
  for (final r in rows) {
    final pre = (r['pre_rmssd'] as num?)?.toDouble();
    final post = (r['post_rmssd'] as num?)?.toDouble();
    final at = (r['started_at'] as num?)?.toInt();
    if (pre != null && post != null && at != null) {
      // started_at хранится в секундах или миллисекундах — различаем по величине.
      final ms = at > 100000000000 ? at : at * 1000;
      return (pre: pre, post: post, at: DateTime.fromMillisecondsSinceEpoch(ms));
    }
  }
  return null;
}

class RitmStressScreen extends StatefulWidget {
  final StressDay? data;
  final ({double pre, double post, DateTime at})? breath;
  const RitmStressScreen({super.key, this.data, this.breath});
  @override
  State<RitmStressScreen> createState() => _RitmStressScreenState();
}

class _RitmStressScreenState extends State<RitmStressScreen> {
  StressDay? _d;
  ({double pre, double post, DateTime at})? _breath;
  bool _loading = true;
  bool get _fixed => widget.data != null || demo.kRitmDemo;

  @override
  void initState() {
    super.initState();
    _d = widget.data ?? demo.ritmDemoStress();
    _breath = widget.breath ?? demo.ritmDemoBreath();
    if (_fixed) {
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) return setState(() => _loading = false);
    AppState? app;
    try {
      app = context.read<AppState>();
    } catch (_) {}
    try {
      final now = DateTime.now();
      final d = await loadStressDay(repo, now, now);
      ({double pre, double post, DateTime at})? b;
      try {
        if (app != null) {
          b = lastBreathPair(await app.breathingHistory(limit: 10));
        }
      } catch (_) {}
      if (mounted) setState(() => (_d = d, _breath = b, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final d = _d;
    final now = demo.ritmDemoNow() ?? DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
    final l = d?.latest;
    final head = l?.s == null
        ? (d == null || d.points.isEmpty ? 'Нет данных' : 'Нет замера')
        : '${dec1(l!.s!)} · ${stressWord(stressLevel(l.s!))}';
    final upd = l == null
        ? (d != null && !d.calibrated
              ? 'калибровка ${d.calDays}/$kStressCalDays'
              : 'спокойных минут пока нет')
        : 'обновлено ${hhmm(DateTime.fromMillisecondsSinceEpoch(l.t * 1000))}';
    return RPage(
      title: 'Монитор стресса',
      large: true,
      children: [
        Text('Сегодня, ${ruDate(now)}', style: RT.label.copyWith(color: RC.ink2)),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              l?.s == null ? '—' : dec1(l!.s!),
              style: RT.display.copyWith(color: l == null ? RC.ink3 : RC.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l?.s == null ? head : stressWord(stressLevel(l!.s!)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RT.title,
                  ),
                  const SizedBox(height: 2),
                  Text(upd, style: RT.small, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: RS.cardGap),
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Стресс за день', trailing: null),
              const SizedBox(height: RS.tileHead),
              if (d == null && _loading)
                const SizedBox(height: 240)
              else
                StressDayChart(
                  day: d ?? const StressDay(),
                  dayStart: start,
                  now: now.millisecondsSinceEpoch ~/ 1000,
                  height: 240,
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _legend(RC.brandA, 'стресс'),
                  _legend(RC.sleepBlue.withValues(alpha: .5), 'сон'),
                  _legend(RC.ink3, 'тренировка'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: RS.cardGap),
        RButton(
          LucideIcons.wind,
          'Подышать 3 мин',
          kind: RButtonKind.primary,
          onTap: _fixed ? () {} : () async {
            await Navigator.of(c).push(
              MaterialPageRoute<void>(
                builder: (_) => const CalmBreathing(measure: true, minutes: 3),
              ),
            );
            if (mounted) unawaited(_load());
          },
        ),
        const SizedBox(height: RS.cardGap),
        _breathCard(),
        const SizedBox(height: RS.cardGap),
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Как считается', trailing: null),
              const SizedBox(height: RS.tileHead),
              Text(
                'Шкала 0–3 по пульсу и ВСР в спокойные минуты дня: 0–1 низкий, 1–2 средний, '
                '2–3 высокий. Окно 5 минут, шаг 1 минута; на тренировке и в движении '
                'стресс не считается, сон — отдельно («Ночной стресс» на экране «Сон»). Норма — ваши спокойные минуты за 14 дней; первые '
                '$kStressCalDays дней идёт калибровка${d == null ? '' : ' (сейчас ${d.calDays}/$kStressCalDays)'}.',
                style: RT.body,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _legend(Color c, String t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 12, height: 4, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 6),
      Text(t, style: RT.small),
    ],
  );

  Widget _breathCard() {
    final b = _breath;
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Дыхание: ВСР до и после', trailing: null),
          const SizedBox(height: RS.tileHead),
          if (b == null)
            const Text(
              'После сессии здесь появится ВСР до и после: по минуте тишины в начале и в конце, браслет на руке.',
              style: RT.body,
            )
          else ...[
            Text(
              'ВСР до ${b.pre.round()} → после ${b.post.round()} мс',
              style: RT.num.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 4),
            Text(
              '${b.post >= b.pre ? 'Пульс успокоился: ВСР выросла на ${(b.post - b.pre).round()} мс' : 'ВСР не выросла — попробуйте медленнее, 6 вдохов в минуту'} · ${hhmm(b.at)}',
              style: RT.small,
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────── Монитор здоровья подробно ─────────────────────────

class RitmMonitorScreen extends StatefulWidget {
  final HealthData? data;
  final RitmSeed? seed;
  const RitmMonitorScreen({super.key, this.data, this.seed});
  @override
  State<RitmMonitorScreen> createState() => _RitmMonitorScreenState();
}

class _RitmMonitorScreenState extends State<RitmMonitorScreen> {
  HealthData? _d;
  RitmSeed? _seed;

  @override
  void initState() {
    super.initState();
    _d = widget.data ?? demo.ritmDemoHealth();
    _seed = widget.seed ?? RitmSeed.cached;
    if (_d == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    RitmWatchStore.data.addListener(_onWatch);
    unawaited(RitmWatchStore.load());
  }

  void _onWatch() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    RitmWatchStore.data.removeListener(_onWatch);
    super.dispose();
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) return;
    try {
      final d = await HealthData.load(repo);
      try {
        d.charts['skin_temp_dev_c'] = pointsOf(await repo.getChart('skin_temp_dev_c'));
      } catch (_) {}
      final s = await RitmSeed.load();
      if (mounted) setState(() => (_d = d, _seed = s));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext c) {
    final d = _d;
    // Та же модель, что на «Здоровье»: с данными Watch (SpO₂) по каналу.
    final m = d == null
        ? null
        : RitmHealthModel.from(
            d,
            seed: _seed,
            watch: RitmWatchStore.data.value,
            now: demo.kRitmDemo ? demo.ritmDemoNow() : null,
          );
    return RPage(
      title: 'Монитор здоровья',
      large: true,
      children: [
        if (m == null)
          _loadingCard()
        else ...[
          Row(
            children: [
              RDot(_col(m.summary.status)),
              const SizedBox(width: 8),
              Expanded(child: Text(m.summary.text, style: RT.title)),
            ],
          ),
          if (m.radar != null) ...[
            const SizedBox(height: 10),
            Text(m.radar!, style: RT.body.copyWith(color: RC.ink)),
          ],
          const SizedBox(height: RS.cardGap),
          for (final r in m.rows) ...[
            _chartCard(c, r, m),
            const SizedBox(height: RS.cardGap),
          ],
          const Text(
            'Норма — ваши ночи за 30 дней (минимум 7; до 14 — предварительно). '
            'Пульс покоя: выше 90-го перцентиля — жёлтый, две ночи подряд или '
            'медленный рост — красный. ВСР: ниже 10-го перцентиля. Дыхание: выше '
            'медианы на 1,5 вд/мин. Температура: +0,3…+0,5 °C — жёлтый, выше — красный. '
            'SpO₂ ночью (Apple Watch): 95 % и выше — норма, 93–94 — жёлтый, ниже — красный.',
            style: RT.small,
          ),
        ],
      ],
    );
  }

  static Color _col(MonStatus s) => switch (s) {
    MonStatus.ok => RC.green,
    MonStatus.warn => RC.yellow,
    MonStatus.alert => RC.red,
    _ => RC.ink3,
  };

  Widget _chartCard(BuildContext c, MonRow r, RitmHealthModel m) {
    final s = m.series[r.kind] ?? const <double?>[];
    final hist = [for (final v in s.length > 1 ? s.sublist(0, s.length - 1) : const <double?>[]) ?v];
    double? lo, hi;
    if (hist.length >= kMonMin) {
      switch (r.kind) {
        case MonKind.rhr:
          hi = percentile(hist, .9);
        case MonKind.hrv:
          lo = percentile(hist, .1);
        case MonKind.resp:
          hi = percentile(hist, .5)! + 1.5;
        case MonKind.temp:
          lo = -.3;
          hi = .3;
        case MonKind.spo2:
          break;
      }
    }
    if (r.kind == MonKind.temp && s.whereType<double>().isNotEmpty) {
      lo = -.3;
      hi = .3;
    }
    final key = switch (r.kind) {
      MonKind.rhr => 'resting_hr',
      MonKind.hrv => 'hrv',
      MonKind.resp => 'resp_rate',
      _ => null,
    };
    return RCard(
      onTap: key == null || widget.data != null || demo.kRitmDemo ? null : () => go(c, MetricDetail(key)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(r.name, style: RT.title.copyWith(fontSize: 15))),
              if (r.value != null)
                Text('${r.value} ${r.unit}', style: RT.num.copyWith(fontSize: 17)),
              const SizedBox(width: 8),
              RDot(_col(r.status)),
            ],
          ),
          const SizedBox(height: 2),
          Text(r.note, style: RT.small),
          if (r.kind != MonKind.spo2) ...[
            const SizedBox(height: 10),
            CorridorChart(
              values: s,
              lo: lo,
              hi: hi,
              height: 96,
              fmt: r.kind == MonKind.resp || r.kind == MonKind.temp
                  ? (v) => dec1(v)
                  : (v) => v.round().toString(),
            ),
          ],
        ],
      ),
    );
  }
}
