// «Ритм»: главная рисуется без переполнений на узком и обычном телефоне,
// во всех состояниях датчиков, и не показывает английских слов.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ritm/ritm_home.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show HomeData;
import 'package:openstrap_edge/ui2/theme.dart' show buildTheme;

Metric _m(num v) => Metric(value: v, confidence: .9, tier: MetricTier.high);

final _now = DateTime(2026, 10, 14, 9, 30);

RitmHomeSnapshot _snap(HomeData d, {List<Map<String, dynamic>> s = const []}) =>
    RitmHomeSnapshot(
      d: d,
      days: const ['2026-10-14', '2026-10-13', '2026-10-12'],
      sessions: s,
      battery: (pct: 87, charging: false),
      alarmAt: DateTime(2026, 10, 15, 7, 30),
      alarmOn: true,
    );

final _green = HomeData(
  name: 'Михаил',
  dayId: '2026-10-14',
  readiness: _m(62.05),
  drivers: const [
    {'label': 'hrv', 'contribution': 0.9},
  ],
  sleepMin: _m(452),
  sleepNeedMin: _m(489),
  bedtime: _m(22 * 60 + 25),
  rhr: _m(51),
  steps: _m(8432),
  caloriesTotal: _m(2410),
  strain: _m(9.4),
  illnessState: 'green',
);

const _calibrating = HomeData(
  name: 'Михаил',
  dayId: '2026-10-14',
  readiness: Metric(note: 'need_baseline:have=5,need=14'),
  strain: Metric(note: 'need_baseline:have=1,need=3'),
);

const _nothing = HomeData(dayId: '2026-10-14');

Future<void> _pump(
  WidgetTester t,
  RitmHomeSnapshot s,
  Size size, {
  bool settle = true,
}) async {
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
      home: Scaffold(
        body: RitmHomeScreen(snapshot: s, now: _now),
      ),
    ),
  );
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump(const Duration(milliseconds: 100));
  }
}

List<String> _texts(WidgetTester t) => [
  for (final w in t.widgetList<Text>(find.byType(Text)))
    w.data ?? w.textSpan?.toPlainText() ?? '',
];

void main() {
  for (final size in const [Size(320, 2600), Size(390, 2600)]) {
    testWidgets('зелёный день на ${size.width.round()} pt', (t) async {
      await _pump(
        t,
        _snap(
          _green,
          s: [
            {
              'start_ts':
                  DateTime(2026, 10, 14, 7, 40).millisecondsSinceEpoch ~/ 1000,
              'duration_min': 46,
              'type': 'running',
              'strain': 8.1,
            },
          ],
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('СОН'), findsOneWidget);
      expect(find.text('ВОССТАНОВЛЕНИЕ'), findsOneWidget);
      expect(find.text('НАГРУЗКА'), findsOneWidget);
      expect(find.text('›'), findsNWidgets(3));
      // ТЗ v2 §2: сносок под кольцами нет, «Мой день» с кнопками.
      expect(find.textContaining('Сон:'), findsNothing);
      expect(find.text('ДОБАВИТЬ'), findsOneWidget);
      expect(find.text('НАЧАТЬ'), findsOneWidget);
      expect(find.text('ОТБОЙ'), findsOneWidget);
      expect(find.text('БУДИЛЬНИК ВКЛ'), findsOneWidget);
      // B4¾ — один план на вечер: отбой = 07:30 − 8:09 / 0,90 (эффективность по
      // умолчанию, пока нет 3 ночей) − 10 мин засыпания = 22:17.
      expect(find.text('22:17'), findsOneWidget);
      expect(find.text('78%'), findsOneWidget); // Edge 62 → Ритм 78
      expect(find.text('92%'), findsOneWidget); // 452 из 489
      expect(find.text('9,4'), findsOneWidget);
      expect(find.text('СЕГОДНЯ'), findsOneWidget);
      // Имена собственные (как в ritm_b2_test): WHOOP, Apple Watch, VO₂max…
      final latin = _texts(t).where(
        (s) => RegExp(r'[A-Za-z]{3,}').hasMatch(
          s.replaceAll(
            RegExp(r'WHOOP|Apple Watch|Watch|MG|SpO₂|VO₂max|CSV', caseSensitive: false),
            '',
          ),
        ),
      );
      expect(latin, isEmpty, reason: '$latin');
    });

    testWidgets('калибровка на ${size.width.round()} pt', (t) async {
      await _pump(t, _snap(_calibrating), size);
      expect(t.takeException(), isNull);
      expect(find.text('5/14'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('калибровка'), findsNWidgets(2));
    });

    testWidgets('нет данных на ${size.width.round()} pt', (t) async {
      await _pump(t, _snap(_nothing), size);
      expect(t.takeException(), isNull);
      expect(find.text('–'), findsNWidgets(3));
      expect(find.text('нет данных'), findsNWidgets(3));
    });

    testWidgets(
      'утро, ночь не закрыта, данные старые → «считаю» на ${size.width.round()} pt',
      (t) async {
        await _pump(
          t,
          RitmHomeSnapshot(
            d: const HomeData(
              name: 'Михаил',
              dayId: '2026-10-14',
              recoveryState: 'night_in_progress',
            ),
            days: const ['2026-10-14'],
            dataEdge: DateTime(2026, 10, 14, 9, 0),
          ),
          size,
          settle: false,
        );
        expect(t.takeException(), isNull);
        expect(find.text('считаю'), findsNWidgets(2));
        expect(find.text('идёт сон'), findsNothing);
        expect(find.textContaining('Забираю ночь'), findsOneWidget);
      },
    );

    testWidgets(
      'ночь идёт, данные свежие → «идёт сон» на ${size.width.round()} pt',
      (t) async {
        await _pump(
          t,
          RitmHomeSnapshot(
            d: const HomeData(
              dayId: '2026-10-14',
              recoveryState: 'night_in_progress',
            ),
            dataEdge: DateTime(2026, 10, 14, 9, 25),
          ),
          size,
        );
        expect(find.text('идёт сон'), findsNWidgets(2));
      },
    );
  }

  testWidgets('листание дней: назад на вчера и обратно', (t) async {
    await _pump(t, _snap(_green), const Size(390, 844));
    await t.tap(find.bySemanticsLabel('Предыдущий день'));
    await t.pumpAndSettle();
    expect(find.text('СЕГОДНЯ'), findsNothing);
    await t.tap(find.bySemanticsLabel('Следующий день'));
    await t.pumpAndSettle();
    expect(find.text('СЕГОДНЯ'), findsOneWidget);
  });
}
