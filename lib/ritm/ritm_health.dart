// «Ритм» — вкладка «Здоровье» (ТЗ v2 §4, сборка B1′).
//
// Порядок: «Здоровье» (h1) → Монитор здоровья (пульс покоя, ВСР, дыхание,
// температура кожи, SpO₂ — коридоры по личной истории, §10.4) → Кардиоформа
// (ВСР и пульс покоя 7 против 30 дней, VO₂max — Watch, §10.8) → Сверка
// браслет / Watch (одна строка → «Источники») → ЭКГ (MG) → Цикл (если вкл.).
// Без вкладок, без списков «Нет данных», без служебных сносок.
// B4: вкладка открывается героем «Биовозраст» (облачко §11) и карточкой
// «Темп старения» (§4.1–4.2), тап → экран 8 вкладов (§10.7).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui2/revision.dart';
import '../ui2/screens/cycle_screen.dart' show CycleTab;
import 'ritm_more.dart' show RitmPaged, RitmProfileScreen;
import '../ui2/screens/ecg.dart' show EcgHomeScreen, pairedIsMaverickOf;
import '../ui2/screens/health_screen.dart' show HealthData;
import '../ui2/screens/home_screen.dart' show denseDays, go, pointsOf, repoOf;
import '../ui2/screens/metric_detail.dart' show MetricDetail;
import '../data/day_label.dart' show dayLabelOf;
import '../data/db.dart' show LocalDb;
import 'ritm_hk.dart';
import 'ritm_watch_store.dart';
import 'ritm_calc.dart';
import 'ritm_seed.dart';
import 'ritm_scores.dart' show dec1;
import 'ritm_demo.dart'
    show
        kRitmDemo,
        ritmDemoBandEcg,
        ritmDemoBioCalib,
        ritmDemoNoBirth,
        ritmDemoHealth,
        ritmDemoNow,
        ritmDemoStep,
        ritmDemoWatch;
import 'ritm_detail.dart' show RitmMonitorScreen;
import 'ritm_bioage.dart';
import 'ritm_bio_ui.dart';
import 'ritm_sources.dart' show RitmSourcesScreen, agoRu;
import 'ritm_ui.dart';
import 'ritm_watch.dart';

/// Всё, что считает вкладка из данных (чистое, для тестов).
class RitmHealthModel {
  final List<MonRow> rows;
  final ({MonStatus status, String text}) summary;
  final String? radar;
  final CardioTrend hrv, rhr;
  final String? verdict;
  final List<double?> hrvSpark, rhrSpark, respSpark, tempSpark;
  final int days;

  /// VO₂max Apple Watch (B3): последнее значение, оценка для возраста,
  /// изменение к месяцу, ряд 90 дней.
  final double? vo2;
  final String? vo2Rating;
  final double? vo2Delta;
  final List<double?> vo2Spark;
  final bool watch;

  /// Ряды 31 день (браслет + засев) для подробного экрана.
  final Map<MonKind, List<double?>> series;
  const RitmHealthModel({
    required this.rows,
    required this.summary,
    this.radar,
    required this.hrv,
    required this.rhr,
    this.verdict,
    this.hrvSpark = const [],
    this.rhrSpark = const [],
    this.respSpark = const [],
    this.tempSpark = const [],
    this.days = 0,
    this.series = const {},
    this.vo2,
    this.vo2Rating,
    this.vo2Delta,
    this.vo2Spark = const [],
    this.watch = false,
  });

  static RitmHealthModel from(
    HealthData d, {
    bool watchSpo2 = false,
    RitmSeed? seed,
    DateTime? now,
    WatchData? watch,
    int? age,
    bool female = false,
  }) {
    List<double?> dense(String k, int n) => denseDays(d.points(k), n);
    final n0 = now ?? DateTime.now();
    final dates = [
      for (var i = 30; i >= 0; i--)
        dayLabelOf(DateTime(n0.year, n0.month, n0.day - i)),
    ];
    final sd = seed ?? const RitmSeed();
    final h31 = dense('hrv', 31);
    final bandHrv = <String, double>{
      for (var i = 0; i < 31; i++) dates[i]: ?h31[i],
    };
    // Ряд браслета + засев (WHOOP / Watch) только на даты без своей ночи;
    // последняя ночь (сегодня) — всегда браслета.
    ({List<double?> s, String src}) merged(String k, String seedKey) {
      final band = dense(k, 31);
      final hist = band.sublist(0, 30);
      final m = mergeSeed(
        hist,
        dates.sublist(0, 30),
        sd.values(seedKey, bandRmssd: bandHrv),
      );
      final used = <String>{
        for (var i = 0; i < 30; i++)
          if (hist[i] == null && m.series[i] != null) dates[i],
      };
      return (
        s: [...m.series, band.last],
        src: used.isEmpty ? '' : sd.sourceWord(seedKey, used),
      );
    }

    ({List<double> hist, double? prev, List<double> recent}) split(
      List<double?> s,
      double? last,
    ) {
      final hist = [for (final v in s.sublist(0, s.length - 1)) ?v];
      final recent = [
        ...hist.length > 6 ? hist.sublist(hist.length - 6) : hist,
        ?last,
      ];
      return (
        hist: hist,
        prev: s.length >= 2 ? s[s.length - 2] : null,
        recent: recent,
      );
    }

    final rhrM = merged('resting_hr', 'rhr'), hrvM = merged('hrv', 'hrv');
    final respM = merged('resp_rate', 'resp');
    final rhrS = rhrM.s, hrvS = hrvM.s, respS = respM.s;
    final rhrLast = d.daily('resting_hr').value?.toDouble() ?? rhrS.last;
    final hrvLast = d.hrv.value?.toDouble() ?? hrvS.last;
    final respLast = d.resp.value?.toDouble() ?? respS.last;
    final st = d.today['skin_temp'];
    final tempLast = st is Map ? (st['dev_c'] as num?)?.toDouble() : null;
    final r = split(rhrS, rhrLast), h = split(hrvS, hrvLast);
    final p = split(respS, respLast);
    final rows = [
      monitorRow(
        MonKind.rhr,
        history: r.hist,
        last: rhrLast,
        prev: r.prev,
        recent: r.recent,
        seededFrom: rhrM.src,
      ),
      monitorRow(
        MonKind.hrv,
        history: h.hist,
        last: hrvLast,
        prev: h.prev,
        seededFrom: hrvM.src,
      ),
      monitorRow(
        MonKind.resp,
        history: p.hist,
        last: respLast,
        prev: p.prev,
        seededFrom: respM.src,
      ),
      // Температура — отклонение от личной нормы Edge; ночей — как у пульса.
      monitorRow(MonKind.temp, history: r.hist, last: tempLast),
      // SpO₂ ночью — только Apple Watch (медиана 23:00–08:00, §10.4).
      monitorRow(
        MonKind.spo2,
        history: const [],
        last: watch?.spo2,
        hasSource: watchSpo2 || (watch?.any ?? false),
      ),
    ];
    final hrv30 = [for (final v in dense('hrv', 30)) ?v];
    final rhr30 = [for (final v in dense('resting_hr', 30)) ?v];
    final ch = cardioHrv(hrv30), cr = cardioRhr(rhr30);
    final vo2 = watch?.vo2;
    final vo2d = watch == null ? null : vo2DeltaMonth(watch.vo2Series);
    return RitmHealthModel(
      rows: rows,
      summary: monitorSummary(rows),
      radar: illnessRadar(rows),
      hrv: ch,
      rhr: cr,
      verdict: cardioVerdict([ch.form, cr.form, vo2Form(vo2d)]),
      vo2: vo2,
      vo2Rating: vo2 == null ? null : vo2Word(vo2, age: age, female: female),
      vo2Delta: vo2d,
      vo2Spark: [for (final x in watch?.vo2Series ?? const <HkSample>[]) x.v],
      watch: watch?.any ?? false,
      hrvSpark: dense('hrv', 30),
      rhrSpark: dense('resting_hr', 30),
      respSpark: dense('resp_rate', 30),
      tempSpark: dense('skin_temp_dev_c', 30),
      days: hrv30.length > rhr30.length ? hrv30.length : rhr30.length,
      series: {
        // Последняя точка графика — та же ночь, что число в строке.
        MonKind.rhr: [...rhrS.sublist(0, rhrS.length - 1), rhrLast],
        MonKind.hrv: [...hrvS.sublist(0, hrvS.length - 1), hrvLast],
        MonKind.resp: [...respS.sublist(0, respS.length - 1), respLast],
        MonKind.temp: [...dense('skin_temp_dev_c', 31).sublist(0, 30), tempLast],
      },
    );
  }
}

class RitmHealthScreen extends StatefulWidget {
  final HealthData? data;
  final WatchNight? watch;
  const RitmHealthScreen({super.key, this.data, this.watch});

  @override
  State<RitmHealthScreen> createState() => _RitmHealthScreenState();
}

class _RitmHealthScreenState extends State<RitmHealthScreen>
    with RevisionReload {
  HealthData? _d;
  WatchNight? _watch;
  RitmSeed _seed = RitmSeed.cached;
  bool _loading = true;

  HealthData? get _fixed => widget.data ?? ritmDemoHealth();

  @override
  bool get revisionReloads => _fixed == null;

  @override
  void dispose() {
    RitmWatchStore.data.removeListener(_onWatch);
    RitmBioStore.days.removeListener(_onWatch);
    if (kRitmDemo) {
      ritmDemoStep.removeListener(_demoStep);
      ritmDemoBioCalib.removeListener(_onCalib);
    }
    _scroll.dispose();
    _bioScroll.dispose();
    super.dispose();
  }

  final _scroll = ScrollController();
  final _ecgKey = GlobalKey();
  final _cardioKey = GlobalKey();

  void _onCalib() => unawaited(RitmBioStore.load(null, force: true));

  // Биовозраст считается из дневных рядов; кэш по входу.
  List<BioDay>? _bioDays;
  DateTime? _bioBirth;
  BioResult? _bio;
  BioResult _bioOf(BuildContext c) {
    final days = RitmBioStore.days.value;
    final bs = ritmBirthOf(c);
    if (_bio == null || !identical(days, _bioDays) || bs.birth != _bioBirth) {
      _bioDays = days;
      _bioBirth = bs.birth;
      _bio = days == null
          ? const BioResult(state: BioState.noData)
          : computeBio(days, birth: bs.birth, female: bs.female);
    }
    return _bio!;
  }

  bool _bioPushed = false;
  final _bioScroll = ScrollController();

  /// B4: 38–39 герой, 40–42 экран «Биовозраст», 43–44 калибровка,
  /// 53 Монитор здоровья подробно (вчерашний пульс покоя), 54 ЭКГ.
  void _demoStepB4(int st) {
    final c = context;
    // Лист «Какая это была тренировка?» (шаг 37, корневой навигатор) не
    // должен переживать смену вкладки.
    if (st == 38) Navigator.of(c, rootNavigator: true).popUntil((r) => r.isFirst);
    if (st != 41 && st != 42 && _bioPushed) {
      _bioPushed = false;
      Navigator.of(c).popUntil((r) => r.isFirst);
    }
    void show(GlobalKey k, [double a = 0]) {
      final ctx = k.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: a);
    }

    switch (st) {
      case 38:
      case 43:
        if (_scroll.hasClients) _scroll.jumpTo(0);
      case 39:
        show(_cardioKey, .55);
      case 40:
        _bioPushed = true;
        go(c, RitmBioScreen(r: _bioOf(c), controller: _bioScroll));
      case 41:
      case 42:
        if (_bioScroll.hasClients) {
          final max = _bioScroll.position.maxScrollExtent;
          _bioScroll.jumpTo(st == 41 ? math.min(max, 560) : max);
        }
      case 53:
        if (_scroll.hasClients) _scroll.jumpTo(0);
        _bioPushed = true;
        _openMonitor(c);
      case 44:
        _bioPushed = true;
        go(c, RitmBioScreen(r: _bioOf(c)));
      case 55:
        if (_scroll.hasClients) _scroll.jumpTo(0);
      case 54:
        // ЭКГ внизу списка — ленивый ListView её ещё не построил.
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _scrollToEcg();
        });
    }
  }

  bool _demoPushed = false;

  void _scrollToEcg() {
    final ctx = _ecgKey.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .6);
  }

  /// Демо-автопилот: шаг 25 — Монитор здоровья подробно, 26 — назад.
  void _demoStep() {
    if (!mounted) return;
    final st = ritmDemoStep.value;
    if ((st >= 38 && st <= 44) || st == 53 || st == 54 || st == 55 || (st >= 66 && st <= 68)) {
      // Калибровка — шаги 43–44, без даты рождения — 55.
      ritmDemoBioCalib.value = st == 43 || st == 44;
      if (ritmDemoNoBirth.value != (st == 55)) {
        ritmDemoNoBirth.value = st == 55;
        _bio = null;
        setState(() {});
      }
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted && ritmDemoStep.value == st) _demoStepB4(st >= 66 ? 38 : st);
      });
      return;
    }
    if (st == 29) {
      // B3: «Здоровье» внизу — Сверка и ЭКГ (браслет + Watch).
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _scrollToEcg();
      });
    } else if (st == 30 && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    if (st == 25 && !_demoPushed) {
      _demoPushed = true;
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _openMonitor(context);
      });
    } else if (st == 26 && _demoPushed) {
      _demoPushed = false;
      Navigator.of(context).pop();
    }
  }

  List<({DateTime at, String category, int? hr})> _bandEcg = const [];

  void _onWatch() {
    if (mounted) setState(() {});
  }

  Future<void> _loadEcg() async {
    final demo = ritmDemoBandEcg();
    if (demo != null) {
      setState(() => _bandEcg = demo);
      return;
    }
    try {
      final rows = await LocalDb.listEcgReadings(limit: 5);
      final l = [
        for (final r in rows)
          (
            at: DateTime.fromMillisecondsSinceEpoch(
              ((r['start_ts'] as num?) ?? 0).toInt() * 1000,
            ),
            category: '${r['category'] ?? ''}',
            hr: (r['avg_hr'] as num?)?.toInt(),
          ),
      ];
      if (mounted) setState(() => _bandEcg = l);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    RitmWatchStore.data.addListener(_onWatch);
    RitmBioStore.days.addListener(_onWatch);
    unawaited(RitmWatchStore.load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadEcg();
      unawaited(RitmBioStore.load(_fixed == null ? repoOf(context) : null));
    });
    if (kRitmDemo) {
      ritmDemoStep.addListener(_demoStep);
      ritmDemoBioCalib.addListener(_onCalib);
      final v = ritmDemoStep.value;
      if (v == 25 || v == 29 || (v >= 38 && v <= 44) || v >= 53) {
        _demoStep();
      }
    }
    if (_fixed != null) {
      _d = _fixed;
      _watch = widget.watch ?? ritmDemoWatch();
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void reload() => _load();

  Future<void> _load() async {
    if (_fixed != null) return;
    final repo = repoOf(context);
    if (repo == null) {
      setState(() => _loading = false);
      return;
    }
    final t = beginRead(#ritmHealth);
    try {
      final d = await HealthData.load(repo);
      try {
        d.charts['skin_temp_dev_c'] = pointsOf(
          await repo.getChart('skin_temp_dev_c'),
        );
      } catch (_) {}
      final seed = await RitmSeed.load();
      if (stillNewest(#ritmHealth, t)) {
        setState(() {
          _d = d;
          _seed = seed;
          _loading = false;
        });
      }
    } catch (_) {
      if (stillNewest(#ritmHealth, t)) setState(() => _loading = false);
    }
    unawaited(RitmWatchStore.load(force: true));
    unawaited(_loadEcg());
    unawaited(RitmBioStore.load(repo, force: true));
    if (RitmWatchReader.asked && RitmWatchStore.data.value == null) {
      final w = await RitmWatchReader().lastNight();
      if (mounted) setState(() => _watch = w);
    }
  }

  /// Возраст — только из даты рождения профиля (в демо — демо-дата).
  ({int? age, bool female}) _ageSex(BuildContext c) {
    final b = ritmBirthOf(c);
    return (
      age: b.birth == null
          ? null
          : ageOn(b.birth!, ritmDemoNow() ?? DateTime.now()),
      female: b.female,
    );
  }

  @override
  Widget build(BuildContext c) {
    final bottom = RS.tabBarClearance + MediaQuery.paddingOf(c).bottom;
    final d = _d;
    final hk = RitmWatchStore.data.value;
    final as = _ageSex(c);
    final m = d == null
        ? null
        : RitmHealthModel.from(
            d,
            seed: _seed,
            watch: hk,
            age: as.age,
            female: as.female,
          );
    bool cycle = false;
    try {
      cycle = context.select<AppState, bool>((a) => a.cycleTrackingEnabled);
    } catch (_) {}
    final mg =
        kRitmDemo || pairedIsMaverickOf(c) || (hk?.ecg.isNotEmpty ?? false);
    return DecoratedBox(
      decoration: RC.background,
      child: RefreshIndicator(
        onRefresh: _load,
        color: RC.ink,
        backgroundColor: RC.card,
        child: ListView(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(RS.screen, 4, RS.screen, bottom),
          children: [
            const SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Здоровье', style: RT.h1),
              ),
            ),
            const SizedBox(height: 4),
            // Герой «Биовозраст» + «Темп старения» (§4.1–4.2).
            Builder(
              builder: (c) {
                // Перестроиться, когда в профиле сменили дату рождения.
                try {
                  c.select<AppState, Object?>((a) => a.user?['birth_date']);
                } catch (_) {}
                final bio = _bioOf(c);
                void open() => go(c, RitmBioScreen(r: bio));
                return Column(
                  children: [
                    BioHero(
                      r: bio,
                      onTap: bio.state == BioState.noProfile
                          ? () => go(c, const RitmProfileScreen())
                          : open,
                    ),
                    const SizedBox(height: RS.cardGap),
                    PaceCard(r: bio, onMore: open),
                  ],
                );
              },
            ),
            const SizedBox(height: RS.cardGap),
            if (m == null)
              _loading
                  ? Container(
                      height: 320,
                      decoration: BoxDecoration(
                        color: RC.card,
                        borderRadius: BorderRadius.circular(RS.rCard),
                      ),
                    )
                  : RCard(
                      child: const Text(
                        'Не удалось прочитать данные. Потяните экран вниз, чтобы повторить.',
                        style: RT.body,
                      ),
                    )
            else ...[
              _monitor(c, m),
              const SizedBox(height: RS.cardGap),
              KeyedSubtree(key: _cardioKey, child: _cardio(c, m)),
              const SizedBox(height: RS.cardGap),
              _reconcile(c, d!),
              if (mg) ...[
                const SizedBox(height: RS.cardGap),
                KeyedSubtree(key: _ecgKey, child: _ecg(c, hk)),
              ],
              if (cycle) ...[
                const SizedBox(height: RS.cardGap),
                RCard(
                  onTap: () =>
                      go(c, const RitmPaged(title: 'Цикл', child: CycleTab())),
                  child: const RCardHead('Цикл'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  static Color _statusColor(MonStatus s) => switch (s) {
    MonStatus.ok => RC.green,
    MonStatus.warn => RC.yellow,
    MonStatus.alert => RC.red,
    _ => RC.ink3,
  };

  Widget _monitor(BuildContext c, RitmHealthModel m) {
    final sum = m.summary;
    return RCard(
      onTap: () => _openMonitor(c),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Монитор здоровья'),
          const SizedBox(height: 8),
          Row(
            children: [
              RDot(_statusColor(sum.status)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sum.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: RT.title.copyWith(fontSize: 15),
                ),
              ),
            ],
          ),
          if (m.radar != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (sum.status == MonStatus.alert ? RC.red : RC.yellow)
                    .withValues(alpha: .14),
                borderRadius: BorderRadius.circular(RS.rTile),
              ),
              child: Text(m.radar!, style: RT.body.copyWith(color: RC.ink)),
            ),
          ],
          const SizedBox(height: 6),
          for (final r in m.rows) _monRow(c, r, m),
        ],
      ),
    );
  }

  void _openMonitor(BuildContext c) =>
      go(c, RitmMonitorScreen(data: _d, seed: _seed));

  Widget _monRow(BuildContext c, MonRow r, RitmHealthModel m) {
    final grey = !r.measured;
    final key = switch (r.kind) {
      MonKind.rhr => 'resting_hr',
      MonKind.hrv => 'hrv',
      MonKind.resp => 'resp_rate',
      MonKind.temp => 'skin_temp',
      MonKind.spo2 => null,
    };
    final spark = switch (r.kind) {
      MonKind.rhr => m.rhrSpark,
      MonKind.hrv => m.hrvSpark,
      MonKind.resp => m.respSpark,
      MonKind.temp => m.tempSpark,
      _ => const <double?>[],
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: key == null ? null : () => _openMonitor(c),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name,
                      style: RT.title.copyWith(
                        fontSize: 15,
                        color: grey ? RC.ink2 : RC.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      r.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RT.small,
                    ),
                  ],
                ),
              ),
              if (spark.whereType<double>().length >= 3) ...[
                SizedBox(
                  width: 60,
                  height: 20,
                  child: CustomPaint(painter: Spark(spark)),
                ),
                const SizedBox(width: 12),
              ],
              if (r.value != null)
                Text(
                  r.value!,
                  style: RT.num.copyWith(
                    fontSize: 17,
                    color: grey ? RC.ink3 : RC.ink,
                  ),
                ),
              const SizedBox(width: 10),
              RDot(_statusColor(r.status)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardio(BuildContext c, RitmHealthModel m) {
    final calib = m.verdict == null;
    Widget tile(
      String title,
      String value,
      String sub,
      List<double?> spark, {
      bool grey = false,
      String? metric,
      String? delta,
    }) => Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: metric == null || _fixed != null
            ? null
            : () => go(c, MetricDetail(metric)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: RC.cardHi,
            borderRadius: BorderRadius.circular(RS.rTile),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.toUpperCase(),
                style: RT.micro.copyWith(color: RC.ink2),
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: RT.num.copyWith(
                    fontSize: 20,
                    color: grey ? RC.ink3 : RC.ink,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (spark.whereType<double>().length >= 3)
                SizedBox(
                  height: 18,
                  width: double.infinity,
                  child: CustomPaint(painter: Spark(spark)),
                ),
              const SizedBox(height: 4),
              Text(
                sub,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: RT.micro,
              ),
              if (delta != null) ...[
                const SizedBox(height: 2),
                // Изменение к месяцу — всегда числом, отдельной строкой (B2_judge).
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    delta,
                    maxLines: 1,
                    style: RT.micro.copyWith(color: RC.ink2),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    String v(double? x, String unit) => x == null ? '—' : '${x.round()}$unit';
    final calibText = '${m.days.clamp(0, kCardioMin)}/$kCardioMin дней';
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Кардиоформа', trailing: null),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                calib ? 'Калибровка' : m.verdict!,
                style: RT.title.copyWith(color: calib ? RC.ink2 : RC.ink),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    calib ? calibText : 'за 30 дней',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RT.small,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  'ВСР',
                  v(m.hrv.now7, ' мс'),
                  calib
                      ? 'среднее 7 дней'
                      : 'за неделю · месяц ${m.hrv.mean30!.round()}',
                  m.hrvSpark,
                  metric: 'hrv',
                  delta: calib ? null : m.hrv.delta,
                ),
                const SizedBox(width: 8),
                tile(
                  'Пульс покоя',
                  v(m.rhr.now7, ''),
                  calib
                      ? 'среднее 7 дней'
                      : 'за неделю · месяц ${m.rhr.mean30!.round()}',
                  m.rhrSpark,
                  metric: 'resting_hr',
                  delta: calib ? null : m.rhr.delta,
                ),
                const SizedBox(width: 8),
                m.vo2 == null
                    ? tile(
                        'VO₂max',
                        '—',
                        m.watch
                            ? 'Watch ещё не измерял: нужна прогулка или бег с часами'
                            : 'нет источника: нужны Apple Watch',
                        const [],
                        grey: true,
                      )
                    : tile(
                        'VO₂max',
                        dec1(m.vo2!),
                        'Watch${m.vo2Rating == null ? '' : ' · ${m.vo2Rating}'}',
                        m.vo2Spark,
                        // VO₂max показан с десятой — и дельта с десятой.
                        delta: m.vo2Delta == null ? null : deltaToMonth1(m.vo2Delta!),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reconcile(BuildContext c, HealthData d) {
    final hk = RitmWatchStore.data.value;
    final w = hk != null ? WatchNight.of(hk) : (_watch ?? const WatchNight());
    final bandRhr = d.daily('resting_hr').value;
    final bandSleep = d.sleepMin.value;
    final a = (bandRhr != null && w.rhr != null)
        ? reconcileRhr(bandRhr, w.rhr!)
        : null;
    final s = (bandSleep != null && w.sleepMin != null)
        ? reconcileSleep(bandSleep, w.sleepMin!)
        : null;
    final text =
        RitmWatchReader.asked ||
            RitmWatchStore.asked ||
            kRitmDemo ||
            widget.watch != null
        ? reconcileSummary(rhr: a, sleep: s)
        : 'Подключите Apple Watch через Здоровье';
    final all = [a, s].whereType<Agree>();
    final dot = all.isEmpty
        ? RC.ink3
        : all.any((x) => x == Agree.check)
        ? RC.red
        : all.any((x) => x == Agree.differ)
        ? RC.yellow
        : RC.green;
    return RCard(
      onTap: () => go(c, const RitmSourcesScreen()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Сверка браслет / Watch'),
          const SizedBox(height: 10),
          Row(
            children: [
              RDot(dot),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RT.body.copyWith(color: RC.ink),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ecg(BuildContext c, WatchData? hk) {
    final items = mergeEcg(band: _bandEcg, watch: hk?.ecg ?? const []);
    final now = ritmDemoNow() ?? DateTime.now();
    return RCard(
      onTap: () => go(c, const EcgHomeScreen()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('ЭКГ'),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: RC.cardHi,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  LucideIcons.heartPulse,
                  size: 18,
                  color: RC.red,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Записать ЭКГ (браслет)', style: RT.title),
                    SizedBox(height: 2),
                    Text('30 секунд, палец на корпусе браслета', style: RT.small),
                  ],
                ),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(height: 1, color: RC.line),
            for (final e in items)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    RDot(
                      e.attention
                          ? RC.yellow
                          : ecgUnclear(e.text)
                          ? RC.ink3
                          : RC.green,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.text,
                            style: RT.body.copyWith(color: RC.ink),
                          ),
                          Text(
                            '${e.source} · ${agoRu(e.at, now)}',
                            style: RT.small,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Мини-спарклайн 30 дней (`ink3`).
class Spark extends CustomPainter {
  final List<double?> v;
  Spark(this.v);

  @override
  void paint(Canvas canvas, Size s) {
    final xs = v.whereType<double>();
    if (xs.length < 2) return;
    final lo = xs.reduce((a, b) => a < b ? a : b);
    final hi = xs.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final path = Path();
    var started = false;
    for (var i = 0; i < v.length; i++) {
      final y = v[i];
      if (y == null) continue;
      final px = v.length == 1 ? 0.0 : s.width * i / (v.length - 1);
      final py = s.height - 1 - (s.height - 2) * (y - lo) / span;
      if (!started) {
        path.moveTo(px, py);
        started = true;
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = RC.ink3,
    );
  }

  @override
  bool shouldRepaint(Spark old) => old.v != v;
}
