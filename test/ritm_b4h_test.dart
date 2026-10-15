// «Ритм» B4½: Восстановление Dart = Python калибровки (фикстура из экспорта
// WHOOP Михаила), экран «Сверка с WHOOP», импорт zip/CSV, модель из HELLO,
// второе устройство, кольца на главной (источник, таймлайн, коридор),
// «Восстановление» с вкладами, 3D-шар (статичный кадр при «Уменьшении движения»).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_charts.dart';
import 'package:openstrap_edge/ritm/ritm_compare.dart';
import 'package:openstrap_edge/ritm/ritm_demo.dart' show demoStrainBack, demoWeekForTest, ritmDemoRings;
import 'package:openstrap_edge/ritm/ritm_detail.dart' show RitmRecoveryScreen;
import 'package:openstrap_edge/ritm/ritm_devices.dart';
import 'package:openstrap_edge/ritm/ritm_rings.dart';
import 'package:openstrap_edge/ritm/ritm_ui.dart';
import 'package:openstrap_edge/ritm/ritm_whoop_csv.dart';
import 'package:openstrap_edge/ritm/ritm_whoop_ui.dart';

final _latin = RegExp(r'[A-Za-z]{3,}');

/// Латиница в видимых текстах (кроме имён устройств/брендов и единиц).
List<String> _latinTexts(WidgetTester t) {
  const ok = ['WHOOP', 'Watch', 'Apple', 'Garmin', 'MAE', 'CSV', 'zip'];
  final out = <String>[];
  for (final w in t.widgetList<Text>(find.byType(Text))) {
    var s = w.data ?? w.textSpan?.toPlainText() ?? '';
    for (final k in ok) {
      s = s.replaceAll(k, '');
    }
    if (_latin.hasMatch(s)) out.add(w.data ?? '');
  }
  return out;
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(393, 852), disableAnimations: true),
    child: child,
  ),
);

void main() {
  // Личная выгрузка WHOOP в публичный репозиторий не входит — тогда группа пропускается.
  const recFx = 'test/fixtures/ritm_compare/recovery_whoop_inputs.json';
  final recPrivate = File(recFx).existsSync() ? null : 'личная выгрузка WHOOP не публикуется';
  group('Восстановление: Dart = Python калибровки (25 дней WHOOP Михаила)', () {
    final rows = recPrivate == null ? jsonDecode(File(recFx).readAsStringSync()) as List : const [];

    test('каждый день совпадает до 0,5 п.п. (θ 15.10, норма — ср./SD 30 ночей)', () {
      expect(rows.length, 25);
      for (final r in rows.cast<Map>()) {
        List<double> l(String k) => [for (final x in r[k] as List) (x as num).toDouble()];
        final res = recoveryV3(
          rmssd: (r['hrv'] as num).toDouble(),
          rhr: (r['rhr'] as num).toDouble(),
          resp: (r['resp'] as num?)?.toDouble(),
          sleepPct: (r['sleep_pct'] as num?)?.toDouble(),
          rmssdHist: l('hrv_hist'),
          rhrHist: l('rhr_hist'),
          respHist: l('resp_hist'),
        );
        final want = (r['expected'] as num).toDouble();
        final want66 = (r['sleep_pct'] as num?) != null && (r['sleep_pct'] as num) < 60 && want > 66 ? 66.0 : want;
        expect(res.value, isNotNull, reason: r['day'] as String);
        expect((res.value! - want66).abs(), lessThanOrEqualTo(0.5 + 1e-9), reason: '${r['day']}: ${res.value} vs $want66');
      }
    });
  }, skip: recPrivate);

  group('«Сверка с WHOOP»', () {
    final demo = demoWhoopCompareData(DateTime(2026, 10, 15));

    test('демо-данные: 44 дня, 2 «грязных» (снят браслет), силовые, один день вне допуска', () {
      final r = compareWhoop(demo.w, demo.ours);
      expect(r.rows.length, 44);
      expect(r.rows.where((x) => !x.clean).length, 1);
      expect(r.rows.where((x) => x.strength).length, greaterThan(2));
      expect(r.preliminary, isFalse);
      final bad = r.rows.where((x) => x.cells['hrv'] != null && !r.cellOk('hrv', x.cells['hrv']!.delta));
      expect(bad, isNotEmpty);
    });

    test('доли зон округляются в сумму 100', () {
      expect(pct100([.494, .331, .175]), [49, 33, 18]);
      expect(pct100([.335, .335, .33]).fold<int>(0, (a, b) => a + b), 100);
    });

    test('красная строка объясняет причину: r ниже порога при малой ошибке', () {
      const t = CmpTol(mae: 2, bias: 1, r: 0.90);
      const st = CmpStat(n: 43, mae: 1.2, bias: 0.1, r: 0.85);
      expect(cmpPass(st, t), isFalse);
      expect(cmpWhy(st, t).values, ['дни не в такт: r 0,85 < 0,90']);
      expect(cmpWhy(const CmpStat(n: 2), t).values, ['мало дней (2)']);
      final r = compareWhoop(demo.w, demo.ours);
      for (final x in r.results.values) {
        if (x.hasData && !x.pass) expect(x.why(r.mult), isNotEmpty, reason: x.m.key);
      }
    });

    testWidgets('экран: итог, вкладки Кольца/Сон, таблица по дням, калибровка — по-русски', (t) async {
      await t.pumpWidget(_app(RitmWhoopCompareScreen(whoop: demo.w, ours: demo.ours, importedAt: DateTime(2026, 10, 15))));
      await t.pump();
      expect(find.text('Сверка с WHOOP'), findsWidgets);
      expect(find.textContaining('Кольца:'), findsOneWidget);
      expect(find.text('Пульс покоя'), findsOneWidget);
      await t.scrollUntilVisible(find.text('ПО ДНЯМ'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('ПО ДНЯМ'), findsOneWidget);
      expect(_latinTexts(t), isEmpty);
      await t.scrollUntilVisible(find.text('КАЛИБРОВКА ФОРМУЛ'), 600, scrollable: find.byType(Scrollable).first);
      expect(_latinTexts(t), isEmpty);
      // Вкладка «Сон» — тап по переключателю на свежем экране.
      await t.pumpWidget(_app(RitmWhoopCompareScreen(key: UniqueKey(), whoop: demo.w, ours: demo.ours, importedAt: DateTime(2026, 10, 16))));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('cmp-tab-sleep')));
      await t.pump();
      expect(find.textContaining('Сон:'), findsOneWidget);
      expect(find.text('Время сна'), findsOneWidget);
    });

    testWidgets('без общих дней — честно: «Общих дней пока нет», калибровка видна', (t) async {
      final w = WhoopExport(cycles: [
        for (var i = 0; i < 30; i++) WhoopCycle(day: dayId(DateTime(2026, 7, 1 + i)), recovery: 50),
      ]);
      await t.pumpWidget(_app(RitmWhoopCompareScreen(whoop: w, ours: demo.ours)));
      await t.pump();
      expect(find.text('Общих дней пока нет'), findsOneWidget);
      expect(find.textContaining('Формулы уже откалиброваны'), findsOneWidget);
      expect(find.text('ПО ДНЯМ'), findsNothing);
    });

    test('импорт: zip из письма WHOOP и отдельные CSV узнаются по заголовку', () {
      const cyc = 'Cycle start time,Cycle end time,Cycle timezone,Recovery score %\n2026-08-09 00:34:04,,UTC+05:00,29\n';
      const slp = 'Cycle start time,Cycle end time,Cycle timezone,Sleep onset,Wake onset,Sleep performance %,Nap\n';
      final a = Archive()
        ..addFile(ArchiveFile.bytes('my_whoop_data/physiological_cycles.csv', utf8.encode(cyc)))
        ..addFile(ArchiveFile.bytes('my_whoop_data/sleeps.csv', utf8.encode(slp)))
        ..addFile(ArchiveFile.bytes('my_whoop_data/readme.txt', utf8.encode('x')));
      final zip = Uint8List.fromList(ZipEncoder().encode(a));
      final texts = RitmWhoopFiles.textsOf([(name: 'whoop.zip', bytes: zip)]);
      expect(texts.keys.toSet(), {'physiological_cycles.csv', 'sleeps.csv'});
      expect({for (final x in texts.values) whoopFileKind(x)}, {'cycles', 'sleeps'});
      final one = RitmWhoopFiles.textsOf([(name: 'workouts.CSV', bytes: Uint8List.fromList(utf8.encode('a,b\n')))]);
      expect(one.length, 1);
    });
  });

  group('D2 модель из HELLO', () {
    test('noteHello запоминает модель; current: HELLO выше ручного и кэша', () async {
      RitmDevicePrefs.hello.value = null;
      expect(RitmDevicePrefs.current().known, isFalse);
      expect(RitmDevicePrefs.current(pairedIsMaverick: true).model, BandModel.whoopMg);
      RitmDevicePrefs.hello.value = BandCaps.fromGen5Hello(
        helloRevision: 1,
        opticalDiscriminator: 60,
        firmware: '50.36.2.0',
        serial: 'S1',
      );
      final c = RitmDevicePrefs.current(pairedIsMaverick: true);
      expect(c.model, BandModel.whoop5);
      expect(c.line, 'WHOOP 5.0 · прошивка 50.36.2.0');
      expect(c.lowBatteryPct, 10);
      expect(const BandCaps(model: BandModel.whoop4).lowBatteryPct, 20);
      RitmDevicePrefs.hello.value = null;
    });
  });

  group('Главная и «Восстановление» (кольца v3)', () {
    final r = ritmDemoRings(DateTime(2026, 10, 15));

    test('демо-кольца: 78 % по калиброванной формуле, «↑» к вчера, источник «браслет 8 ч 40 мин + Watch 46 мин» (+ «не носился 0:15» = 9:41)', () {
      expect(r.recovery.value, 78);
      expect(r.arrow, ' ↑');
      expect(r.strainSource, 'браслет 8 ч 40 мин + Watch 46 мин');
      // Сегменты таймлайна до 09:41: 8:40 браслет + 0:46 Watch + 0:15 пусто = 9:41.
      final now = r.dayFrom + 9 * 3600 + 41 * 60;
      final total = r.inputs.timeline.fold<int>(0, (a, g) => a + (math.min(g.to, now) - g.from));
      expect(total, 9 * 3600 + 41 * 60);
      final sum = r.recovery.drivers.fold<double>(0, (a, d) => a + d.weight);
      expect(sum, closeTo(1, 1e-9));
    });

    test('график 7 дней: бар дня = Нагрузка того же дня (одна таблица демо)', () {
      for (final end in [0, 1, 3]) {
        final w = demoWeekForTest(end);
        expect(w.length, 7);
        for (var i = 0; i < 7; i++) {
          expect(w[i].strain, demoStrainBack(end + 6 - i), reason: 'конец $end, бар $i');
        }
      }
      expect(demoStrainBack(0), 10.8);
      expect(demoStrainBack(2), 4.2);
    });

    testWidgets('таймлайн 24 ч и мини-шкала 0–21 рисуются', (t) async {
      await t.pumpWidget(_app(Scaffold(
        body: Column(children: [
          RitmHrTimeline(segments: r.inputs.timeline, from: r.dayFrom, to: r.dayTo, now: r.dayFrom + 9 * 3600),
          const RitmStrainScale(value: 10.8, lo: 14, hi: 18),
        ]),
      )));
      expect(find.byType(RitmHrTimeline), findsOneWidget);
      expect(find.text('21'), findsOneWidget);
    });

    testWidgets('«Восстановление»: 5 факторов, вклады в пунктах, дата калибровки', (t) async {
      await t.pumpWidget(_app(RitmRecoveryScreen(
        hero: const GaugeState(frac: .78, value: '78%', inner: 'Готов ↑'),
        rings: r,
      )));
      await t.pump();
      expect(find.text('ВСР в глубоком сне'), findsOneWidget);
      expect(find.text('Пульс покоя за сон'), findsOneWidget);
      await t.scrollUntilVisible(find.text('ВКЛАД В ЭТО УТРО, ПУНКТЫ'), 200);
      expect(find.textContaining('Формула откалибрована по вашему экспорту WHOOP'), findsOneWidget);
      expect(_latinTexts(t), isEmpty);
    });
  });
}
