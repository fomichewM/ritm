// «Ритм» B2: экраны показателей, Монитор стресса и здоровья, «Мои
// показатели» — без переполнений на 320 и 393 pt, без латиницы, с составом
// по ТЗ v2 §2 п. 4–8, §3, §4.3, §5.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ritm/ritm_charts.dart';
import 'package:openstrap_edge/ritm/ritm_detail.dart';
import 'package:openstrap_edge/ritm/ritm_home.dart';
import 'package:openstrap_edge/ritm/ritm_metrics.dart';
import 'package:openstrap_edge/ritm/ritm_night.dart';
import 'package:openstrap_edge/ritm/ritm_rings.dart' show TV;
import 'package:openstrap_edge/ritm/ritm_sleep.dart';
import 'package:openstrap_edge/ritm/ritm_seed.dart';
import 'package:openstrap_edge/ritm/ritm_stress.dart';
import 'package:openstrap_edge/ritm/ritm_ui.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart' show HealthData;
import 'package:openstrap_edge/ui2/screens/home_screen.dart'
    show ChartPoint, HomeData;
import 'package:openstrap_edge/ui2/theme.dart' show buildTheme;

final _today = DateTime.now();
final _now = DateTime(_today.year, _today.month, _today.day, 9, 41);
String _id(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Metric _m(num v) => Metric(value: v, confidence: .9, tier: MetricTier.high);
Map<String, dynamic> _env(num v) => {'value': v, 'confidence': .9, 'tier': 'HIGH'};

List<ChartPoint> _series(double base, double amp, int n) => [
  for (var i = n - 1; i >= 0; i--)
    (
      t: DateTime(_now.year, _now.month, _now.day - i, 12).millisecondsSinceEpoch ~/ 1000,
      v: base + amp * ((i * 7 % 11) - 5) / 5,
    ),
];

HealthData _health(int nights) => HealthData(
  today: {
    'daily': {'resting_hr': _env(51)},
    'hrv': {'rmssd': 58, 'confidence': .9, 'tier': 'HIGH'},
    'resp': _env(14.2),
    'skin_temp': {'value': .3, 'dev_c': .2, 'confidence': .8, 'tier': 'RELATIVE'},
  },
  charts: {
    'resting_hr': _series(52, 2, nights),
    'hrv': _series(50, 6, nights),
    'resp_rate': _series(14.2, .5, nights),
    'skin_temp_dev_c': _series(0, .15, nights),
  },
  daysWithData: nights,
);

StressDay _stress({bool calibrated = true}) {
  final start = DateTime(_now.year, _now.month, _now.day).millisecondsSinceEpoch ~/ 1000;
  final pts = <StressPoint>[
    for (var t = start + 300; t < start + 7 * 3600; t += 60) StressPoint(t, null, StressGap.sleep),
    for (var t = start + 7 * 3600; t < start + 8 * 3600; t += 60) StressPoint(t, null, StressGap.workout),
    for (var t = start + 8 * 3600; t <= start + 9 * 3600 + 40 * 60; t += 60)
      StressPoint(t, 1.2 + ((t ~/ 60) % 5) / 10, StressGap.none),
  ];
  final last = StressPoint(pts.last.t, 1.4, StressGap.none);
  pts[pts.length - 1] = last;
  return StressDay(points: pts, latest: last, calDays: calibrated ? 7 : 4);
}

const _gSleep = GaugeState(frac: .92, color: RC.green, value: '92%', inner: '7:32');

List<String> _latin(WidgetTester t) => [
  for (final w in t.widgetList<Text>(find.byType(Text)))
    if (RegExp(r'[A-Za-z]{3,}').hasMatch(
      (w.data ?? w.textSpan?.toPlainText() ?? '').replaceAll(
        RegExp(r'WHOOP|Apple Watch|Watch|MG|SpO₂|VO₂max|CSV', caseSensitive: false),
        '',
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
];

Future<void> _pump(WidgetTester t, Widget w, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.dark),
      home: w,
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _scrollAll(WidgetTester t) async {
  final l = find.byType(Scrollable);
  if (l.evaluate().isEmpty) return;
  for (var i = 0; i < 8; i++) {
    await t.drag(l.first, const Offset(0, -500));
    await t.pump(const Duration(milliseconds: 50));
    expect(t.takeException(), isNull);
  }
}

void main() {
  for (final (w, size) in const [(320, Size(320, 700)), (393, Size(393, 852))]) {
    testWidgets('Сон: герой Ø140, стадии, потребность, качество, сверка ($w pt)', (t) async {
      await _pump(
        t,
        const RitmSleepScreen(
          hero: _gSleep,
          data: RitmSleepView(
            tst: 452, need: 489, awake: 31, light: 236, deep: 98, rem: 118,
            inBed: 483, effPct: 94, wakes: 3, latency: 9, debt: 15, strainAdd: 10,
            watchMin: 441,
          ),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('Стадии'.toUpperCase()), findsOneWidget);
      expect(find.text('= база 7:44 + долг 0:15 + нагрузка 0:10'), findsOneWidget);
      expect(find.byWidgetPredicate((x) => x is RitmGauge && x.size == 140), findsOneWidget);
      await _scrollAll(t);
      expect(find.textContaining('Watch 7:21 · совпадают'), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Восстановление: факторы, коридор ВСР, как считается ($w pt)', (t) async {
      await _pump(
        t,
        RitmRecoveryScreen(
          hero: const GaugeState(frac: .78, color: RC.green, value: '78%', inner: 'Готов'),
          data: _health(30),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('ВСР'), findsOneWidget);
      expect(find.textContaining('обычно'), findsWidgets);
      await _scrollAll(t);
      expect(find.text('Как считается'.toUpperCase()), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Нагрузка: кривая, тренировки, зоны, калории ±25% ($w pt)', (t) async {
      final s = _now.millisecondsSinceEpoch ~/ 1000;
      await _pump(
        t,
        RitmStrainScreen(
          hero: const GaugeState(frac: .45, color: RC.strain1, value: '9,4', inner: 'Лёгкая'),
          sub: 'Лёгкая · цель 14–18',
          data: RitmStrainView(
            curve: [(t: s - 7200, v: 3), (t: s - 3600, v: 9.4)],
            sessions: const [(name: 'Бег', time: '07:40–08:26 · 46 мин', strain: 8.1)],
            zones: const [62, 38, 24, 14, 3],
            kcal: 1180,
          ),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('Лёгкая · цель 14–18'), findsOneWidget);
      await _scrollAll(t);
      expect(find.text('ккал ±25%'), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Монитор стресса: число, график, «Подышать», ВСР до/после ($w pt)', (t) async {
      await _pump(
        t,
        RitmStressScreen(
          data: _stress(),
          breath: (pre: 41, post: 55, at: DateTime(_now.year, _now.month, _now.day, 9, 12)),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('1,4'), findsOneWidget);
      expect(find.text('Средний'), findsOneWidget);
      expect(find.byType(StressDayChart), findsOneWidget);
      expect(find.text('ПОДЫШАТЬ 3 МИН'), findsOneWidget);
      await _scrollAll(t);
      expect(find.text('ВСР до 41 → после 55 мс'), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Монитор здоровья подробно: 5 строк, графики 30 дней ($w pt)', (t) async {
      await _pump(t, RitmMonitorScreen(data: _health(30), seed: const RitmSeed()), size);
      expect(t.takeException(), isNull);
      expect(find.text('В норме · 4 из 4'), findsOneWidget);
      expect(find.byType(CorridorChart), findsWidgets);
      await _scrollAll(t);
      expect(find.text('SpO₂ ночью'), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Главная B2: плитки мониторов, Мои показатели, графики 2.7–2.8 ($w pt)', (t) async {
      final d = HomeData(
        name: 'Михаил',
        dayId: _id(_now),
        readiness: _m(62.05),
        sleepMin: _m(452),
        sleepNeedMin: _m(489),
        rhr: _m(51),
        steps: _m(7480),
        caloriesTotal: _m(1180),
        strain: _m(9.4),
        illnessState: 'green',
      );
      await _pump(
        t,
        Scaffold(
          body: RitmHomeScreen(
            now: _now,
            snapshot: RitmHomeSnapshot(
              d: d,
              days: [_id(_now)],
              battery: (pct: 87, charging: false),
              stress: _stress(),
              health: _health(30),
              week: [
                for (var i = 6; i >= 0; i--)
                  WeekDayPoint(
                    DateTime(_now.year, _now.month, _now.day - i),
                    strain: 4.0 + i,
                    recovery: 30.0 + i * 10,
                  ),
              ],
              metrics: const RitmMetricValues(
                hrv: 58, hrvNorm: 50, rhr: 51, rhrMean30: 52.3, steps: 7480,
                kcal: 1180, z13: 130, z45: 35, strength: 58,
              ),
            ),
          ),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      // B4½: над плитками — коридор Нагрузки и таймлайн пульса.
      await t.scrollUntilVisible(
        find.text('В норме · 4 из 4'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('В норме · 4 из 4'), findsOneWidget);
      expect(find.text('Средний · 1,4'), findsOneWidget);
      await t.scrollUntilVisible(
        find.text('Зоны 1–3 за неделю'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('НАСТРОИТЬ'), findsOneWidget);
      expect(find.text('2:10'), findsOneWidget);
      expect(find.text('мс · обычно 50'), findsOneWidget);
      await _scrollAll(t);
      expect(find.byType(StressDayChart), findsOneWidget);
      expect(find.byType(WeekChart), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });
  }

  test('Мои показатели: порядок и выключенные строки сохраняются', () {
    expect(RitmMetricsConfig.visible(), kRitmMetricKeys);
    const v = RitmMetricValues(rhr: 50, rhrMean30: 52.4, z13: 130);
    expect(v.cell('rhr').$2, '−2 к 30 дн.');
    expect(v.cell('z13').$1, '2:10');
    expect(v.cell('kcal').$1, '—');
  });

  testWidgets('Плитка стресса в калибровке — «Калибровка · 4/7»', (t) async {
    expect(stressTileText(_stress(calibrated: false)), 'Калибровка · 4/7');
  });

  // ── B4¾ «Сон» v2 и «Ночь» ──
  for (final (w, size) in const [(320, Size(320, 700)), (393, Size(393, 852))]) {
    testWidgets('Сон v2: окно, 4 составляющие, «Сегодня ночью» ($w pt)', (t) async {
      final t0 = DateTime(2026, 10, 16);
      await _pump(
        t,
        RitmSleepScreen(
          hero: _gSleep,
          data: RitmSleepView(
            tst: 452, need: 489, awake: 31, light: 236, deep: 98, rem: 118,
            inBed: 483, effPct: 94, wakes: 3, wakesShort: 4, latency: 9, debt: 15, strainAdd: 10,
            onset: t0.subtract(const Duration(hours: 1)),
            wake: t0.add(const Duration(hours: 7, minutes: 3)),
            score: const SleepScore(88.96, 92.4, 81, 94, 92.5),
            stagesConf: 'med',
            tonightNeed: 486,
            tonightWake: t0.add(const Duration(days: 1, hours: 7, minutes: 3)),
          ),
          debtHist: const [10, 20, 67],
          norms: const {'deep': 92},
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('Отбой 23:00 → подъём 07:03'), findsOneWidget);
      expect(find.text('Из чего 89\u00a0%'.toUpperCase()), findsOneWidget);
      for (final n in ['Достаточность', 'Регулярность', 'Эффективность', 'Ночной стресс']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      await t.scrollUntilVisible(find.text('оценка'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('оценка'), findsOneWidget);
      await t.scrollUntilVisible(find.text('Разобрать ночь'.toUpperCase()), 100, scrollable: find.byType(Scrollable).first);
      await t.scrollUntilVisible(find.text('обычно 1:32'), 100, scrollable: find.byType(Scrollable).first);
      expect(find.text('обычно 1:32'), findsOneWidget);
      // 486 мин · 100 % / 0,94 + 9 мин засыпания = 526 мин до 07:03 → 22:17.
      await t.scrollUntilVisible(find.text('22:17'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('22:17'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const Key('sleep-debt14')), 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Сейчас 1:07.'), findsOneWidget);
      await _scrollAll(t);
      expect(find.text('+ 4 коротких'), findsOneWidget);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Ночь: гипнограмма + 4 кривые на общей оси, листается ($w pt)', (t) async {
      final t0 = DateTime(2026, 10, 15, 23).millisecondsSinceEpoch ~/ 1000;
      final runs = <StageRun>[
        (from: t0, to: t0 + 600, stage: Stage.wake),
        (from: t0 + 600, to: t0 + 7200, stage: Stage.deep),
        (from: t0 + 7200, to: t0 + 7800, stage: Stage.wake),
        (from: t0 + 7800, to: t0 + 28800, stage: Stage.light),
        (from: t0 + 28800, to: t0 + 29400, stage: Stage.wake),
      ];
      final hr = [for (var x = t0; x < t0 + 29400; x += 60) TV(x, 55 + (x % 7))];
      final rm = [for (var x = t0; x < t0 + 29400; x += 300) TV(x, 40 + (x % 11))];
      await _pump(
        t,
        RitmNightScreen(
          data: RitmNightData(
            from: t0, to: t0 + 29400, stages: runs, hr: hr, hrv: rm,
            stress: nightStressOf(hr, rm), signal: signalOf(hr, t0, t0 + 29400),
          ),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      for (final n in ['Стадии', 'Пульс', 'ВСР', 'Ночной стресс', 'Сигнал браслета']) {
        expect(find.text(n), findsWidgets, reason: n);
      }
      expect(find.text('23:00 → 07:10'), findsOneWidget);
      expect(find.text('Пробуждений 1 (≥ 5 мин), коротких 0 · бодрствование между снами 10 мин'), findsOneWidget);
      expect(find.text('стадии — оценка по пульсу и движению · точность низкая'), findsOneWidget);
      final sc = find.byKey(const Key('night-scroll'));
      expect(sc, findsOneWidget);
      await t.drag(sc, const Offset(-400, 0));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });
  }
}
