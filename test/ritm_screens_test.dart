// «Ритм» B1′: экраны «Здоровье», «Источники и сверка», «Ещё» — без
// переполнений на 320 и 393 pt, без латиницы, с составом по ТЗ v2 §4, §8.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ritm/ritm_health.dart';
import 'package:openstrap_edge/ritm/ritm_more.dart';
import 'package:openstrap_edge/ritm/ritm_sources.dart';
import 'package:openstrap_edge/ritm/ritm_watch.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart' show HealthData;
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show ChartPoint;
import 'package:openstrap_edge/ui2/theme.dart' show buildTheme;
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 15, 9, 30);

Map<String, dynamic> _env(num v) => {
  'value': v,
  'confidence': .9,
  'tier': 'HIGH',
};

List<ChartPoint> _series(double base, double amp, int n) => [
  for (var i = n - 1; i >= 0; i--)
    (
      t:
          DateTime(
            _now.year,
            _now.month,
            _now.day - i,
            12,
          ).millisecondsSinceEpoch ~/
          1000,
      v: base + amp * ((i * 7 % 11) - 5) / 5,
    ),
];

HealthData _health(int nights) => HealthData(
  today: {
    'status': {'today_day': '2026-10-15'},
    'daily': {'resting_hr': _env(51)},
    'hrv': {'rmssd': 48, 'confidence': .9, 'tier': 'HIGH'},
    'sleep': {'duration_min': _env(452)},
    'resp': _env(14.2),
    'skin_temp': {
      'value': .3,
      'dev_c': .2,
      'confidence': .8,
      'tier': 'RELATIVE',
    },
  },
  charts: nights == 0
      ? const {}
      : {
          'resting_hr': _series(51, 2, nights),
          'hrv': _series(46, 6, nights),
          'resp_rate': _series(14.1, .4, nights),
        },
  daysWithData: nights,
);

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
      home: Scaffold(body: w),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

List<String> _latin(WidgetTester t) => [
  for (final w in t.widgetList<Text>(find.byType(Text)))
    if (RegExp(r'[A-Za-z]{3,}').hasMatch(
      (w.data ?? w.textSpan?.toPlainText() ?? '')
      // Названия моделей и устройств — имена собственные.
      .replaceAll(
        RegExp(
          r'WHOOP|Apple Watch|Watch|Garmin|MG|OpenAI|AGPL|SpO₂|SDNN|VO₂max|CSV',
          caseSensitive: false,
        ),
        '',
      ),
    ))
      w.data ?? w.textSpan?.toPlainText() ?? '',
];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  for (final size in const [Size(320, 2000), Size(393, 2000)]) {
    final w = size.width.round();

    testWidgets('Здоровье: 30 ночей — коридоры и кардиоформа ($w pt)', (
      t,
    ) async {
      await _pump(
        t,
        RitmHealthScreen(
          data: _health(31),
          watch: WatchNight(
            rhr: 52,
            sleepMin: 441,
            lastSample: _now,
            samples: 100,
          ),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('МОНИТОР ЗДОРОВЬЯ'), findsOneWidget);
      expect(find.text('Пульс покоя'), findsWidgets);
      expect(find.text('ВСР'), findsWidgets);
      expect(find.text('Дыхание'), findsOneWidget);
      expect(find.text('КАРДИОФОРМА'), findsOneWidget);
      expect(find.text('СВЕРКА БРАСЛЕТ / WATCH'), findsOneWidget);
      expect(find.text('Браслет и Watch совпадают'), findsOneWidget);
      expect(find.textContaining('нет источника: нужны Apple Watch'), findsWidgets);
      expect(find.text('Нет данных'), findsNothing);
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Здоровье: 3 ночи — калибровка, не «норма» ($w pt)', (t) async {
      await _pump(t, RitmHealthScreen(data: _health(4)), size);
      expect(t.takeException(), isNull);
      expect(find.textContaining('нужно 7 ночей'), findsWidgets);
      expect(find.text('Калибровка'), findsOneWidget);
      expect(find.textContaining('В норме'), findsNothing);
    });

    testWidgets('Источники и сверка: три блока ($w pt)', (t) async {
      await _pump(
        t,
        RitmSourcesScreen(
          now: _now,
          data: RitmSourcesData(
            model: 'WHOOP 5.0 MG',
            paired: true,
            connected: true,
            battery: 87,
            lastSync: _now.subtract(const Duration(minutes: 3)),
            healthAsked: true,
            watch: WatchNight(
              rhr: 58,
              sleepMin: 441,
              lastSample: _now,
              samples: 90,
            ),
            bandRhr: 51,
            bandSleepMin: 452,
          ),
        ),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('БРАСЛЕТ'), findsWidgets);
      expect(find.text('APPLE WATCH ЧЕРЕЗ ЗДОРОВЬЕ'), findsOneWidget);
      await t.scrollUntilVisible(find.text('СВЕРКА БРАСЛЕТ / WATCH'), 300);
      expect(find.text('СВЕРКА БРАСЛЕТ / WATCH'), findsOneWidget);
      await t.scrollUntilVisible(find.text('WHOOP 5.0 MG'), -300);
      expect(find.text('WHOOP 5.0 MG'), findsOneWidget);
      expect(find.textContaining('3 мин назад'), findsOneWidget);
      // 51 против 58 — разница 7 > 6 → «проверьте посадку браслета» (D10: справочно).
      await t.scrollUntilVisible(find.textContaining('проверьте посадку браслета'), 300);
      expect(
        find.textContaining('проверьте посадку браслета', findRichText: true),
        findsOneWidget,
      );
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });

    testWidgets('Источники: Watch не подключены — кнопка доступа ($w pt)', (
      t,
    ) async {
      await _pump(
        t,
        RitmSourcesScreen(now: _now, data: const RitmSourcesData()),
        size,
      );
      expect(t.takeException(), isNull);
      expect(find.text('ВЫДАТЬ ДОСТУП'), findsOneWidget);
      expect(find.text('не подключён'), findsOneWidget);
    });

    testWidgets('Ещё: ровно восемь пунктов §8 ($w pt)', (t) async {
      await _pump(t, const RitmMoreScreen(), size);
      expect(t.takeException(), isNull);
      for (final s in const [
        'Профиль',
        'Браслет',
        'Источники и сверка',
        'Уведомления',
        'Помощник',
        'Данные',
        'Значок',
        'О приложении',
      ]) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      for (final gone in const [
        'Оформление',
        'Единицы',
        'Дополнительно',
        'Тема',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(_latin(t), isEmpty, reason: '${_latin(t)}');
    });
  }
}
