// K7 — силовые «как тяжело 1–10» (sRPE): вклад только сверх пульса, подпись, хранение.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ritm/ritm_rings.dart';
import 'package:openstrap_edge/ritm/ritm_srpe.dart';
import 'package:openstrap_edge/ritm/ritm_workout.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<HrMinute> _flat(int from, int minutes, double hr) => [
  for (var i = 0; i < minutes; i++) HrMinute(from + i * 60, hr, HrSrc.band),
];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  test('без оценки — Нагрузка только по пульсу; с оценкой — больше, вклад записан отдельно', () {
    final xs = _flat(0, 60, 115);
    final a = strainV3(xs, rhr: 50, hrMax: 190);
    final b = strainV3(xs, rhr: 50, hrMax: 190, srpe: const [SrpeSession(0, 3600, 7)]);
    expect(a.srpeLoad, 0);
    expect(b.srpeLoad, greaterThan(0));
    expect(b.strain, greaterThan(a.strain));
    expect(b.load, closeTo(a.load + b.srpeLoad, 1e-9));
  });

  test('тяжёлое по пульсу — добавлять нечего (без двойного счёта)', () {
    final xs = _flat(0, 60, 175);
    final hr = hrLoadIn(xs, 0, 3600, rhr: 50, hrMax: 190);
    expect(kSrpeQ * 2 * 60, lessThan(hr));
    final b = strainV3(xs, rhr: 50, hrMax: 190, srpe: const [SrpeSession(0, 3600, 2)]);
    expect(b.srpeLoad, 0);
  });

  test('шкала: 58 мин «6 из 10» при спокойном пульсе ≈ медиана WHOOP Weightlifting (12,1)', () {
    final s = strainScale(kSrpeQ * 6 * 58, kRingTheta);
    expect(s, inInclusiveRange(10.5, 13.5));
  });

  test('оценка хранится по началу тренировки (±2 мин), снимается повторным нажатием', () {
    final s0 = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400;
    RitmRpe.set(s0, s0 + 3480, 7);
    expect(RitmRpe.of(s0 + 60), 7);
    expect(RitmRpe.range(s0 - 1000, s0 + 1000).single.rpe, 7);
    RitmRpe.set(s0, s0 + 3480, null);
    expect(RitmRpe.of(s0), isNull);
  });

  test('слова шкалы', () {
    expect(rpeWord(1), 'очень легко');
    expect(rpeWord(6), 'тяжело');
    expect(rpeWord(10), 'на пределе');
  });

  testWidgets('экран силовой: «Как тяжело было?», выбор 7 → «по ощущению»', (t) async {
    final n = DateTime.now();
    final y = DateTime(n.year, n.month, n.day - 1, 12, 30);
    await t.binding.setSurfaceSize(const Size(393, 1400));
    await t.pumpWidget(
      MaterialApp(
        home: RitmWorkoutScreen(
          w: RitmDayWorkout(
            name: 'Силовая',
            start: y,
            end: y.add(const Duration(minutes: 58)),
            bandAvgHr: 110,
            icon: LucideIcons.dumbbell,
            strength: true,
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('КАК ТЯЖЕЛО БЫЛО?'), findsOneWidget);
    expect(find.textContaining('Без оценки — мышечная нагрузка не учтена'), findsOneWidget);
    await t.tap(find.text('7'));
    await t.pump();
    expect(find.textContaining('7 из 10 — очень тяжело · по ощущению'), findsOneWidget);
    expect(find.textContaining('Разница добавлена в Нагрузку дня'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.binding.setSurfaceSize(null);
  });

  testWidgets('база «по пульсу» = Нагрузка сессии браслета из шапки', (t) async {
    final n = DateTime.now();
    final y = DateTime(n.year, n.month, n.day - 2, 12, 30);
    await t.binding.setSurfaceSize(const Size(393, 1400));
    await t.pumpWidget(
      MaterialApp(
        home: RitmWorkoutScreen(
          w: RitmDayWorkout(
            name: 'Силовая',
            start: y,
            end: y.add(const Duration(minutes: 58)),
            strain: 9.7,
            bandAvgHr: 124,
            icon: LucideIcons.dumbbell,
            strength: true,
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.textContaining('По пульсу: 9,7'), findsOneWidget);
    await t.binding.setSurfaceSize(null);
  });
}
