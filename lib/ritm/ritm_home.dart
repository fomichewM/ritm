// «Ритм» — главный экран «Сегодня» (ТЗ v2 §2).
//
// Сверху вниз: шапка (аватар · серия · ‹ СЕГОДНЯ › · заряд) → три кольца
// Сон / Восстановление / Нагрузка (Ø84/5, без сносок) → «Пульс дня» →
// плитки «Монитор здоровья» / «Монитор стресса» → «Мой день» (активности,
// авто-найденные тренировки, «Добавить» / «Начать») → «Сегодня ночью»
// (отбой · будильник) → «Мои показатели».
//
// Данные — те же, что читает главная Edge (HomeData.load / loadForDay);
// пересчёт в шкалы «Ритма» — ritm_scores.dart.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../data/day_label.dart' show todayLabel;
import '../l10n/app_localizations.dart';
import '../models/activity_suggestion.dart';
import '../models/metric.dart' show baselineCountsFromNote;
import '../state/app_state.dart';
import '../ui2/activity/catalogue.dart' show activityByName;
import '../ui2/activity/day_strain.dart' show DayStrainDetail;
import '../ui2/activity/picker.dart' show ActivityPicker;
import '../ui2/profile/alarm.dart' show AlarmArmState, AlarmScreen;
import '../ui2/revision.dart';
import '../ui2/screens/detected_activities.dart' show DetectedActivitiesScreen;
import '../ui2/screens/home_screen.dart'
    show
        HomeData,
        alarmArmOfContext,
        deviceBatteryOf,
        go,
        heldOverNightOf,
        pointsOf,
        repoOf;
import '../ui2/screens/log_workout.dart' show LogWorkout;
import '../ui2/screens/metric_detail.dart' show MetricDetail;
import '../ui2/screens/workout_screen.dart'
    show WorkoutScreen, activityHost, loadSetHistory;
import '../ui2/screens/health_screen.dart' show HealthData;
import 'ritm_avatar.dart';
import 'ritm_calc.dart' show MonStatus, mean, monitorTileText, percentile;
import 'ritm_charts.dart';
import 'ritm_demo.dart';
import 'ritm_detail.dart';
import 'ritm_health.dart' show RitmHealthModel;
import 'ritm_hk.dart';
import 'ritm_rings.dart' show HrSegment;
import 'ritm_rings_store.dart';
import 'ritm_watch_store.dart';
import 'ritm_workout.dart';
import 'ritm_metrics.dart';
import 'ritm_community_api.dart' show RitmCommunity;
import 'ritm_community_feed.dart' show ritmDaySummary;
import 'ritm_night.dart' show RitmNightScreen;
import 'ritm_sleep.dart' show TonightPlan, bedtimeFor;
import 'ritm_seed.dart';
import 'ritm_stress.dart';
import 'ritm_more.dart' show RitmProfileScreen, RitmPaged;
import 'ritm_scores.dart';
import 'ritm_sources.dart' show RitmSourcesScreen;
import 'ritm_ui.dart';

class RitmHomeScreen extends StatefulWidget {
  /// Готовые данные (демо/тесты). В проде — null, экран читает базу сам.
  final RitmHomeSnapshot? snapshot;
  final DateTime? now;

  const RitmHomeScreen({super.key, this.snapshot, this.now});

  @override
  State<RitmHomeScreen> createState() => _RitmHomeScreenState();
}

/// Авто-найденная тренировка, ждущая ответа.
class RitmSuggestion {
  final DateTime start, end;
  final int? avgHr;
  final String? sport;
  final ActivitySuggestion? raw;

  /// Мягкий ярус «Ритма» (§10.6): найдено классификатором по секундам
  /// браслета, без пуша и без записи в базе Edge до ответа «Да».
  final bool soft;
  final WkType? type;
  const RitmSuggestion({
    required this.start,
    required this.end,
    this.avgHr,
    this.sport,
    this.raw,
    this.soft = false,
    this.type,
  });

  factory RitmSuggestion.soft(WkCandidate c) => RitmSuggestion(
    start: DateTime.fromMillisecondsSinceEpoch(c.from * 1000),
    end: DateTime.fromMillisecondsSinceEpoch(c.to * 1000),
    avgHr: c.avgHr,
    sport: c.type == WkType.other ? null : wkTypeKey(c.type),
    soft: true,
    type: c.type,
  );

  WkType? get kind => type ?? wkTypeOfKey(sport);

  factory RitmSuggestion.of(ActivitySuggestion s) {
    num? hr;
    for (final k in const ['avg_hr', 'mean_hr', 'hr_mean', 'avgHr']) {
      final v = s.details[k];
      if (v is num) {
        hr = v;
        break;
      }
    }
    return RitmSuggestion(
      start: DateTime.fromMillisecondsSinceEpoch(s.startTs * 1000),
      end: DateTime.fromMillisecondsSinceEpoch(s.endTs * 1000),
      avgHr: hr?.round(),
      sport: s.sport == 'detected' ? null : s.sport,
      raw: s,
    );
  }
}

/// Строка «Мой день» → тренировка дня (браслет, Watch или обе вместе).
List<RitmDayWorkout> ritmDayWorkouts(
  List<Map<String, dynamic>> sessions,
  List<HkWorkout> watch, {
  required String Function(String? type) nameOf,
  required IconData Function(String? type) iconOf,
  WatchData? hk,
}) {
  final out = <RitmDayWorkout>[];
  final used = <HkWorkout>{};
  for (final s in sessions) {
    final st = (s['start_ts'] as num?)?.toInt();
    if (st == null) continue;
    final dur = (s['duration_min'] as num?)?.toInt() ?? 0;
    final en = (s['end_ts'] as num?)?.toInt() ?? st + dur * 60;
    final from = DateTime.fromMillisecondsSinceEpoch(st * 1000);
    final to = DateTime.fromMillisecondsSinceEpoch(en * 1000);
    final ww = watchMatch(from, to, watch);
    if (ww != null) used.add(ww);
    out.add(
      RitmDayWorkout(
        name: ww != null ? hkTypeName(ww.type) : nameOf(s['type']?.toString()),
        start: ww?.s ?? from,
        end: ww?.e ?? to,
        strain: (s['strain'] as num?)?.toDouble(),
        bandAvgHr: (s['avg_hr'] as num?)?.round(),
        bandValidShare: (s['hr_valid_share'] as num?)?.toDouble(),
        watch: ww,
        hrr: ww == null ? null : hk?.hrrOf(ww),
        icon: iconOf(ww != null ? hkTypeKey(ww.type) : s['type']?.toString()),
        auto: s['source'] == 'auto',
      ),
    );
  }
  for (final ww in watch) {
    if (used.contains(ww)) continue;
    out.add(
      RitmDayWorkout(
        name: hkTypeName(ww.type),
        start: ww.s,
        end: ww.e,
        watch: ww,
        hrr: hk?.hrrOf(ww),
        icon: iconOf(hkTypeKey(ww.type)),
      ),
    );
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Всё, что рисует главная за один день.
class RitmHomeSnapshot {
  final HomeData d;
  final List<String> days;
  final List<Map<String, dynamic>> sessions;
  final ({double pct, bool charging})? battery;
  final DateTime? alarmAt;
  final bool alarmOn;
  final int pendingActivities;
  final List<RitmSuggestion> suggestions;

  /// Мягкий ярус «Ритма» (классификатор §10.6).
  final List<RitmSuggestion> soft;

  /// Ночная ВСР (rMSSD, мс) — для «Моих показателей».
  final num? hrv;

  /// Последняя запись с браслета (для «идёт сон» / «считаю»).
  final DateTime? dataEdge;
  final bool syncing;

  /// B2: стресс дня, 7 дней нагрузки/восстановления, «Мои показатели»,
  /// история для Монитора здоровья.
  final StressDay? stress;
  final List<WeekDayPoint> week;
  final RitmMetricValues? metrics;
  final HealthData? health;

  /// Эффективность сна (медиана последних ночей, %) — для отбоя.
  final num? effPct;

  /// B4½: кольца v3 дня (Восстановление §7.2, Нагрузка §7.3 + таймлайн).
  final RitmRingsDay? rings;

  const RitmHomeSnapshot({
    this.rings,
    this.effPct,
    required this.d,
    this.days = const [],
    this.sessions = const [],
    this.battery,
    this.alarmAt,
    this.alarmOn = false,
    this.pendingActivities = 0,
    this.suggestions = const [],
    this.soft = const [],
    this.hrv,
    this.dataEdge,
    this.syncing = false,
    this.stress,
    this.week = const [],
    this.metrics,
    this.health,
  });
}

class _RitmHomeScreenState extends State<RitmHomeScreen>
    with RevisionReload, WidgetsBindingObserver {
  HomeData? _d;

  /// Кольца v3 (ritm_rings_store); null — ещё не посчитаны (берём Edge).
  RitmRingsDay? _rings;

  /// Сон %: оценка v2 (4 составляющие), пока её нет — сон/потребность.
  int? _sp(HomeData d) =>
      _rings?.sleepScore?.pct.round() ?? ritmSleepPct(d.sleepMin.value, d.sleepNeedMin.value);

  /// Восстановление: v3 (§7.2), иначе — шкала Edge (до первых 4 ночей кэша).
  int? _rec(HomeData d, num? sp) =>
      _rings?.recovery.value ?? ritmRecovery(d.readiness.value, sleepPct: sp);

  /// Нагрузка: v3 по склеенному ряду (§7.3), иначе — Edge.
  num? _strainVal(HomeData d) {
    final s = _rings?.strain;
    return s != null && s.minutes > 0 ? s.strain : d.strain.value;
  }
  List<String> _days = const [];
  List<Map<String, dynamic>> _sessions = const [];
  List<RitmSuggestion> _suggestions = const [];
  List<RitmSuggestion> _soft = const [];
  final _autoConfirmed = <String>{};
  num? _hrv;
  StressDay? _stress;
  List<WeekDayPoint> _week = const [];
  RitmMetricValues? _mv;
  HealthData? _health;

  /// Эффективность сна, медиана 14 ночей (%), — сколько лежишь без сна.
  num? _effPct;
  RitmSeed _seed = RitmSeed.cached;
  int _pending = 0;
  String? _day;
  bool _loading = true;
  bool _failed = false;
  bool _syncing = false;
  DateTime? _lastAutoSync;
  final _scroll = ScrollController();
  final _myDayKey = GlobalKey();
  final _metricsKey = GlobalKey();
  final _chartsKey = GlobalKey();

  DateTime get _now => widget.now ?? ritmDemoNow() ?? DateTime.now();
  RitmHomeSnapshot? get _snap => widget.snapshot ?? ritmDemoHome(_day);

  @override
  bool get revisionReloads => _snap == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RitmWatchStore.data.addListener(_onWatch);
    RitmHealthKitChannel.changed.addListener(_onHkChanged);
    unawaited(RitmWatchStore.load());
    if (kRitmDemo) {
      ritmDemoStep.addListener(_demoStep);
      if (ritmDemoStep.value >= 20) _demoStep();
    }
    unawaited(RitmAvatar.load());
    if (_snap != null) {
      _applySnap();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _autoSync();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RitmWatchStore.data.removeListener(_onWatch);
    RitmHealthKitChannel.changed.removeListener(_onHkChanged);
    if (kRitmDemo) ritmDemoStep.removeListener(_demoStep);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _autoSync();
      unawaited(RitmWatchStore.load());
    }
  }

  void _onWatch() {
    if (!mounted) return;
    setState(() {});
    _autoConfirmWatch();
  }

  /// D5/D6: «Здоровье» сообщило о новой записи (сон, тренировка Watch…) —
  /// перечитать день и пересчитать кольца, не дожидаясь открытия экрана.
  void _onHkChanged() {
    if (!mounted || _snap != null) return;
    _load();
  }

  /// Тренировки Watch сегодняшнего дня.
  List<HkWorkout> get _watchDay {
    final hk = RitmWatchStore.data.value;
    if (hk == null) return const [];
    final id = _shownId;
    return [
      for (final w in hk.workouts)
        if (todayLabel(w.s) == id) w,
    ];
  }

  /// §10.6: пендинг Edge, перекрытый тренировкой Watch ≥ 50 %, подтверждаем
  /// сами — с типом Watch, без карточки.
  Future<void> _autoConfirmWatch() async {
    if (_snap != null || !_isToday) return;
    final repo = repoOf(context);
    if (repo == null) return;
    var changed = false;
    for (final s in _suggestions) {
      final raw = s.raw;
      if (raw == null || _autoConfirmed.contains(raw.id)) continue;
      final ww = watchMatch(s.start, s.end, _watchDay);
      if (ww == null) continue;
      _autoConfirmed.add(raw.id);
      try {
        await repo.confirmActivity(raw, workoutType: hkTypeKey(ww.type));
        changed = true;
      } catch (_) {}
    }
    if (changed && mounted) await _load();
  }

  /// §10.1: при открытии приложения — синхронизация и пересчёт, если данные
  /// с браслета старше 10 минут (или ночь ещё не закрыта). Не чаще раза в 2 мин.
  Future<void> _autoSync() async {
    if (_snap != null || !mounted) return;
    final last = _lastAutoSync;
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(minutes: 2)) {
      return;
    }
    AppState app;
    try {
      app = context.read<AppState>();
    } catch (_) {
      return;
    }
    if (!app.isPaired || app.syncingNow) return;
    final edgeTs = app.lastSynced?.tsEpoch;
    final edge = edgeTs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(edgeTs * 1000);
    final open = _d?.recoveryState == 'night_in_progress';
    if (!open && edge != null && now.difference(edge) <= kNightStale) return;
    _lastAutoSync = now;
    setState(() => _syncing = true);
    try {
      await app.syncNow().timeout(const Duration(seconds: 90));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _syncing = false);
    await _load();
  }

  /// Автопилот демо (только DEBUG + RITM_DEMO): день и прокрутка по шагу.
  bool _demoPushed = false;

  /// B2: шаги 20–26 — главная внизу, экраны показателей, «Настроить».
  void _demoStepB2(int step) {
    final c = context;
    final nav = Navigator.of(c);
    if (_demoPushed) {
      nav.pop();
      _demoPushed = false;
    }
    final d = _d;
    if (d == null) return;
    final s = _states(d);
    Widget? page = switch (step) {
      21 => RitmSleepScreen(hero: s.sleep, score: _rings?.sleepScore, needRes: _rings?.need,
                    plan: _d == null ? null : _plan(context, _d!),
                    debtHist: _rings?.debtHist ?? const [],
                    norms: _rings?.norms ?? const {}),
      22 => RitmRecoveryScreen(hero: s.recovery, rings: _rings),
      23 => RitmStrainScreen(hero: s.strain, sub: _strainSub(d)),
      24 => const RitmStressScreen(),
      _ => null,
    };
    if (step == 20) {
      final ctx = _chartsKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .12);
    } else if (step == 26) {
      final ctx = _metricsKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx);
      _demoPushed = true;
      unawaited(showRitmMetricsTune(c));
    } else if (page != null) {
      _demoPushed = true;
      go(c, page);
    }
  }

  /// B3: 28 «Мой день», 31 экран тренировки, 32 «Мои показатели»,
  /// 37 пикер «Другой тип».
  void _demoStepB3(int step) {
    final c = context;
    // Всё, что открыто поверх (экраны прошлых шагов, листы), — закрыть.
    Navigator.of(c, rootNavigator: true).popUntil((r) => r.isFirst);
    Navigator.of(c).popUntil((r) => r.isFirst);
    _demoPushed = false;
    if (_shownId != _todayId) _goDay(_todayId);
    void show(GlobalKey k, [double a = 0]) {
      final ctx = k.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: a);
    }

    switch (step) {
      case 28:
        show(_myDayKey);
      case 31:
        final list = ritmDayWorkouts(
          _sessions,
          _watchDay,
          nameOf: (t) => activityByName(t)?.displayName(c) ?? 'Тренировка',
          iconOf: (t) => activityByName(t)?.icon ?? LucideIcons.activity,
          hk: RitmWatchStore.data.value,
        );
        final w = list.where((x) => x.watch != null).firstOrNull;
        if (w != null) {
          _demoPushed = true;
          go(c, RitmWorkoutScreen(w: w));
        }
      case 32:
        show(_metricsKey);
      case 37:
        // Начальный шаг прогона B4 (FROM = 38) — пикер не открываем.
        if (const int.fromEnvironment('RITM_DEMO_FROM') > 37) return;
        show(_myDayKey);
        _demoPushed = true;
        unawaited(showRitmWkTypePicker(c));
    }
  }

  /// B4: 46 главная верх, 47 «Мой день» (отбой 22:50), 48 «Мои показатели»,
  /// 49–50 экран тренировки (график пульса по зонам), 51–52 вчера (плитки,
  /// активности: велосипед легче бега).
  void _demoStepB4(int step) {
    final c = context;
    Navigator.of(c, rootNavigator: true).popUntil((r) => r.isFirst);
    Navigator.of(c).popUntil((r) => r.isFirst);
    _demoPushed = false;
    final want = step >= 51
        ? todayLabel(DateTime(_now.year, _now.month, _now.day - 1))
        : _todayId;
    if (_shownId != want) _goDay(want);
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void show(GlobalKey k, [double a = 0]) {
        final ctx = k.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignment: a);
      }

      switch (step) {
        case 46:
        case 51:
          if (_scroll.hasClients) _scroll.jumpTo(0);
        case 47:
        case 52:
          show(_myDayKey);
        case 48:
          show(_metricsKey);
        case 49:
        case 50:
          final list = ritmDayWorkouts(
            _sessions,
            _watchDay,
            nameOf: (t) => activityByName(t)?.displayName(c) ?? 'Тренировка',
            iconOf: (t) => activityByName(t)?.icon ?? LucideIcons.activity,
            hk: RitmWatchStore.data.value,
          );
          final w = list.where((x) => x.watch != null).firstOrNull;
          if (w != null) {
            _demoPushed = true;
            go(c, RitmWorkoutScreen(w: w, scrollEnd: step == 50));
          }
      }
    });
  }

  // B4½: 56 главная верх, 57–58 «Восстановление» (факторы; вклады).
  void _demoStepB4h(int step) {
    final c = context;
    Navigator.of(c, rootNavigator: true).popUntil((r) => r.isFirst);
    Navigator.of(c).popUntil((r) => r.isFirst);
    if (_shownId != _todayId) _goDay(_todayId);
    // Не postFrame: на статичной главной кадра может не быть до следующего шага.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      final d = _d;
      if (step >= 70 && d != null) {
        // B4¾: 70 главная (кольцо «Сон» = оценка v2), 71 «Сон» вверху,
        // 72 — прокручен к «Сегодня ночью», 73 «Ночь».
        if (step >= 71) {
          go(
            context,
            step == 73
                ? const RitmNightScreen()
                : RitmSleepScreen(
                    hero: _states(d).sleep,
                    score: _rings?.sleepScore,
                    needRes: _rings?.need,
                    plan: _d == null ? null : _plan(context, _d!),
                    debtHist: _rings?.debtHist ?? const [],
                    norms: _rings?.norms ?? const {},
                    demoScroll: step == 72 ? 560 : 0,
                  ),
          );
        }
      } else if (step >= 57 && d != null) {
        go(context, RitmRecoveryScreen(hero: _states(d).recovery, rings: _rings, demoScrollEnd: step == 58));
      }
    });
  }

  void _demoStep() {
    final step = ritmDemoStep.value;
    if (step == 58) return; // «Восстановление» само прокрутится (ritm_detail)
    if ((step >= 56 && step <= 57) || (step >= 70 && step <= 73)) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted && ritmDemoStep.value == step) _demoStepB4h(step);
      });
      return;
    }
    if (step >= 46 && step <= 52) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted && ritmDemoStep.value == step) _demoStepB4(step);
      });
      return;
    }
    if (step == 28 || step == 31 || step == 32 || step == 37) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted && ritmDemoStep.value == step) _demoStepB3(step);
      });
      return;
    }
    if (step >= 20 && step <= 27) {
      // Вкладка могла только что смениться — даём ей отрисоваться.
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted && ritmDemoStep.value == step) _demoStepB2(step);
      });
      return;
    }
    if (step < 0 || step > 5) return;
    final back = step <= 2 ? 0 : step - 2;
    final id = todayLabel(DateTime(_now.year, _now.month, _now.day - back));
    if (id != _shownId) _goDay(id);
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final key = switch (step) {
        1 => _myDayKey,
        2 => _metricsKey,
        _ => null,
      };
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx);
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  void _applySnap() {
    final s = _snap!;
    _rings = s.rings;
    _d = s.d;
    _days = s.days;
    _sessions = s.sessions;
    _hrv = s.hrv;
    _stress = s.stress;
    _week = s.week;
    _mv = s.metrics;
    _health = s.health;
    _effPct = s.effPct;
    _pending = s.pendingActivities;
    _suggestions = s.suggestions;
    _soft = s.soft;
    _loading = false;
  }

  @override
  void reload() => _load();

  Future<void> _load() async {
    if (_snap != null) {
      setState(_applySnap);
      return;
    }
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final t = beginRead(#ritmHome);
    try {
      final l = AppLocalizations.of(context);
      final day = _day;
      final isToday = day == null || day == todayLabel(_now);
      final d = isToday
          ? await HomeData.load(repo, l)
          : await HomeData.loadForDay(repo, day, l);
      final days = await repo.availableDays();
      final id = d.dayId ?? day ?? todayLabel(_now);
      final start = DateTime.tryParse(id) ?? _now;
      final from = DateTime(start.year, start.month, start.day);
      final to = from.add(const Duration(days: 1));
      List<Map<String, dynamic>> sessions = const [];
      try {
        sessions = await repo.getSessions(
          from: from.millisecondsSinceEpoch ~/ 1000,
          to: to.millisecondsSinceEpoch ~/ 1000,
          includeDetected: false,
        );
      } catch (_) {}
      // Ночная ВСР — только за сегодняшнюю ночь (не «перенесённую» старую).
      num? hrv;
      var pending = 0;
      var suggestions = <RitmSuggestion>[];
      if (isToday) {
        try {
          final list = await repo.pendingActivities();
          suggestions = [
            for (final s in list)
              if (s.kind == ActivityKind.workout) RitmSuggestion.of(s),
          ];
          pending = list.length;
        } catch (_) {}
        try {
          final today = await repo.getToday();
          final h = today['hrv'];
          if (heldOverNightOf(today) == null && h is Map) {
            hrv = h['rmssd'] as num?;
          }
        } catch (_) {}
      }
      if (stillNewest(#ritmHome, t)) {
        setState(() {
          _hrv = hrv;
          _pending = pending;
          _suggestions = suggestions;
          if (!isToday) _soft = const [];
          _d = d;
          _days = days;
          _sessions = sessions;
          _loading = false;
          _failed = false;
        });
        unawaited(_loadExtras(repo, id, isToday, d));
        unawaited(_loadRings(repo, id, days));
        _autoConfirmWatch();
      }
    } catch (_) {
      if (stillNewest(#ritmHome, t)) {
        setState(() => (_loading = false, _failed = true));
      }
    }
  }

  /// B4½: кольца v3 по дням (кэш ritm_rings.json; досчёт до 45 дней).
  Future<void> _loadRings(dynamic repo, String id, List<String> days) async {
    try {
      final r = await RitmRingsStore.ensure(
        repo,
        id,
        available: days,
        watch: RitmWatchStore.data.value?.workouts ?? const <HkWorkout>[],
      );
      if (mounted && _snap == null && (_d?.dayId ?? id) == id) setState(() => _rings = r);
      // B5: итог дня — в «Сообщество» (только агрегаты; правила отправки — RitmSummarySync).
      if (r != null && !kRitmDemo && _isToday) {
        final com = RitmCommunity.I;
        unawaited(com.start().then((_) => com.offerSummary(ritmDaySummary(r, sessions: _sessions))));
      }
    } catch (_) {}
  }

  /// B2: Монитор здоровья (история + засев), стресс, неделя, показатели.
  /// Отдельно от основного чтения — главная не ждёт тяжёлых запросов.
  Future<void> _loadExtras(
    dynamic repo,
    String id,
    bool isToday,
    HomeData d,
  ) async {
    final day = DateTime.tryParse(id) ?? _now;
    final t = beginRead(#ritmHomeExtras);
    HealthData? health;
    try {
      health = await HealthData.load(repo);
      try {
        health.charts['skin_temp_dev_c'] = pointsOf(
          await repo.getChart('skin_temp_dev_c'),
        );
      } catch (_) {}
    } catch (_) {}
    final seed = await RitmSeed.load();
    // 7 дней нагрузки и восстановления, заканчивая показанным днём.
    final week = <WeekDayPoint>[];
    try {
      final st = pointsOf(await repo.getChart('strain'));
      final rc = pointsOf(await repo.getChart('recovery'));
      double? at(List<({int t, double v})> pts, DateTime dd) {
        for (final p in pts) {
          final x = DateTime.fromMillisecondsSinceEpoch(p.t * 1000);
          if (x.year == dd.year && x.month == dd.month && x.day == dd.day) {
            return p.v;
          }
        }
        return null;
      }

      for (var i = 6; i >= 0; i--) {
        final dd = DateTime(day.year, day.month, day.day - i);
        final r = at(rc, dd);
        week.add(
          WeekDayPoint(
            dd,
            strain: at(st, dd),
            recovery: r == null ? null : ritmRecovery(r)?.toDouble(),
          ),
        );
      }
    } catch (_) {}
    num? eff;
    try {
      final e = [for (final p in pointsOf(await repo.getChart('efficiency'))) p.v];
      final tail = e.length > 14 ? e.sublist(e.length - 14) : e;
      if (tail.length >= 3) eff = percentile(tail, .5);
    } catch (_) {}
    if (stillNewest(#ritmHomeExtras, t)) {
      setState(() {
        _effPct = eff;
        _health = health;
        _seed = seed;
        _week = week;
      });
    }
    // Мои показатели: нормы из истории, зоны и силовые за 7 дней.
    RitmMetricValues? mv;
    try {
      final hrvHist = health == null
          ? const <double>[]
          : [for (final p in health.points('hrv')) p.v];
      final rhrHist = health == null
          ? const <double>[]
          : [for (final p in health.points('resting_hr')) p.v];
      List<double> tail(List<double> x) =>
          x.length > 30 ? x.sublist(x.length - 30) : x;
      var z13 = 0, z45 = 0, zDays = 0, strength = 0;
      for (var i = 6; i >= 0; i--) {
        final dd = DateTime(day.year, day.month, day.day - i);
        try {
          final m = await repo.getDayStrain(todayLabel(dd));
          final z = m['zones'];
          if (z is Map && z.isNotEmpty) {
            int v(int k) => (z['z$k'] as num?)?.round() ?? 0;
            z13 += v(1) + v(2) + v(3);
            z45 += v(4) + v(5);
            zDays++;
          }
        } catch (_) {}
      }
      try {
        final from = DateTime(day.year, day.month, day.day - 6);
        final ss = await repo.getSessions(
          from: from.millisecondsSinceEpoch ~/ 1000,
          to: DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch ~/ 1000,
          includeDetected: false,
        );
        for (final s in ss) {
          if (isStrengthType(s['type']?.toString())) {
            strength += ((s['duration_min'] as num?) ?? 0).round();
          }
        }
      } catch (_) {}
      mv = RitmMetricValues(
        hrv: _hrv,
        hrvNorm: percentile(tail(hrvHist), .5),
        rhr: d.rhr.value,
        rhrMean30: mean(tail(rhrHist)),
        steps: d.steps.value,
        kcal: d.caloriesTotal.value ?? d.calories.value,
        z13: zDays == 0 ? null : z13,
        z45: zDays == 0 ? null : z45,
        strength: strength,
      );
    } catch (_) {}
    if (stillNewest(#ritmHomeExtras, t)) setState(() => _mv = mv);
    // Стресс — последним: читает секунды браслета за день.
    try {
      final sd = await loadStressDay(repo, day, isToday ? _now : day.add(const Duration(days: 1)));
      if (stillNewest(#ritmHomeExtras, t)) setState(() => _stress = sd);
    } catch (_) {}
    if (isToday) unawaited(_loadSoft(repo, d));
  }

  /// §10.6, мягкий ярус: пульс ≥ RHR + 0,30·HRR ≥ 20 мин + движение по
  /// секундам браслета за сегодня → карточка без пуша.
  Future<void> _loadSoft(dynamic repo, HomeData d) async {
    try {
      final rhr = d.rhr.value?.toDouble();
      if (rhr == null) return;
      final from = DateTime(_now.year, _now.month, _now.day);
      final secs = await readWkSecs(
        from.millisecondsSinceEpoch ~/ 1000,
        _now.millisecondsSinceEpoch ~/ 1000,
      );
      if (secs.isEmpty) return;
      final found = detectWorkouts(secs, rhr: rhr, hrMax: _hrMax());
      final busy = <({int from, int to})>[
        for (final s in _sessions)
          if (s['start_ts'] is num)
            (
              from: (s['start_ts'] as num).toInt(),
              to: (s['end_ts'] as num?)?.toInt() ??
                  (s['start_ts'] as num).toInt() +
                      (((s['duration_min'] as num?) ?? 0).toInt() * 60),
            ),
        for (final s in _suggestions)
          (
            from: s.start.millisecondsSinceEpoch ~/ 1000,
            to: s.end.millisecondsSinceEpoch ~/ 1000,
          ),
      ];
      final soft = softCandidates(
        found,
        busy: busy,
        watch: _watchDay,
        dismissed: RitmWkDismissed.all,
      );
      if (mounted) {
        setState(() => _soft = [for (final c in soft) RitmSuggestion.soft(c)]);
      }
    } catch (_) {}
  }

  /// HRmax: из профиля (или 208 − 0,7·возраст), но не ниже максимума
  /// тренировок Watch за неделю.
  double _hrMax() {
    double base = 185;
    try {
      final u = context.read<AppState>().user;
      final hm = (u?['hr_max'] as num?)?.toDouble();
      final age = (u?['age'] as num?)?.toDouble();
      base = hm ?? (age == null ? 185 : 208 - 0.7 * age);
    } catch (_) {}
    for (final w in RitmWatchStore.data.value?.workouts ?? const <HkWorkout>[]) {
      if ((w.hrMax ?? 0) > base) base = w.hrMax!;
    }
    return base;
  }

  String get _todayId => todayLabel(_now);
  String get _shownId => _day ?? _d?.dayId ?? _todayId;
  bool get _isToday => _day == null || _day == _todayId;

  /// Соседний день с данными: older=true — назад.
  String? _neighbour(bool older) {
    final cur = _shownId;
    final all = {..._days, _todayId}.toList()..sort();
    final i = all.indexOf(cur);
    if (i < 0) return older && all.isNotEmpty ? all.last : null;
    final j = older ? i - 1 : i + 1;
    return j >= 0 && j < all.length ? all[j] : null;
  }

  void _goDay(String? id) {
    if (id == null) return;
    setState(() {
      _day = id == _todayId ? null : id;
      _loading = _snap == null;
    });
    _load();
  }

  Future<void> _pull() async {
    if (_snap != null) return;
    try {
      final app = context.read<AppState>();
      if (app.isPaired && _isToday) {
        setState(() => _syncing = true);
        await app.syncNow().timeout(const Duration(seconds: 90));
      }
    } catch (_) {}
    if (mounted) setState(() => _syncing = false);
    await _load();
  }

  /// Состояние ночи для колец (§10.1).
  NightPhase _phase(HomeData d) {
    final snap = _snap;
    DateTime? edge = snap?.dataEdge;
    var syncing = snap?.syncing ?? _syncing;
    if (snap == null) {
      try {
        final app = context.read<AppState>();
        final ts = app.lastSynced?.tsEpoch;
        if (ts != null) edge = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        syncing = syncing || app.syncingNow;
      } catch (_) {}
    }
    return ritmNightPhase(
      hasNight: d.sleepMin.value != null,
      recoveryState: d.recoveryState,
      now: _now,
      dataEdge: edge,
      syncing: syncing,
      isToday: _isToday,
    );
  }

  @override
  Widget build(BuildContext c) {
    final d = _d;
    final bottom = RS.tabBarClearance + MediaQuery.paddingOf(c).bottom;
    return DecoratedBox(
      decoration: RC.background,
      child: RefreshIndicator(
        onRefresh: _pull,
        color: RC.ink,
        backgroundColor: RC.card,
        child: ListView(
          controller: _scroll,
          scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
          padding: EdgeInsets.fromLTRB(RS.screen, 4, RS.screen, bottom),
          children: [
            _header(c, d),
            const SizedBox(height: 20),
            if (d == null)
              _empty(c)
            else ...[
              _gauges(c, d),
              const SizedBox(height: 14),
              _sources(c, d),
              const SizedBox(height: RS.sectionGap),
              _pulse(c, d),
              if (_corridor(d) case final w?) ...[
                const SizedBox(height: RS.cardGap),
                w,
              ],
              const SizedBox(height: RS.cardGap),
              _monitors(c, d),
              const SizedBox(height: RS.sectionGap),
              _myDay(c, d),
              const SizedBox(height: RS.sectionGap),
              KeyedSubtree(key: _chartsKey, child: _stressCard(c)),
              const SizedBox(height: RS.cardGap),
              _weekCard(c),
            ],
          ],
        ),
      ),
    );
  }

  // ── шапка ──
  Widget _header(BuildContext c, HomeData? d) {
    final streak = wearStreak(_days, _now);
    final snap = _snap;
    final bat = snap != null
        ? snap.battery
        : switch (deviceBatteryOf(c)) {
            final (double, bool) b => (pct: b.$1, charging: b.$2),
            null => null,
          };
    final name = (d?.name ?? '').trim();
    final older = _neighbour(true), newer = _neighbour(false);
    final label = _isToday ? 'СЕГОДНЯ' : shortDayRu(_shownId).toUpperCase();
    return SizedBox(
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  button: true,
                  label: 'Профиль',
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: snap != null
                        ? null
                        : () => go(c, const RitmProfileScreen()),
                    child: ValueListenableBuilder<String?>(
                      valueListenable: RitmAvatar.path,
                      builder: (_, p, _) => RAvatar(
                        size: 32,
                        path: kRitmDemo ? ritmDemoAvatarPath() : p,
                        name: name,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Semantics(
                  label:
                      'Серия: $streak ${plural(streak, 'день', 'дня', 'дней')} с браслетом',
                  excludeSemantics: true,
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    decoration: BoxDecoration(
                      color: RC.card,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.flame,
                          size: 14,
                          color: streak > 0 ? RC.yellow : RC.ink3,
                        ),
                        const SizedBox(width: 4),
                        Text('$streak', style: RT.label),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 32,
            decoration: BoxDecoration(
              color: RC.card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _arrow(
                  LucideIcons.chevronLeft,
                  older == null ? null : () => _goDay(older),
                  'Предыдущий день',
                ),
                GestureDetector(
                  onTap: _isToday ? null : () => _goDay(_todayId),
                  child: Container(
                    height: 28,
                    constraints: const BoxConstraints(minWidth: 84),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: RC.cardHi,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(label, style: RT.cap),
                  ),
                ),
                _arrow(
                  LucideIcons.chevronRight,
                  newer == null ? null : () => _goDay(newer),
                  'Следующий день',
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Semantics(
              label: bat == null
                  ? 'Браслет: заряд неизвестен'
                  : 'Браслет: заряд ${bat.pct.round()}%',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: snap != null
                    ? null
                    : () => go(c, const RitmSourcesScreen()),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bat == null ? '—' : pct(bat.pct),
                      style: RT.label.copyWith(
                        color: bat != null && bat.pct <= 20 && !bat.charging
                            ? RC.red
                            : RC.ink2,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      bat?.charging == true
                          ? LucideIcons.batteryCharging
                          : LucideIcons.watch,
                      size: 20,
                      color: bat == null ? RC.ink3 : RC.ink2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrow(IconData i, VoidCallback? onTap, String label) => Semantics(
    button: true,
    label: label,
    child: InkResponse(
      onTap: onTap,
      radius: 18,
      child: SizedBox(
        width: 36,
        height: 32,
        child: Icon(i, size: 18, color: onTap == null ? RC.ink3 : RC.ink),
      ),
    ),
  );

  Widget _empty(BuildContext c) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            Row(
              children: [
                for (final l in const ['Сон', 'Восстановление', 'Нагрузка'])
                  Expanded(
                    child: Center(
                      child: RitmGauge(
                        s: const GaugeState(kind: GaugeKind.none, value: ''),
                        label: l,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: RS.sectionGap),
            Container(
              height: 110,
              decoration: BoxDecoration(
                color: RC.card,
                borderRadius: BorderRadius.circular(RS.rCard),
              ),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return RCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Не удалось прочитать данные', style: RT.title),
            const SizedBox(height: 6),
            const Text(
              'Данные не удалены — это ошибка чтения.',
              style: RT.body,
            ),
            const SizedBox(height: 12),
            RButton(LucideIcons.refreshCw, 'Повторить', onTap: _load),
          ],
        ),
      );
    }
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Подключите браслет', style: RT.title),
          const SizedBox(height: 6),
          const Text(
            'Носите браслет ночью — утром здесь появятся сон, восстановление и нагрузка.',
            style: RT.body,
          ),
          const SizedBox(height: 12),
          RButton(
            LucideIcons.watch,
            'Источники',
            onTap: () => go(c, const RitmSourcesScreen()),
          ),
        ],
      ),
    );
  }

  // ── три кольца ──
  ({GaugeState sleep, GaugeState recovery, GaugeState strain}) _states(
    HomeData d,
  ) {
    final phase = _phase(d);
    final sleepMin = d.sleepMin.value;
    final need = d.sleepNeedMin.value;
    final sp = _rings?.sleepScore?.pct.round() ?? ritmSleepPct(sleepMin, need);

    // Сон
    final GaugeState sleep;
    switch (phase) {
      case NightPhase.asleep:
        sleep = const GaugeState(
          kind: GaugeKind.provisional,
          value: '–',
          inner: 'идёт сон',
        );
      case NightPhase.computing:
        sleep = const GaugeState.computing();
      case NightPhase.none:
        sleep = const GaugeState.none();
      case NightPhase.done:
        if (sleepMin == null) {
          sleep = const GaugeState.none();
        } else if (sp == null) {
          sleep = GaugeState(
            kind: GaugeKind.provisional,
            value: hmm(sleepMin),
            inner: 'сон',
          );
        } else {
          sleep = GaugeState(
            frac: sp / 100,
            color: RC.zone(sleepZone(sp)),
            value: pct(sp),
            inner: hmm(sleepMin),
          );
        }
    }

    // Восстановление
    final rec = _rec(d, sp);
    final rz = recoveryZone(rec);
    final v3 = _rings?.recovery;
    final GaugeState recovery;
    if (phase == NightPhase.asleep) {
      recovery = const GaugeState(
        kind: GaugeKind.provisional,
        value: '–',
        inner: 'идёт сон',
      );
    } else if (phase == NightPhase.computing) {
      recovery = const GaugeState.computing();
    } else if (rec != null) {
      final prov = v3?.value != null ? v3!.preliminary : d.recoveryState == 'provisional';
      recovery = GaugeState(
        kind: prov ? GaugeKind.provisional : GaugeKind.measured,
        frac: rec / 100,
        color: RC.zone(rz),
        value: pct(rec),
        // «Готов ↑» — зона словом и стрелка к вчера (|Δ| ≥ 5 п.п.).
        inner: prov ? 'уточняется' : '${recoveryWord(rz!)}${_rings?.arrow ?? ''}',
      );
    } else if (v3 != null && v3.why == 'calibrating' && v3.nights > 0) {
      recovery = GaugeState.calibrating(v3.nights, 4);
    } else if (baselineCountsFromNote(d.readiness.note) case final n?) {
      recovery = GaugeState.calibrating(n.have, n.need);
    } else {
      recovery = const GaugeState.none();
    }

    // Нагрузка
    final st = _strainVal(d);
    final target = strainTargetFor(rz);
    final GaugeState strain;
    if (st != null) {
      strain = GaugeState(
        frac: st / 21,
        color: RC.strain(st),
        value: dec1(st),
        inner: strainWord(st),
        targetLo: _isToday && target != null ? target.lo / 21 : null,
        targetHi: _isToday && target != null ? target.hi / 21 : null,
      );
    } else if (baselineCountsFromNote(d.strain.note) case final n?) {
      strain = GaugeState.calibrating(n.have, n.need);
    } else {
      strain = const GaugeState.none();
    }
    return (sleep: sleep, recovery: recovery, strain: strain);
  }

  Widget _gauges(BuildContext c, HomeData d) {
    final s = _states(d);
    final demo = _snap != null;
    Widget col(GaugeState g, String label, VoidCallback onTap) => Expanded(
      child: Center(
        child: RitmGauge(s: g, label: label, onTap: demo ? () {} : onTap),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        col(
          s.sleep,
          'Сон',
          () => go(c, RitmSleepScreen(day: _isToday ? null : _day, hero: s.sleep, score: _rings?.sleepScore, needRes: _rings?.need,
                    plan: _d == null ? null : _plan(context, _d!),
                    debtHist: _rings?.debtHist ?? const [],
                    norms: _rings?.norms ?? const {})),
        ),
        col(
          s.recovery,
          'Восстановление',
          () => go(c, RitmRecoveryScreen(hero: s.recovery, rings: _rings)),
        ),
        col(
          s.strain,
          'Нагрузка',
          () => go(
            c,
            RitmStrainScreen(
              day: _isToday ? null : _day,
              hero: s.strain,
              sub: _strainSub(d),
              sportName: (t) => activityByName(t)?.displayName(c) ?? 'Тренировка',
            ),
          ),
        ),
      ],
    );
  }

  // ── источник колец + таймлайн пульса 24 ч (ТЗ v3 §9, MULTIDEVICE §7 п. 1–2) ──
  Widget _sources(BuildContext c, HomeData d) {
    final r = _rings;
    final strainSrc = r?.strainSource;
    final tl = r?.inputs.timeline ?? const <HrSegment>[];
    final from = r?.dayFrom ?? 0;
    var to = r?.dayTo ?? 0;
    if (_isToday) {
      final nowS = _now.millisecondsSinceEpoch ~/ 1000;
      if (nowS < to) to = nowS;
    }
    var off = 0;
    for (final g in tl) {
      if (g.src == null && g.to <= to) off += (math.min(g.to, to) - g.from) ~/ 60;
    }
    // Подпись источника — две строки слева (в одну не помещается на 393 pt).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('сон и восстановление — браслет', style: RT.micro),
        if (strainSrc != null) ...[
          const SizedBox(height: 2),
          Text('нагрузка — $strainSrc', style: RT.micro),
        ],
        if (tl.isNotEmpty && to > from) ...[
          const SizedBox(height: 8),
          Semantics(
            label: 'Пульс за день по источникам',
            child: RitmHrTimeline(segments: tl, from: r!.dayFrom, to: r.dayTo, now: to),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('0:00', style: RT.micro),
              const Spacer(),
              _legend(RC.ink3, 'браслет'),
              const SizedBox(width: 10),
              _legend(RC.strain0, 'Watch'),
              if (off >= 10) ...[
                const SizedBox(width: 10),
                Text('не носился ${hmm(off)}', style: RT.micro),
              ],
              const Spacer(),
              const Text('24:00', style: RT.micro),
            ],
          ),
        ],
      ],
    );
  }

  Widget _legend(Color c, String t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 8, height: 4, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 4),
      Text(t, style: RT.micro),
    ],
  );

  // ── строка коридора нагрузки с мини-шкалой 0–21 (K8) ──
  Widget? _corridor(HomeData d) {
    if (!_isToday) return null;
    final sp = _sp(d);
    final rz = recoveryZone(_rec(d, sp));
    final t = strainTargetFor(rz);
    final st = _strainVal(d);
    if (t == null || st == null) return null;
    final left = t.lo - st;
    final txt = st >= t.hi
        ? 'Коридор ${t.lo.round()}–${t.hi.round()} пройден — дальше только лёгкое'
        : (left > 0
            ? 'Коридор на сегодня ${t.lo.round()}–${t.hi.round()} · до него ${dec1(left)}'
            : 'В коридоре ${t.lo.round()}–${t.hi.round()} · ещё до ${dec1(t.hi - st)}');
    return RCard(
      pad: const EdgeInsets.fromLTRB(RS.cardPad, 12, RS.cardPad, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Число Нагрузки — в кольце выше; здесь только коридор.
          Text(txt, style: RT.label),
          const SizedBox(height: 10),
          RitmStrainScale(value: st.toDouble(), lo: t.lo, hi: t.hi),
        ],
      ),
    );
  }

  // ── Пульс дня ──
  Widget _pulse(BuildContext c, HomeData d) {
    final phase = _phase(d);
    final sp = _sp(d);
    final rec = phase == NightPhase.done || phase == NightPhase.none
        ? _rec(d, sp)
        : null;
    Map<String, dynamic>? top;
    final v3d = _rings?.recovery.drivers ?? const [];
    if (v3d.isNotEmpty) {
      // v3: вклад фактора в пунктах (кроме сна — он отдельной строкой текста).
      for (final x in v3d) {
        if (x.key == 'sleep') continue;
        if (top == null || x.points.abs() > (top['contribution'] as double).abs()) {
          top = {'label': x.key, 'contribution': x.points};
        }
      }
    } else {
      for (final e in d.drivers) {
        final v = (e['contribution'] as num?)?.abs() ?? 0;
        if (top == null || v > ((top['contribution'] as num?)?.abs() ?? 0)) {
          top = e;
        }
      }
    }
    final input = PulseInput(
      name: d.name,
      recovery: rec,
      sleepPct: sp,
      sleepMin: d.sleepMin.value,
      needMin: d.sleepNeedMin.value,
      strain: _strainVal(d),
      bedtimeMinOfDay: (_plan(c, d) == null ? null : _bedMin(_plan(c, d)!)) ?? d.bedtime.value?.round(),
      driver: top?['label']?.toString(),
      driverSign: (top?['contribution'] as num?)?.toDouble(),
      calibrating: rec == null
          ? baselineCountsFromNote(d.readiness.note)
          : null,
      hour: _now.hour,
      isToday: _isToday,
    );
    final text = switch (phase) {
      NightPhase.computing =>
        'Забираю ночь с браслета и считаю сон и восстановление — обычно это занимает несколько минут.',
      NightPhase.asleep =>
        'Ночь ещё идёт. Сон и восстановление посчитаю после пробуждения.',
      _ => pulseText(input),
    };
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_isToday ? pulseTitle(input) : 'Итог дня', style: RT.title),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(text, style: RT.body),
          ],
        ],
      ),
    );
  }

  // ── плитки мониторов ──
  /// Модель Монитора здоровья (5 строк §10.4) — та же, что во «Здоровье».
  RitmHealthModel? get _healthModel {
    final h = _health;
    if (h == null) return null;
    return RitmHealthModel.from(
      h,
      seed: _seed,
      now: _now,
      watch: RitmWatchStore.data.value,
    );
  }

  Widget _monitors(BuildContext c, HomeData d) {
    final m = _isToday ? _healthModel : null;
    final nights = _days.length.clamp(0, 7);
    // Плитка — итог Монитора здоровья (как у WHOOP: иконка + одна строка).
    final (Color ic, String health) = m == null
        ? switch (d.illnessState) {
            'green' => (RC.green, 'В норме'),
            'amber' => (RC.yellow, _amberText(d)),
            'red' => (RC.red, 'Вне нормы'),
            _ => (RC.ink2, 'Изучаем · $nights/7'),
          }
        : (
            switch (m.summary.status) {
              MonStatus.ok => RC.green,
              MonStatus.warn => RC.yellow,
              MonStatus.alert => RC.red,
              _ => RC.ink2,
            },
            monitorTileText(m.rows),
          );
    final st = _stress;
    final sl = st?.latest?.s;
    return Row(
      children: [
        Expanded(
          child: RTile(
            title: 'Монитор здоровья',
            icon: LucideIcons.activity,
            iconColor: ic,
            text: health,
            onTap: () => _openHealth(),
          ),
        ),
        const SizedBox(width: RS.cardGap),
        Expanded(
          child: RTile(
            title: 'Монитор стресса',
            icon: LucideIcons.waves,
            iconColor: sl == null || !(st?.calibrated ?? false)
                ? RC.ink2
                : RC.brandA,
            // Минутные окна хранятся только за сегодня — для прошлых дней
            // плитка честно говорит об этом, а не «Нет данных».
            text: _isToday ? stressTileText(st) : 'Только за сегодня',
            onTap: _snap != null ? () {} : () => go(c, const RitmStressScreen()),
          ),
        ),
      ],
    );
  }

  /// Прошлый день «1 вне нормы» — с названием и числом (§4.3), если по
  /// истории видно, что вышло за коридор.
  String _amberText(HomeData d) {
    final h = _health;
    final r = d.rhr.value;
    if (h != null && r != null) {
      final hist = [for (final p in h.points('resting_hr')) p.v];
      final p90 = hist.length >= 7 ? percentile(hist, .9) : null;
      if (p90 != null && r > p90) return 'Пульс покоя ${r.round()} ↑';
    }
    final v = _hrv;
    if (h != null && v != null) {
      final hist = [for (final p in h.points('hrv')) p.v];
      final p10 = hist.length >= 7 ? percentile(hist, .1) : null;
      if (p10 != null && v < p10) return 'ВСР ${v.round()} ↓';
    }
    return '1 вне нормы';
  }

  /// «Высокая · цель 10–14» под героем «Нагрузки».
  String? _strainSub(HomeData d) {
    final st = d.strain.value;
    if (st == null) return null;
    final sp = _sp(d);
    final t = strainTargetFor(recoveryZone(ritmRecovery(d.readiness.value, sleepPct: sp)));
    final w = strainWord(st);
    return t == null || !_isToday
        ? w
        : '$w · цель ${t.lo.round()}–${t.hi.round()}';
  }

  /// §2 п. 7: «Монитор стресса» за день (карточка 260).
  Widget _stressCard(BuildContext c) {
    final st = _stress;
    final day = DateTime.tryParse(_shownId) ?? _now;
    final start = DateTime(day.year, day.month, day.day);
    final end = _isToday ? _now : start.add(const Duration(days: 1));
    final l = st?.latest;
    final has = st != null && st.measured > 0;
    return RCard(
      onTap: _snap != null || !_isToday ? null : () => go(c, const RitmStressScreen()),
      child: SizedBox(
        height: 228,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('МОНИТОР СТРЕССА', style: RT.cap),
                      const SizedBox(height: 2),
                      Text(
                        l != null
                            ? 'обновлено ${clock(DateTime.fromMillisecondsSinceEpoch(l.t * 1000).hour * 60 + DateTime.fromMillisecondsSinceEpoch(l.t * 1000).minute)}'
                            : (st != null && !st.calibrated
                                  ? 'калибровка ${st.calDays}/$kStressCalDays'
                                  : 'за день'),
                        style: RT.small,
                      ),
                    ],
                  ),
                ),
                Text(
                  l?.s == null ? '' : dec1(l!.s!),
                  style: RT.num.copyWith(color: RC.ink),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: has
                  ? StressDayChart(
                      day: st,
                      dayStart: start.millisecondsSinceEpoch ~/ 1000,
                      now: end.millisecondsSinceEpoch ~/ 1000,
                      height: 170,
                    )
                  : const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.activity, size: 24, color: RC.ink3),
                          SizedBox(height: 6),
                          Text('НЕТ ДАННЫХ', style: RT.cap),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// §2 п. 8: «Нагрузка и восстановление» за 7 дней (карточка 300).
  Widget _weekCard(BuildContext c) => RCard(
    child: SizedBox(
      height: 268,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('НАГРУЗКА И ВОССТАНОВЛЕНИЕ', style: RT.cap),
          const SizedBox(height: 2),
          const Text('7 дней', style: RT.small),
          const SizedBox(height: 10),
          Expanded(
            child: _week.every((w) => w.strain == null && w.recovery == null)
                ? const Center(child: Text('НЕТ ДАННЫХ', style: RT.cap))
                : WeekChart(days: _week, height: 220),
          ),
        ],
      ),
    ),
  );

  void _openHealth() {
    try {
      context.read<AppState>().navRequest.value = 2;
    } catch (_) {}
  }

  // ── Мой день ──
  Widget _myDay(BuildContext c, HomeData d) {
    final snap = _snap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyedSubtree(
          key: _myDayKey,
          child: RSection(
            'Мой день',
            addLabel: 'Добавить или начать тренировку',
            onAdd: snap != null ? () {} : () => _addSheet(c),
          ),
        ),
        const SizedBox(height: RS.cardGap),
        _activities(c, d),
        if (_isToday) ...[const SizedBox(height: RS.cardGap), _tonight(c, d)],
        const SizedBox(height: RS.sectionGap),
        KeyedSubtree(
          key: _metricsKey,
          child: RSection(
            'Мои показатели',
            trailing: RitmTuneButton(
              onTap: snap != null
                  ? () {}
                  : () async {
                      if (await showRitmMetricsTune(c) && mounted) {
                        setState(() {});
                      }
                    },
            ),
          ),
        ),
        const SizedBox(height: RS.cardGap),
        _metrics(c, d),
      ],
    );
  }

  void _addSheet(BuildContext c) {
    showRSheet<void>(
      c,
      (sc) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RButton(
            LucideIcons.plus,
            'Добавить тренировку',
            onTap: () {
              Navigator.of(sc).pop();
              go(c, const LogWorkout());
            },
          ),
          const SizedBox(height: RS.cardGap),
          RButton(
            LucideIcons.timer,
            'Начать тренировку',
            kind: RButtonKind.primary,
            onTap: () {
              Navigator.of(sc).pop();
              _start(c);
            },
          ),
        ],
      ),
    );
  }

  Widget _activities(BuildContext c, HomeData d) {
    final snap = _snap;
    final rows = <Widget>[];
    final hk = RitmWatchStore.data.value;
    final list = ritmDayWorkouts(
      _sessions,
      _watchDay,
      nameOf: (t) => activityByName(t)?.displayName(c) ?? 'Тренировка',
      iconOf: (t) => activityByName(t)?.icon ?? LucideIcons.activity,
      hk: hk,
    );
    for (final w in list) {
      final strain = w.strain;
      rows.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openWorkout(c, w),
          child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: strain == null ? RC.cardHi : RC.strain(strain),
                  borderRadius: BorderRadius.circular(RS.rTile),
                ),
                child: strain == null
                    ? Icon(w.icon, color: RC.ink, size: 20)
                    : Text(
                        dec1(strain),
                        style: RT.title.copyWith(
                          fontSize: 15,
                          color: const Color(0xFFFFFFFF),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RT.title,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        w.span,
                        if (w.watch?.distM != null)
                          distRu(w.watch!.distM!)
                        else
                          '${w.minutes} мин',
                        if (w.watch != null)
                          'Apple Watch'
                        else if (w.auto)
                          'найдена браслетом',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RT.small,
                    ),
                  ],
                ),
              ),
              const Icon(LucideIcons.chevronRight, size: 16, color: RC.ink3),
            ],
          ),
        ),
        ),
      );
    }
    final dismissed = RitmWkDismissed.all;
    final shown = !_isToday
        ? const <RitmSuggestion>[]
        : [
            for (final s in [..._suggestions, ..._soft])
              if (wkAction(
                    s.start,
                    s.end,
                    watch: _watchDay,
                    dismissed: s.soft ? dismissed : const {},
                  ) ==
                  WkAction.ask)
                s,
          ];
    final hidden = _isToday
        ? (_pending - _suggestions.length).clamp(0, 99)
        : 0;
    return RCard(
      onTap: snap != null || _sessions.isEmpty
          ? null
          : () => go(c, const DayStrainDetail()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RCardHead(
            _isToday ? 'Активности сегодня' : 'Активности за день',
            trailingWidget: Semantics(
              button: true,
              label: 'Все тренировки',
              excludeSemantics: true,
              child: InkResponse(
                onTap: snap != null
                    ? null
                    : () => go(
                        c,
                        const RitmPaged(
                          title: 'Тренировки',
                          child: WorkoutScreen(),
                        ),
                      ),
                radius: 20,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(LucideIcons.maximize2, size: 16, color: RC.ink3),
                ),
              ),
            ),
          ),
          if (!_isToday && rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('В этот день тренировок не было.', style: RT.small),
            ),
          ...rows,
          for (final s in shown)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _suggestionCard(c, s),
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: RButton(
                LucideIcons.listChecks,
                'Ещё $hidden на проверку',
                onTap: snap != null
                    ? () {}
                    : () => go(c, const DetectedActivitiesScreen()),
              ),
            ),
          if (_isToday) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: RButton(
                    LucideIcons.plus,
                    'Добавить',
                    height: 44,
                    onTap: snap != null
                        ? () {}
                        : () => go(c, const LogWorkout()),
                  ),
                ),
                const SizedBox(width: RS.cardGap),
                Expanded(
                  child: RButton(
                    LucideIcons.timer,
                    'Начать',
                    height: 44,
                    onTap: snap != null ? () {} : () => _start(c),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Тренировка дня: HRR (Watch, иначе по секундам браслета после финиша).
  Future<void> _openWorkout(BuildContext c, RitmDayWorkout w) async {
    var ww = w;
    if (w.hrr == null && _snap == null && w.bandAvgHr != null) {
      try {
        final end = w.end.millisecondsSinceEpoch ~/ 1000;
        final secs = await readWkSecs(end - 15, end + 80);
        final pts = [
          for (final x in secs)
            if (x.valid && x.hr != null)
              (DateTime.fromMillisecondsSinceEpoch(x.ts * 1000), x.hr!.toDouble()),
        ];
        final d = hrrFromSamples(w.end, pts);
        if (d != null) {
          ww = RitmDayWorkout(
            name: w.name,
            start: w.start,
            end: w.end,
            strain: w.strain,
            bandAvgHr: w.bandAvgHr,
            bandValidShare: w.bandValidShare,
            watch: w.watch,
            hrr: WorkoutHrr(d, 'браслет'),
            icon: w.icon,
            auto: w.auto,
          );
        }
      } catch (_) {}
    }
    if (c.mounted) unawaited(openRitmWorkout(c, ww));
  }

  /// Карточка авто-найденной тренировки (§6): «Это был бег?» + «Да, бег» /
  /// «Другой тип» / «Нет».
  Widget _suggestionCard(BuildContext c, RitmSuggestion s) {
    final k = s.kind;
    final span =
        '${clock(s.start.hour * 60 + s.start.minute)}–${clock(s.end.hour * 60 + s.end.minute)}';
    final hr = s.avgHr == null ? '' : ' (пульс в среднем ${s.avgHr})';
    final text =
        'Браслет заметил тренировку $span$hr. ${wkQuestion(k ?? WkType.other)}';
    final yes = k == null || k == WkType.other ? 'Да' : 'Да, ${wkTypeWord(k)}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RC.cardHi,
        borderRadius: BorderRadius.circular(RS.rTile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.activity, size: 20, color: RC.brandA),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: RT.body.copyWith(color: RC.ink)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 4,
                child: RButton(
                  null,
                  yes,
                  kind: RButtonKind.primary,
                  height: 40,
                  onTap: () => _answer(c, s, yes: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: RButton(
                  null,
                  'Другой тип',
                  kind: RButtonKind.ghost,
                  height: 40,
                  onTap: _snap != null
                      ? () {}
                      : () async {
                          final t = await showRitmWkTypePicker(c);
                          if (t != null && c.mounted) {
                            await _answer(c, s, yes: true, type: t);
                          }
                        },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: RButton(
                  null,
                  'Нет',
                  kind: RButtonKind.ghost,
                  height: 40,
                  onTap: () => _answer(c, s, yes: false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _answer(
    BuildContext c,
    RitmSuggestion s, {
    required bool yes,
    String? type,
  }) async {
    final raw = s.raw;
    final repo = repoOf(c);
    if (_snap != null || repo == null) return;
    final st = s.start.millisecondsSinceEpoch ~/ 1000;
    final en = s.end.millisecondsSinceEpoch ~/ 1000;
    try {
      if (s.soft) {
        if (yes) {
          await repo.logManualWorkout(
            startTs: st,
            endTs: en,
            type: type ?? s.sport ?? 'other',
          );
        } else {
          RitmWkDismissed.add(st);
        }
        setState(() => _soft = [for (final x in _soft) if (x != s) x]);
      } else if (raw != null) {
        if (yes) {
          await repo.confirmActivity(
            raw,
            workoutType: type ?? activityByName(raw.sport)?.typeKey ?? 'other',
          );
        } else {
          await repo.discardActivity(raw);
        }
      }
    } catch (_) {}
    if (mounted) await _load();
  }

  Future<void> _start(BuildContext c) async {
    final app = c.read<AppState>();
    final nav = Navigator.of(c);
    final history = await loadSetHistory();
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ActivityPicker(host: activityHost(app, history: history)),
      ),
    );
  }

  // ── План на вечер (B4¾, §7.4.2) ──
  /// Подъём — будильник (если включён), иначе как сегодня; потребность — на
  /// следующую ночь из колец; эффективность — медиана 14 ночей.
  TonightPlan? _plan(BuildContext c, HomeData d) {
    if (!_isToday) return null;
    DateTime? at;
    var armed = false;
    final snap = _snap;
    if (snap != null) {
      at = snap.alarmAt;
      armed = snap.alarmOn;
    } else if (alarmArmOfContext(c) case final (DateTime?, AlarmArmState) a) {
      at = a.$1;
      armed = a.$1 != null && a.$1!.isAfter(_now) && a.$2 != AlarmArmState.none;
    }
    final r = _rings;
    final w0 = r?.inputs.night.wakeTs;
    DateTime? wake;
    if (armed && at != null) {
      wake = at;
    } else if (w0 != null) {
      final w = DateTime.fromMillisecondsSinceEpoch(w0 * 1000);
      final n = _now;
      wake = DateTime(n.year, n.month, n.day + 1, w.hour, w.minute);
    }
    final need = r?.tonight?.need.round() ?? d.sleepNeedMin.value?.round();
    if (wake == null || need == null) return null;
    final eff = (r?.inputs.eff ?? _effPct ?? 90).round().clamp(60, 100);
    return (wake: wake, alarm: armed && at != null, need: need, eff: eff, latency: kRitmDemo ? 9 : 10);
  }

  int _bedMin(TonightPlan p) {
    final b = bedtimeFor(wake: p.wake, needMin: p.need, target: 1, effPct: p.eff, latencyMin: p.latency);
    return b.hour * 60 + b.minute;
  }

  int _awakeOf(TonightPlan p) => (p.need * 100 / p.eff).round() - p.need + p.latency;

  // ── Сегодня ночью ──
  Widget _tonight(BuildContext c, HomeData d) {
    final snap = _snap;
    DateTime? at;
    var armed = false;
    if (snap != null) {
      at = snap.alarmAt;
      armed = snap.alarmOn;
    } else if (alarmArmOfContext(c) case final (DateTime?, AlarmArmState) a) {
      at = a.$1;
      armed = a.$1 != null && a.$1!.isAfter(_now) && a.$2 != AlarmArmState.none;
    }
    // Один план на вечер (B4¾): тот же отбой на «Сне» и в тексте главной.
    final plan = _plan(c, d);
    final need = plan?.need ?? d.sleepNeedMin.value;
    final wake = at == null ? null : at.hour * 60 + at.minute;
    final awake = plan == null ? awakeForNeed(need, _effPct) : _awakeOf(plan);
    final bed = plan == null
        ? ritmBedtime(wakeMinOfDay: wake, needMin: need, awakeMin: awake) ?? d.bedtime.value?.round()
        : _bedMin(plan);
    Widget side(
      IconData icon,
      String value,
      String caption,
      Color capColor,
      String? sub,
    ) => Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: RC.ink2),
              const SizedBox(width: 6),
              Text(value, style: RT.num),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RT.cap.copyWith(color: capColor),
        ),
        const SizedBox(height: 2),
        Text(
          sub ?? ' ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RT.small,
        ),
      ],
    );
    return RCard(
      onTap: snap != null
          ? null
          : () => go(
              c,
              RitmSleepScreen(hero: _states(d).sleep, score: _rings?.sleepScore, needRes: _rings?.need,
                    plan: _d == null ? null : _plan(context, _d!),
                    debtHist: _rings?.debtHist ?? const [],
                    norms: _rings?.norms ?? const {}),
            ),
      child: Column(
        children: [
          const RCardHead('Сегодня ночью'),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: side(
                  LucideIcons.sunset,
                  bed == null ? '--:--' : clock(bed),
                  'ОТБОЙ',
                  RC.ink2,
                  need == null
                      ? null
                      : awake == null
                      ? 'потребность ${hmm(need)}'
                      : 'сон ${hmm(need)} + ${hmm(awake)} без сна',
                ),
              ),
              const SizedBox(
                width: 44,
                child: Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: RDashes(),
                ),
              ),
              Expanded(
                child: side(
                  LucideIcons.sunrise,
                  at == null ? '--:--' : clock(at.hour * 60 + at.minute),
                  armed ? 'БУДИЛЬНИК ВКЛ' : 'БУДИЛЬНИК ВЫКЛ',
                  armed ? RC.green : RC.yellow,
                  null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          RButton(
            LucideIcons.alarmClock,
            'Будильник',
            height: 44,
            onTap: snap != null ? () {} : () => go(c, const AlarmScreen()),
          ),
        ],
      ),
    );
  }

  /// Шаги браслета, а Watch тоже считал — показываем второе число рядом
  /// (сверка §10.10: разница в пределах ±5 % — норма).
  static String _stepsPair(String source, num? shown, double? watch) {
    if (source != 'браслет' || shown == null || watch == null || watch <= 0) {
      return source;
    }
    return 'браслет · Watch ${thousands(watch.round())}';
  }

  // ── Мои показатели ──
  Widget _metrics(BuildContext c, HomeData d) {
    final snap = _snap;
    final v =
        _mv ??
        RitmMetricValues(
          hrv: _hrv,
          rhr: d.rhr.value,
          steps: d.steps.value,
          kcal: d.caloriesTotal.value ?? d.calories.value,
        );
    final hk = RitmWatchStore.data.value;
    final steps = ritmSteps(
      watch: _isToday ? hk?.steps.watch : null,
      watchHours: hk?.steps.watchHours ?? 0,
      band: v.steps,
      now: _now,
      today: _isToday,
    );
    return RitmMetricsList(
      v: v.withWatch(
        vo2: hk?.vo2,
        watchKnown: hk?.any ?? false,
        steps: steps.value,
        stepsSource: steps.source.isEmpty
            ? v.stepsSource
            : _stepsPair(
                steps.source,
                steps.value,
                _isToday ? hk?.steps.watch : null,
              ),
      ),
      keys: RitmMetricsConfig.visible(),
      onTap: snap != null
          ? null
          : (k) {
              if (k == 'vo2') return;
              final w = switch (k) {
                'hrv' => const MetricDetail('hrv'),
                'rhr' => const MetricDetail('resting_hr'),
                'steps' => const MetricDetail('steps'),
                _ => const DayStrainDetail(),
              };
              go(c, w);
            },
    );
  }
}

/// Силовая тренировка (для строки «Силовые за неделю»).
bool isStrengthType(String? t) {
  if (t == null) return false;
  final s = t.toLowerCase();
  return s.contains('strength') ||
      s.contains('weight') ||
      s.contains('crossfit') ||
      s.contains('powerlift') ||
      s.contains('calisthen') ||
      s.contains('bodybuild');
}
