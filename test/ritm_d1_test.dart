// D1/U3 на экране тренировки: чей пульс в Нагрузке и надёжность (pickSource, ТЗ §6).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ritm/ritm_devices.dart';
import 'package:openstrap_edge/ritm/ritm_workout.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  test('§6 S4: Garmin без трансляции — пульс тренировки браслета; с трансляцией — Garmin', () {
    const g = SecondDevice.garmin;
    expect(pickSource(RMetric.workoutHr, set: g, inCardioWorkout: true).source, 'band');
    final b = pickSource(RMetric.workoutHr, set: g, inCardioWorkout: true, garminBroadcast: true);
    expect(b.source, 'garmin_hr');
    expect(b.trust, 'A');
  });

  testWidgets('шапка тренировки: «Пульс в Нагрузку: браслет · надёжность высокая» и «почему»', (t) async {
    final n = DateTime.now();
    final y = DateTime(n.year, n.month, n.day - 3, 18, 5);
    await t.binding.setSurfaceSize(const Size(393, 1400));
    await t.pumpWidget(
      MaterialApp(
        home: RitmWorkoutScreen(
          w: RitmDayWorkout(
            name: 'Велосипед',
            start: y,
            end: y.add(const Duration(minutes: 47)),
            bandAvgHr: 122,
            icon: LucideIcons.bike,
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('Пульс в Нагрузку: браслет · надёжность высокая'), findsOneWidget);
    await t.tap(find.text('Пульс в Нагрузку: браслет · надёжность высокая'));
    await t.pumpAndSettle();
    expect(find.textContaining('Почему: браслет носится весь день'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.binding.setSurfaceSize(null);
  });
}
