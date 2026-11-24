// «Ритм» B7: Garmin через «Здоровье», трансляция пульса в Нагрузку,
// ручной VO₂max (D9), «Дыхание ночью» (K17) — чистые правила.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_b7.dart';
import 'package:openstrap_edge/ritm/ritm_bioage.dart';
import 'package:openstrap_edge/ritm/ritm_devices.dart';
import 'package:openstrap_edge/ritm/ritm_hk.dart';
import 'package:openstrap_edge/ritm/ritm_rings.dart';

const _garmin = {'bundle': 'com.garmin.connect.mobile', 'name': 'Connect', 'product': 'iPhone15,2', 'model': 'fenix 8'};
const _watch = {'bundle': 'com.apple.health.ABC', 'name': 'Apple Watch', 'product': 'Watch7,1', 'model': 'Watch'};

Map<String, Object?> _wk(Map src, int s, int e, {double avg = 140}) => {
  's': s * 1000,
  'e': e * 1000,
  'type': 37,
  'hrAvg': avg,
  'hrN': 500,
  'hrSeries': [for (var t = s; t < e; t += 20) [t * 1000, avg]],
  'src': src,
};

void main() {
  final t0 = DateTime(2026, 10, 16, 7, 40).millisecondsSinceEpoch ~/ 1000;

  group('Garmin через «Здоровье»', () {
    final snap = HkSnapshot.parse({
      'available': true,
      'nowMs': DateTime(2026, 10, 16, 12).millisecondsSinceEpoch,
      'workouts': [_wk(_garmin, t0, t0 + 46 * 60), _wk(_watch, t0 + 3600 * 3, t0 + 3600 * 3 + 1800)],
      'vo2': [
        {'v': 48.0, 's': t0 * 1000, 'e': t0 * 1000, 'src': _garmin},
      ],
      'steps': {'all': 12000, 'watch': 3000, 'watchHours': 4, 'garmin': 10800, 'garminHours': 15},
    });

    test('источник Garmin узнаётся по bundle, Watch — нет', () {
      expect(HkSource.parse(_garmin).isGarmin(), isTrue);
      expect(HkSource.parse(_watch).isGarmin(), isFalse);
      expect(HkSource.parse(_garmin).isWatch(), isFalse);
    });

    test('набор «браслет + Garmin»: только тренировки и шаги Garmin, без VO₂max', () {
      final w = WatchData.from(snap, garmin: true);
      expect(w.garmin, isTrue);
      expect(w.device, 'Garmin');
      expect(w.workouts.length, 1);
      expect(w.workouts.single.src.isGarmin(), isTrue);
      expect(w.steps.watch, 10800);
      expect(w.steps.watchHours, 15);
      expect(w.vo2, isNull, reason: 'Garmin не передаёт VO₂max в «Здоровье»');
    });

    test('набор «браслет + Watch» не берёт Garmin', () {
      final w = WatchData.from(snap);
      expect(w.device, 'Apple Watch');
      expect(w.workouts.length, 1);
      expect(w.workouts.single.src.isWatch(), isTrue);
      expect(w.steps.watch, 3000);
    });

    test('автоопределение: есть только Garmin → предлагаем Garmin', () {
      final r = detectSecondDevice([const SourceProbe(bundle: 'com.garmin.connect.mobile')]);
      expect(r.suggest, SecondDevice.garmin);
    });
  });

  group('трансляция пульса → Нагрузка', () {
    test('отрезки: разрыв > 2 мин режет, короче 5 мин — не тренировка', () {
      final hr = [
        for (var t = 0; t < 30 * 60; t += 1) TV(t0 + t, 150),
        for (var t = 0; t < 3 * 60; t += 1) TV(t0 + 3600 + t, 120),
      ];
      final segs = broadcastSegments(hr, HrSrc.garmin);
      expect(segs.length, 1);
      expect(segs.single.src, HrSrc.garmin);
      expect(segs.single.to - segs.single.from, closeTo(30 * 60, 2));
    });

    test('склейка: в окне трансляции идёт её пульс, вне — браслет', () {
      final band = [for (var m = 0; m < 120; m++) TV(t0 + m * 60, 100)];
      final bc = [for (var t = 30 * 60; t < 60 * 60; t++) TV(t0 + t, 160)];
      final xs = stitchHr(band, broadcastSegments(bc, HrSrc.sensor));
      final bySrc = <HrSrc, int>{};
      for (final m in xs) {
        bySrc[m.src] = (bySrc[m.src] ?? 0) + 1;
      }
      expect(bySrc[HrSrc.sensor], 30);
      expect(bySrc[HrSrc.band], 90);
      expect(strainSourceLine(bySrc), 'браслет 1 ч 30 мин + датчик пульса 30 мин');
    });

    test('мусор (< 30 или > 230) выбрасывается', () {
      final hr = [for (var t = 0; t < 10 * 60; t++) TV(t0 + t, t.isEven ? 0 : 250)];
      expect(broadcastSegments(hr, HrSrc.sensor), isEmpty);
    });
  });

  group('D9 VO₂max вручную', () {
    test('проверка ввода', () {
      expect(RitmVo2Manual.validate('44,5'), isNull);
      expect(RitmVo2Manual.validate('8'), isNotNull);
      expect(RitmVo2Manual.validate('abc'), isNotNull);
    });

    test('замер устройства важнее; ввод — с даты ввода и 180 дней', () {
      final at = DateTime(2026, 9, 1);
      expect(vo2ForDay(DateTime(2026, 10, 1), 50, (44, at))!.manual, isFalse);
      expect(vo2ForDay(DateTime(2026, 10, 1), null, (44, at))!.v, 44);
      expect(vo2ForDay(DateTime(2026, 8, 31), null, (44, at)), isNull);
      expect(vo2ForDay(DateTime(2027, 3, 31), null, (44, at)), isNull);
    });

    test('биовозраст: VO₂max «введено» входит во вклады', () {
      final days = [
        for (var i = 0; i < 30; i++)
          BioDay(DateTime(2026, 9, 17).add(Duration(days: i)), sleepMin: 450, rhr: 52, steps: 9000, onsetMin: 23 * 60, wakeMin: 7 * 60 + 30),
      ];
      final withManual = withManualVo2(days, (52.0, DateTime(2026, 9, 1)));
      expect(withManual.every((d) => d.vo2 == 52 && d.vo2Manual), isTrue);
      String vo2Text(List<BioDay> w) => bioParts(w, age: 41)[kBioOrder.indexOf(BioKey.vo2)].value;
      expect(vo2Text(days), contains('ввод вручную'));
      expect(vo2Text(withManual), '52,0 · введено');
      // Замер Watch в дне не перезаписывается вводом.
      final mixed = withManualVo2([days.first.withVo2(48), ...days.skip(1)], (52.0, DateTime(2026, 9, 1)));
      expect(mixed.first.vo2Manual, isFalse);
    });
  });

  group('K17 дыхание ночью', () {
    List<CvhrNightRow> nights(List<double> xs, {double hours = 6}) => [
      for (var i = 0; i < xs.length; i++) CvhrNightRow('2026-09-${(i + 1).toString().padLeft(2, '0')}', xs[i], hours),
    ];
    final usual = [for (var i = 0; i < 20; i++) 8.0 + i % 5];

    test('меньше 14 ночей — учится', () {
      expect(cvhrVerdict(nights(usual.sublist(0, 10))).state, CvhrState.learning);
    });

    test('две ночи подряд выше обычного верха — «непохожа»', () {
      final v = cvhrVerdict(nights([...usual, 25, 26]));
      expect(v.state, CvhrState.unlike);
    });

    test('одна ночь выше — ещё нет (нужны две подряд)', () {
      expect(cvhrVerdict(nights([...usual, 25, 9])).state, CvhrState.usual);
    });

    test('короткие ночи (< 4 ч) не считаются', () {
      final rows = [...nights(usual), ...nights([25, 26], hours: 2)];
      expect(cvhrVerdict(rows).state, CvhrState.usual);
    });

    test('текст по юридическому разбору строителя (B6_legal.md §5), без запретных слов', () {
      expect(kRitmCvhrText, contains('Это не диагноз'));
      for (final w in ['апноэ', 'нарушени', 'риск', '%']) {
        expect(kRitmCvhrText.toLowerCase().contains(w), isFalse, reason: w);
      }
    });
  });
}
