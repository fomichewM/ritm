// «Ритм» — экран «Источники и сверка» (ТЗ v2 §8.1).
//
// 1. Браслет: модель, подключение, заряд, когда была синхронизация.
// 2. Apple Watch через «Здоровье»: доступ, свежесть данных Watch,
//    переключатели чтения и записи по типам.
// 3. Сверка браслет / второе устройство — только дневные строки (ТЗ v3 D10).
// 4. Телефон: шаги телефона, когда браслет снят.
//
// B4½ (ТЗ v3 §9, MULTIDEVICE §7): карточка модели из HELLO (BandCaps),
// селектор «Второе устройство» с автоопределением по «Здоровью» (D3),
// предупреждение «в Здоровье пишет приложение WHOOP» (D4), сверка
// браслет / второе — две колонки, только дневные строки (D10), вход в
// «Сверку с WHOOP» (U8).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../health/auto_workout_import.dart' show AutoWorkoutImport;
import '../l10n/app_localizations.dart';
import '../notify/notification_prefs.dart' show NotificationPrefs;
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../ui2/screens/home_screen.dart' show HomeData, go, repoOf;
import '../ui2/profile/devices.dart' show MyDevices;
import 'ritm_demo.dart' show kRitmDemo, ritmDemoNow, ritmDemoSources, ritmDemoStep;
import 'ritm_devices.dart';
import 'ritm_hk.dart';
import 'ritm_stress.dart' show RitmStressStore;
import 'ritm_watch_store.dart';
import 'ritm_scores.dart';
import 'ritm_ui.dart';
import 'ritm_watch.dart';
import 'ritm_whoop_ui.dart';
import 'ritm_write_gate.dart';

/// Всё, что показывает экран (снимок — для демо и тестов).
class RitmSourcesData {
  final String model;
  final String? bandName;
  final bool paired, connected;
  final double? battery;
  final DateTime? lastSync;
  final bool healthAsked;
  final WatchNight watch;
  final num? bandRhr;
  final num? bandSleepMin;
  final bool readWorkouts;
  final bool writeOn;
  final bool phoneSteps;

  /// Отклонение температуры кожи браслета за ночь, °C.
  final double? bandTempDev;

  /// Тренировка браслета сегодня (для сверки пульса с Watch).
  final ({DateTime start, DateTime end, int avgHr, double validShare})?
  bandWorkout;

  /// Модель браслета (HELLO → ручной выбор → кэш), шаги браслета сегодня.
  final BandCaps caps;
  final num? bandSteps;
  const RitmSourcesData({
    this.caps = const BandCaps(),
    this.bandSteps,
    this.model = 'WHOOP',
    this.bandName,
    this.paired = false,
    this.connected = false,
    this.battery,
    this.lastSync,
    this.healthAsked = false,
    this.watch = const WatchNight(),
    this.bandRhr,
    this.bandSleepMin,
    this.readWorkouts = true,
    this.writeOn = false,
    this.phoneSteps = false,
    this.bandTempDev,
    this.bandWorkout,
  });

  RitmSourcesData copyWith({
    WatchNight? watch,
    num? bandRhr,
    num? bandSleepMin,
    bool? readWorkouts,
    double? bandTempDev,
    ({DateTime start, DateTime end, int avgHr, double validShare})?
    bandWorkout,
  }) => RitmSourcesData(
    caps: caps,
    bandSteps: bandSteps,
    model: model,
    bandName: bandName,
    paired: paired,
    connected: connected,
    battery: battery,
    lastSync: lastSync,
    healthAsked: healthAsked,
    watch: watch ?? this.watch,
    bandRhr: bandRhr ?? this.bandRhr,
    bandSleepMin: bandSleepMin ?? this.bandSleepMin,
    readWorkouts: readWorkouts ?? this.readWorkouts,
    writeOn: writeOn,
    phoneSteps: phoneSteps,
    bandTempDev: bandTempDev ?? this.bandTempDev,
    bandWorkout: bandWorkout ?? this.bandWorkout,
  );
}

/// «WHOOP 5.0 MG» / «WHOOP 5.0» / «WHOOP 4.0» — модель устройства (не бренд).
String bandModel({String? generation, bool maverick = false}) =>
    switch (generation) {
      'gen5' => maverick ? 'WHOOP 5.0 MG' : 'WHOOP 5.0',
      'gen4' => 'WHOOP 4.0',
      _ => maverick ? 'WHOOP MG' : 'WHOOP',
    };

/// «5 мин назад», «сегодня 07:12», «вчера 22:40», «14 окт 09:00».
String agoRu(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  final hm = clock(t.hour * 60 + t.minute);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final back = today.difference(day).inDays;
  if (back == 0) return 'сегодня $hm';
  if (back == 1) return 'вчера $hm';
  return '${shortDayRu(dayId(t)).split(', ').last} $hm';
}

String dayId(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

class RitmSourcesScreen extends StatefulWidget {
  final RitmSourcesData? data;
  final DateTime? now;

  /// Только демо-скриншоты: открыть сразу прокрученным вниз (к сверке).
  final bool demoScrollEnd;

  /// Только демо: доля прокрутки (0…1).
  final double? demoScrollTo;
  const RitmSourcesScreen({
    super.key,
    this.data,
    this.now,
    this.demoScrollEnd = false,
    this.demoScrollTo,
  });

  @override
  State<RitmSourcesScreen> createState() => _RitmSourcesScreenState();
}

class _RitmSourcesScreenState extends State<RitmSourcesScreen> {
  RitmSourcesData? _d;
  bool _loadingWatch = true;
  bool _syncing = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    RitmWatchStore.data.removeListener(_onWatch);
    _scroll.dispose();
    super.dispose();
  }

  DateTime get _now => widget.now ?? ritmDemoNow() ?? DateTime.now();
  int _typeCount = 0;
  String _whoopLine = '';

  /// D3/D4: кого «Здоровье» видит вторым устройством, пишет ли туда WHOOP.
  ({SecondDevice? suggest, bool whoopApp}) get _detect {
    if (_fixed != null && kRitmDemo) {
      return (suggest: SecondDevice.watch, whoopApp: ritmDemoStep.value == 69);
    }
    final w = RitmWatchStore.data.value;
    if (w == null) return (suggest: null, whoopApp: false);
    final probes = <SourceProbe>[
      for (final x in [...w.vo2Series, ...w.hrr])
        SourceProbe(bundle: x.src.bundle, product: x.src.product, model: x.src.model, name: x.src.name),
      for (final x in w.workouts)
        SourceProbe(bundle: x.src.bundle, product: x.src.product, model: x.src.model, name: x.src.name),
      for (final x in w.ecg)
        SourceProbe(bundle: x.src.bundle, product: x.src.product, model: x.src.model, name: x.src.name),
    ];
    return detectSecondDevice(probes);
  }

  SecondDevice get _secondNow =>
      RitmDevicePrefs.cached.second ?? _detect.suggest ?? SecondDevice.none;

  void _onWatch() {
    if (mounted) setState(() {});
  }
  RitmSourcesData? get _fixed => widget.data ?? ritmDemoSources();

  int? _batPct;

  @override
  void initState() {
    super.initState();
    unawaited(NotificationPrefs.load().then((p) {
      if (mounted) setState(() => _batPct = p.batteryAlertPct);
    }).catchError((_) {}));
    RitmWatchStore.data.addListener(_onWatch);
    unawaited(RitmWatchStore.load());
    unawaited(RitmDevicePrefs.load().then((_) {
      if (mounted) setState(() {});
    }));
    unawaited(whoopCompareLine().then((x) {
      if (mounted) setState(() => _whoopLine = x);
    }));
    unawaited(
      RitmHealthKitChannel.readTypeCount().then((n) {
        if (mounted) setState(() => _typeCount = n);
      }),
    );
    if (_fixed != null) {
      _d = _fixed;
      _loadingWatch = false;
      if (widget.demoScrollEnd || widget.demoScrollTo != null) {
        // Ждём данные канала, потом прокручиваем.
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted && _scroll.hasClients) {
            final max = _scroll.position.maxScrollExtent;
            _scroll.jumpTo(widget.demoScrollEnd ? max : max * widget.demoScrollTo!);
          }
        });
      }
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  RitmSourcesData _bandOnly(AppState? app, {RitmSourcesData? prev}) {
    final dev = app?.device;
    final ts = app?.lastSynced?.tsEpoch;
    final gen4 = app?.paired?.generation == 'gen4';
    final caps = gen4 && RitmDevicePrefs.hello.value == null
        ? const BandCaps(model: BandModel.whoop4, origin: 'cache')
        : RitmDevicePrefs.current(
            serial: app?.paired?.serial,
            pairedIsMaverick: app?.pairedIsMaverick ?? false,
          );
    return RitmSourcesData(
      caps: caps,
      bandSteps: prev?.bandSteps,
      model: bandModel(
        generation: app?.paired?.generation,
        maverick: app?.pairedIsMaverick ?? false,
      ),
      bandName: dev?.strapName,
      paired: app?.isPaired ?? false,
      connected: app?.isConnected ?? false,
      battery: dev?.batteryPct,
      lastSync: ts == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ts * 1000),
      healthAsked: RitmWatchReader.asked || RitmWatchStore.asked,
      watch: prev?.watch ?? const WatchNight(),
      bandRhr: prev?.bandRhr,
      bandSleepMin: prev?.bandSleepMin,
      bandTempDev: prev?.bandTempDev,
      bandWorkout: prev?.bandWorkout,
      readWorkouts: prev?.readWorkouts ?? true,
      writeOn: app?.healthSyncEnabled ?? false,
      phoneSteps: app?.phoneStepsEnabled ?? false,
    );
  }

  Future<void> _load() async {
    AppState? app;
    try {
      app = context.read<AppState>();
    } catch (_) {}
    setState(() => _d = _bandOnly(app, prev: _d));
    num? rhr, sleep, steps;
    double? tempDev;
    ({DateTime start, DateTime end, int avgHr, double validShare})? bw;
    final repo = repoOf(context);
    final l10n = AppLocalizations.of(context);
    await RitmDevicePrefs.load();
    if (repo != null) {
      try {
        final d = await HomeData.load(repo, l10n);
        rhr = d.rhr.value;
        sleep = d.sleepMin.value;
        steps = d.steps.value;
      } catch (_) {}
      try {
        final t = await repo.getToday();
        final st = t['skin_temp'];
        if (st is Map) tempDev = (st['dev_c'] as num?)?.toDouble();
      } catch (_) {}
      bw = await _bandWorkoutToday(repo);
    }
    final readW = await AutoWorkoutImport.isEnabled();
    final watch = RitmWatchReader.asked
        ? await RitmWatchReader().lastNight(now: _now)
        : const WatchNight();
    if (!mounted) return;
    setState(() {
      final b = _bandOnly(app, prev: _d);
      _d = RitmSourcesData(
        caps: b.caps,
        bandSteps: steps,
        model: b.model,
        bandName: b.bandName,
        paired: b.paired,
        connected: b.connected,
        battery: b.battery,
        lastSync: b.lastSync,
        healthAsked: b.healthAsked,
        watch: watch,
        bandRhr: rhr,
        bandSleepMin: sleep,
        bandTempDev: tempDev,
        bandWorkout: bw,
        readWorkouts: readW,
        writeOn: b.writeOn,
        phoneSteps: b.phoneSteps,
      );
      _loadingWatch = false;
    });
  }

  Future<void> _sync() async {
    if (_fixed != null) return;
    setState(() => _syncing = true);
    try {
      await context.read<AppState>().syncNow().timeout(
        const Duration(seconds: 90),
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _syncing = false);
    await _load();
  }

  /// Последняя тренировка браслета сегодня, пересекающаяся с Watch: средний
  /// пульс и доля секунд с валидным пульсом (для сверки §10.9).
  Future<({DateTime start, DateTime end, int avgHr, double validShare})?>
  _bandWorkoutToday(dynamic repo) async {
    final watch = RitmWatchStore.data.value?.workouts ?? const <HkWorkout>[];
    if (watch.isEmpty) return null;
    final n = _now;
    final from = DateTime(n.year, n.month, n.day);
    try {
      final ss = await repo.getSessions(
        from: from.millisecondsSinceEpoch ~/ 1000,
        to: from.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
        includeDetected: false,
      ) as List;
      for (final m in ss.reversed) {
        final st = (m['start_ts'] as num?)?.toInt();
        final en = (m['end_ts'] as num?)?.toInt() ??
            (st == null ? null : st + ((m['duration_min'] as num?) ?? 0).toInt() * 60);
        final hr = (m['avg_hr'] as num?)?.round();
        if (st == null || en == null || hr == null || en <= st) continue;
        final s = DateTime.fromMillisecondsSinceEpoch(st * 1000);
        final e = DateTime.fromMillisecondsSinceEpoch(en * 1000);
        if (watchMatch(s, e, watch) == null) continue;
        final (secs, _) = await RitmStressStore.read(st, en);
        final valid = secs.where((x) => x.hrValid && x.hr != null).length;
        return (start: s, end: e, avgHr: hr, validShare: valid / (en - st));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _ask() async {
    if (_fixed != null) return;
    await RitmWatchReader().requestAccess();
    await RitmWatchStore.requestAccess();
    await _load();
  }

  @override
  Widget build(BuildContext c) {
    final d = _d ?? const RitmSourcesData();
    return RPage(
      controller: _scroll,
      title: 'Источники и сверка',
      children: [
        // D4: предупреждение — первым, до карточек устройств.
        if (_detect.whoopApp) ...[
          _whoopAppWarning(),
          const SizedBox(height: RS.cardGap),
        ],
        _band(c, d),
        const SizedBox(height: RS.cardGap),
        _second(c, d),
        const SizedBox(height: RS.cardGap),
        _watch(c, d),
        const SizedBox(height: RS.cardGap),
        _reconcile(c, d),
        const SizedBox(height: RS.cardGap),
        _whoopRow(c),
        const SizedBox(height: RS.cardGap),
        _phone(c, d),
      ],
    );
  }

  // 1. Браслет
  Widget _band(BuildContext c, RitmSourcesData d) {
    final status = !d.paired
        ? 'не подключён'
        : d.connected
        ? 'подключён'
        : 'нет связи';
    final parts = [
      status,
      if (d.battery != null) pct(d.battery!),
      if (d.lastSync != null) 'синхронизация ${agoRu(d.lastSync!, _now)}',
    ];
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Браслет', trailing: null),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: RC.cardHi,
                  borderRadius: BorderRadius.circular(RS.rTile),
                ),
                child: Icon(
                  LucideIcons.watch,
                  size: 22,
                  color: d.connected ? RC.green : RC.ink3,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.caps.known ? d.caps.line : d.model, style: RT.title),
                    const SizedBox(height: 2),
                    Text(parts.join(' · '), style: RT.small),
                    if (d.caps.known) ...[
                      const SizedBox(height: 2),
                      Text(
                        // Порог — тот же, что в «Уведомлениях» (настройка), а не константа модели.
                        '${d.caps.can} · батарея ${d.caps.batteryDays} · напомним при ${_batPct ?? NotificationPrefs.batteryPctDefault}\u00a0%'
                        '${d.caps.origin == 'cache' ? ' · по прошлому подключению' : ''}',
                        style: RT.small,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: RButton(
                  LucideIcons.refreshCw,
                  _syncing ? 'Синхронизирую…' : 'Синхронизировать',
                  height: 44,
                  onTap: _syncing || !d.paired ? null : _sync,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RButton(
                  LucideIcons.bluetooth,
                  d.paired ? 'Переподключить' : 'Подключить',
                  height: 44,
                  onTap: _fixed != null
                      ? () {}
                      : () => go(c, const MyDevices()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 2. Apple Watch через Здоровье
  Widget _watch(BuildContext c, RitmSourcesData d) {
    final hk = RitmWatchStore.data.value;
    final w = hk != null ? WatchNight.of(hk) : d.watch;
    final types = _typeCount > 0
        ? ' · чтение $_typeCount ${plural(_typeCount, 'типа', 'типов', 'типов')}'
        : '';
    final access = !d.healthAsked
        ? 'Доступ к Здоровью не запрошен'
        : w.any
        ? 'Доступ выдан$types'
        : 'Доступ запрошен · данных Watch нет';
    final fresh = w.lastSample == null
        ? (_loadingWatch ? 'Читаю Здоровье…' : 'Последние данные Watch: нет')
        : 'Последние данные Watch: ${agoRu(w.lastSample!, _now)}';
    final legacy = d.writeOn;
    bool wr(RitmWriteKind k) => d.writeOn && RitmWriteGate.allows(k);
    final watchOn = RitmWatchStore.watchPresent || (hk?.any ?? false);
    Widget write(RitmWriteKind k, String title, String sub) => RRow(
      title: title,
      sub: k == RitmWriteKind.energy && watchOn
          ? 'Выключено: есть Apple Watch — иначе кольца Активности удвоятся'
          : sub,
      trailing: RSwitch(
        value: wr(k) && !(k == RitmWriteKind.energy && watchOn),
        onChanged: _fixed != null || (k == RitmWriteKind.energy && watchOn)
            ? (_) {}
            : (v) async {
                final app = context.read<AppState>();
                // Первое касание: остальные типы — как шли до сих пор.
                RitmWriteGate.set(k, v, legacyAll: legacy);
                final any = RitmWriteGate.any;
                if (any != app.healthSyncEnabled) {
                  await app.setHealthSync(any);
                }
                if (mounted) setState(() => _d = _bandOnly(app, prev: _d));
              },
      ),
    );
    Widget read(String title, String sub, bool on, ValueChanged<bool> set) =>
        RRow(
          title: title,
          sub: sub,
          trailing: RSwitch(
            value: on,
            onChanged: _fixed != null ? (_) {} : set,
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Apple Watch через Здоровье', trailing: null),
              const SizedBox(height: 12),
              Row(
                children: [
                  RDot(
                    w.any
                        ? RC.green
                        : d.healthAsked
                        ? RC.yellow
                        : RC.ink3,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(access, style: RT.body.copyWith(color: RC.ink)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(fresh, style: RT.small),
              ),
              if (!w.any) ...[
                const SizedBox(height: 12),
                RButton(
                  LucideIcons.heartHandshake,
                  d.healthAsked ? 'Запросить доступ снова' : 'Выдать доступ',
                  height: 44,
                  onTap: _ask,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: RS.cardGap),
        RGroup(
          title: 'Читать из Здоровья',
          rows: [
            read(
              'Тренировки',
              'Тренировки Watch сами появляются в «Мой день»',
              d.readWorkouts && RitmWatchStore.reads('workouts'),
              (v) async {
                await AutoWorkoutImport.setEnabled(v);
                if (v) unawaited(AutoWorkoutImport.maybeRun());
                await RitmWatchStore.setRead('workouts', v);
                await _load();
              },
            ),
            for (final e in const [
              ('vo2', 'В «Кардиоформе» и «Моих показателях»'),
              ('spo2', 'Строка в «Мониторе здоровья»'),
              ('temp', 'Для сверки с браслетом'),
              ('ecg', 'В списке ЭКГ рядом с браслетом'),
              ('steps', 'Когда часы носились весь день'),
            ])
              read(
                kRitmReadKinds[e.$1]!,
                e.$2,
                RitmWatchStore.reads(e.$1),
                (v) async {
                  await RitmWatchStore.setRead(e.$1, v);
                  if (mounted) setState(() {});
                },
              ),
            read(
              'Сон',
              'Для сверки с браслетом',
              RitmWatchReader.readSleep && RitmWatchStore.reads('sleep'),
              (v) {
                setState(() {});
                _setPref(RitmWatchReader.readSleepKey, v);
                unawaited(RitmWatchStore.setRead('sleep', v));
              },
            ),
            read(
              'Пульс покоя',
              'Для сверки с браслетом',
              RitmWatchReader.readRhr && RitmWatchStore.reads('rhr'),
              (v) {
                setState(() {});
                _setPref(RitmWatchReader.readRhrKey, v);
                unawaited(RitmWatchStore.setRead('rhr', v));
              },
            ),
          ],
        ),
        const SizedBox(height: RS.cardGap),
        RGroup(
          title: 'Записывать в Здоровье',
          rows: [
            write(
              RitmWriteKind.sleep,
              'Сон со стадиями',
              'Включайте, если Ритм — ваш источник сна; иначе в Здоровье будет два сна',
            ),
            write(RitmWriteKind.rhr, 'Пульс покоя', 'Одна запись за ночь'),
            write(RitmWriteKind.hrv, 'ВСР за ночь', 'Одна запись за ночь'),
            write(RitmWriteKind.resp, 'Дыхание', 'Одна запись за ночь'),
            write(
              RitmWriteKind.workouts,
              'Тренировки',
              'Только те, которых нет от Watch',
            ),
            write(
              RitmWriteKind.hr,
              'Непрерывный пульс',
              'Здоровье покажет источник с высшим приоритетом',
            ),
            write(
              RitmWriteKind.energy,
              'Калории',
              'Выключите, если есть Watch, — иначе кольца Активности удвоятся',
            ),
          ],
        ),
      ],
    );
  }

  void _setPref(String key, bool v) {
    Prefs.setBool(key, v);
    unawaited(_load());
  }

  // 3. Сверка
  // 2б. Второе устройство (D3): три плитки «даёт / не даёт».
  Widget _second(BuildContext c, RitmSourcesData d) {
    final cur = _secondNow;
    final det = _detect.suggest;
    final chosen = RitmDevicePrefs.cached.second;
    Widget tile(SecondDevice x, IconData icon) {
      final on = x == cur;
      final (give, no) = secondDeviceGives(x);
      return GestureDetector(
        onTap: _fixed != null
            ? null
            : () async {
                await RitmDevicePrefs.cached.withSecond(x).save();
                if (mounted) setState(() {});
              },
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: on ? RC.cardHi : const Color(0x00000000),
            borderRadius: BorderRadius.circular(RS.rTile),
            border: Border.all(color: on ? RC.brandA : RC.line, width: on ? 1.5 : 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: on ? RC.brandA : RC.ink3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(secondDeviceName(x), style: RT.body.copyWith(color: RC.ink, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('Даёт: $give', style: RT.small),
                    Text('Не даёт: $no', style: RT.small),
                  ],
                ),
              ),
              if (on) const Icon(LucideIcons.check, size: 18, color: RC.brandA),
            ],
          ),
        ),
      );
    }

    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Второе устройство', trailing: null),
          const SizedBox(height: 4),
          Text(
            chosen == null && det != null
                ? 'Нашли ${secondDeviceName(det)} в «Здоровье» — выбрано автоматически. Ночь всегда считает браслет.'
                : 'Днём точнее то, что ближе к сердцу на тренировке; ночь всегда считает браслет.',
            style: RT.small,
          ),
          tile(SecondDevice.none, LucideIcons.circleSlash),
          tile(SecondDevice.watch, LucideIcons.watch),
          tile(SecondDevice.garmin, LucideIcons.mountain),
        ],
      ),
    );
  }

  // D4: в «Здоровье» пишет приложение WHOOP.
  Widget _whoopAppWarning() => const RCard(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: EdgeInsets.only(top: 2), child: Icon(LucideIcons.triangleAlert, size: 20, color: RC.yellow)),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            'В «Здоровье» пишет приложение WHOOP. Если открыть его с браслетом рядом, оно может обновить прошивку — '
            'и «Ритм» потеряет связь до нашего обновления. Держите приложение WHOOP закрытым.',
            style: RT.body,
          ),
        ),
      ],
    ),
  );

  // 3. Сверка браслет / второе устройство: две колонки, только дневные строки.
  Widget _reconcile(BuildContext c, RitmSourcesData d) {
    final hk = RitmWatchStore.data.value;
    final second = _secondNow;
    final name2 = second == SecondDevice.garmin ? 'Garmin' : 'Watch';
    final rows = <Widget>[];
    Widget line(String name, String a, String b, String delta, Color dot, {String? note}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: RC.line))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(flex: 5, child: Text(name, style: RT.body.copyWith(color: RC.ink))),
              Expanded(flex: 3, child: Text(a, textAlign: TextAlign.right, style: RT.body.copyWith(color: RC.ink))),
              Expanded(flex: 3, child: Text(b, textAlign: TextAlign.right, style: RT.body.copyWith(color: RC.ink))),
              SizedBox(
                width: 64,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [Text(delta, style: RT.small), const SizedBox(width: 6), RDot(dot)],
                ),
              ),
            ],
          ),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(note, style: RT.micro)),
        ],
      ),
    );
    final bw = d.bandWorkout;
    final ww = bw == null ? null : watchMatch(bw.start, bw.end, hk?.workouts ?? const []);
    if (bw != null && ww != null && ww.hrAvg != null) {
      final win = workoutHrWinner(
        bandShare: bw.validShare,
        watchN: ww.hrN,
        seconds: bw.end.difference(bw.start).inSeconds,
      );
      final diff = bw.avgHr - ww.hrAvg!;
      rows.add(
        line(
          'Пульс тренировки ${clock(bw.start.hour * 60 + bw.start.minute)}',
          '${bw.avgHr}',
          '${ww.hrAvg!.round()}',
          signed(diff.round()),
          diff.abs() <= 5 ? RC.green : (diff.abs() <= 10 ? RC.yellow : RC.red),
          note: win.winner == 'браслет'
              ? 'в Нагрузку идёт браслет — больше секунд с пульсом'
              : 'в Нагрузку идёт $name2 — больше секунд с пульсом',
        ),
      );
    }
    final ws = hk?.steps.watch;
    if (d.bandSteps != null && ws != null && ws > 0) {
      final rel = (d.bandSteps! - ws) / ws;
      rows.add(
        line(
          'Шаги',
          thousands(d.bandSteps!),
          thousands(ws),
          '${rel >= 0 ? '+' : '−'}${(rel.abs() * 100).round()} %',
          rel.abs() <= .10 ? RC.green : (rel.abs() <= .25 ? RC.yellow : RC.red),
          note: 'в день — один источник: $name2, если он на руке ≥ 12 ч, иначе браслет; не складываем',
        ),
      );
    }
    // D10: пульс покоя — справочно (в Восстановление идёт только браслет ночью).
    final wn = hk != null ? WatchNight.of(hk) : d.watch;
    if (d.bandRhr != null && wn.rhr != null) {
      final diff = (d.bandRhr! - wn.rhr!).round();
      final a = diff.abs();
      rows.add(
        line(
          'Пульс покоя',
          '${d.bandRhr!.round()}',
          '${wn.rhr!.round()}',
          '${diff > 0 ? '+' : (diff < 0 ? '−' : '')}$a',
          a <= 3 ? RC.green : (a <= 6 ? RC.yellow : RC.red),
          note: a > 6
              ? 'справочно; разница больше 6 — проверьте посадку браслета'
              : 'справочно: в Восстановление идёт браслет за сон',
        ),
      );
    }
    final hrr = hk?.hrr.isNotEmpty == true ? hk!.hrr.last.v.round() : null;
    if (hrr != null) {
      rows.add(
        line('Восстановление пульса за 1 мин', '—', '$hrr', '', RC.ink3, note: 'считает $name2 после тренировки; браслет — справочно'),
      );
    }
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RCardHead('Сверка браслет / $name2', trailing: null),
          const SizedBox(height: 4),
          const Text('Только дневные строки: ночью считает браслет, часы для сна не нужны.', style: RT.small),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                !d.healthAsked
                    ? 'Выдайте доступ к Здоровью — после тренировки в часах здесь будут обе цифры.'
                    : 'Сегодня не было тренировки в часах вместе с браслетом.',
                style: RT.body,
              ),
            )
          else ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(flex: 5, child: SizedBox()),
                const Expanded(flex: 3, child: Text('БРАСЛЕТ', textAlign: TextAlign.right, style: RT.micro)),
                Expanded(flex: 3, child: Text(name2.toUpperCase(), textAlign: TextAlign.right, style: RT.micro)),
                const SizedBox(width: 64, child: Text('Δ', textAlign: TextAlign.right, style: RT.micro)),
              ],
            ),
            const SizedBox(height: 6),
            ...rows,
            const SizedBox(height: 6),
            const Text('Пульс ±5 — совпадают, 6–10 — расходятся, больше 10 — проверьте посадку. Шаги ±10 %.', style: RT.small),
          ],
        ],
      ),
    );
  }

  // Сверка с WHOOP (U8).
  Widget _whoopRow(BuildContext c) => RGroup(
    rows: [
      RRow(
        icon: LucideIcons.scale,
        title: 'Сверка с WHOOP',
        sub: _whoopLine.isEmpty ? 'Экспорт WHOOP → таблица по дням' : _whoopLine,
        onTap: () {
          final demo = ritmDemoWhoopCompare();
          go(
            c,
            demo != null
                ? RitmWhoopCompareScreen(whoop: demo.w, ours: demo.ours, importedAt: _now, sample: true)
                : const RitmWhoopCompareScreen(),
          );
        },
      ),
    ],
  );

  // 4. Телефон
  Widget _phone(BuildContext c, RitmSourcesData d) => RGroup(
    title: 'Телефон',
    rows: [
      RRow(
        icon: LucideIcons.smartphone,
        title: 'Шаги телефона',
        sub: 'Используются, когда браслет снят',
        trailing: RSwitch(
          value: d.phoneSteps,
          onChanged: _fixed != null
              ? (_) {}
              : (v) async {
                  final app = context.read<AppState>();
                  if (v) {
                    await app.requestPhoneSteps();
                  } else {
                    await app.disablePhoneSteps();
                  }
                  await _load();
                },
        ),
      ),
    ],
  );
}
