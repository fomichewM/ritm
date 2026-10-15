// «Ритм» B2: Монитор стресса (ТЗ v2 §10.5) — окна, допуск, шкала,
// калибровка, плитка. Чистые функции, без базы.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_stress.dart';

/// Синтетические секунды: пульс [hr], RR вокруг 60000/hr с разбросом ±[jit] мс.
(List<StressSec>, List<StressBeat>) _desk(
  int from,
  int secs, {
  double hr = 70,
  int jit = 25,
  double enmo = .004,
  int cls = 0,
  int seed = 1,
}) {
  final r = math.Random(seed);
  final s = <StressSec>[], b = <StressBeat>[];
  var tBeat = from.toDouble();
  for (var i = 0; i < secs; i++) {
    s.add(StressSec(from + i, hr: hr.round(), enmo: enmo, cls: cls));
  }
  while (tBeat < from + secs) {
    final rr = (60000 / hr + (r.nextDouble() * 2 - 1) * jit).round();
    b.add(StressBeat(tBeat.floor(), rr));
    tBeat += rr / 1000;
  }
  return (s, b);
}

void main() {
  const t0 = 1792000000; // произвольная секунда, кратная 60 не обязательно

  test('чистые RR-разности: артефакты и скачки > 20 % отбрасываются', () {
    final d = cleanRrDiffs([800, 810, 1600, 805, 250, 820, 830]);
    expect(d, [10.0, 10.0]);
    expect(rmssdOf(d), closeTo(10, 1e-9));
    expect(rmssdOf(const []), isNull);
  });

  test('2 часа спокойной работы за столом → ≥ 60 точек (приёмка B2)', () {
    final (s, b) = _desk(t0, 2 * 3600);
    final w = stressWindows(s, b);
    expect(w.where((x) => x.quiet).length, greaterThanOrEqualTo(60));
    final day = stressDay(w, pastQuiet: const [], now: t0 + 2 * 3600);
    expect(day.measured, greaterThanOrEqualTo(60));
    // Норма из того же дня — значения около 1 (обычный день).
    final vals = [for (final p in day.points) ?p.s];
    expect(vals.every((v) => v >= 0 && v <= 3), isTrue);
    expect(vals.reduce((a, c) => a + c) / vals.length, closeTo(1, .35));
  });

  test('сон, тренировка, движение и снятый браслет — без значений', () {
    final (s, b) = _desk(t0, 3600);
    final sleep = [(from: t0, to: t0 + 1200)];
    final work = [(from: t0 + 1800, to: t0 + 2400)];
    final w = stressWindows(s, b, sleep: sleep, workouts: work);
    expect(w.any((x) => x.gap == StressGap.sleep), isTrue);
    expect(w.any((x) => x.gap == StressGap.workout), isTrue);
    expect(
      w.where((x) => x.gap != StressGap.none).every((x) => x.hr == null),
      isTrue,
    );
    final (m, mb) = _desk(t0, 1200, enmo: .1);
    expect(stressWindows(m, mb).every((x) => x.gap == StressGap.motion), isTrue);
    final (wk, wb) = _desk(t0, 1200, cls: 1);
    expect(stressWindows(wk, wb).every((x) => !x.quiet), isTrue);
    final off = [for (final x in s.take(1200)) StressSec(x.ts, hr: x.hr, enmo: x.enmo, onWrist: false)];
    expect(stressWindows(off, b).every((x) => x.gap == StressGap.signal), isTrue);
  });

  test('мало RR (< 20 чистых разностей) — окно не считается', () {
    final (s, _) = _desk(t0, 900);
    final few = [for (var i = 0; i < 10; i++) StressBeat(t0 + 400 + i, 850)];
    expect(stressWindows(s, few).every((x) => !x.quiet), isTrue);
  });

  test('шкала: норма → 1; пульс выше и ВСР ниже → выше; границы 0…3', () {
    const b = StressBaseline(hr: 70, hrSd: 5, ln: 3.6, lnSd: .3, days: 7);
    expect(stressScore(70, 3.6, b), closeTo(1, 1e-9));
    expect(stressScore(80, 3.3, b), closeTo(1 + .6 * (.6 * 2 + .4 * 1), 1e-9));
    expect(stressScore(140, 1, b), 3);
    expect(stressScore(40, 6, b), 0);
    expect(stressLevel(.6), StressLevel.low);
    expect(stressLevel(1.4), StressLevel.mid);
    expect(stressLevel(2.2), StressLevel.high);
  });

  test('калибровка N/7 и текст плитки', () {
    final (s, b) = _desk(t0, 3600, seed: 3);
    final w = stressWindows(s, b);
    final day25 = List.generate(25, (i) => (70.0 + i % 3, 3.6));
    final cal = stressDay(w, pastQuiet: [day25, day25, day25], now: t0 + 3600);
    expect(cal.calDays, 4); // три прошлых дня + сегодня
    expect(stressTileText(cal), 'Калибровка · 4/7');
    final full = stressDay(w, pastQuiet: List.filled(8, day25), now: t0 + 3600);
    expect(full.calibrated, isTrue);
    expect(stressTileText(full), matches(RegExp(r'^(Низкий|Средний|Высокий) · \d,\d$')));
    // Последний замер старше 30 минут — «Нет замера».
    final old = stressDay(w, pastQuiet: List.filled(8, day25), now: t0 + 3 * 3600);
    expect(stressTileText(old), 'Нет замера');
    expect(stressTileText(null), 'Нет данных');
  });

  test('норма — по 14 последним дням, SD с полом', () {
    final days = [
      for (var d = 0; d < 20; d++) [for (var i = 0; i < 20; i++) (60.0 + d, 3.5)],
    ];
    final b = stressBaseline(days)!;
    expect(b.hr, closeTo(72.5, .6)); // дни 6…19 → медиана 72,5
    expect(b.lnSd, .15);
    expect(b.days, 14);
  });
}
