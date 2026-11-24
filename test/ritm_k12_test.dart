// K12 — тренд восстановления пульса (HRR 1 мин) за 30 дней.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_health.dart';

void main() {
  final now = DateTime(2026, 10, 16, 9);
  (DateTime, int) at(int daysAgo, int v) => (now.subtract(Duration(days: daysAgo)), v);

  test('границы 30 дней и среднее', () {
    final t = hrrTrend([at(1, 30), at(10, 24), at(29, 27), at(31, 20), at(45, 22), at(59, 21), at(61, 99)], now);
    expect(t.n, 3);
    expect(t.avg, 27);
    expect(t.nPrev, 3);
    expect(t.prev, 21);
  });

  test('меньше 3 тренировок — «нужно 3», без числа', () {
    final (main, sub) = hrrTrendText(hrrTrend([at(1, 30), at(2, 28)], now));
    expect(main, '—');
    expect(sub, contains('сейчас 2'));
  });

  test('стрелка — только при разнице ≥ 2 и ≥ 3 тренировках в обоих периодах', () {
    final up = hrrTrendText(hrrTrend([at(1, 28), at(5, 28), at(9, 28), at(35, 24), at(40, 24), at(50, 24)], now));
    expect(up.$1, '−28 уд/мин');
    expect(up.$2, contains('↑ к прошлым 30 дням (24)'));
    final flat = hrrTrendText(hrrTrend([at(1, 25), at(5, 25), at(9, 25), at(35, 24), at(40, 24), at(50, 24)], now));
    expect(flat.$2, isNot(contains('↑')));
    final few = hrrTrendText(hrrTrend([at(1, 28), at(5, 28), at(9, 28), at(35, 20)], now));
    expect(few.$2, isNot(contains('↑')));
    expect(few.$2, contains('хорошо'));
  });
}
