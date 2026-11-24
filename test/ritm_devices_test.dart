// «Ритм» B4½: модель браслета по HELLO (D2), второе устройство (D3/D4) и
// схема «метрика × источник» (D1, ТЗ v3 §6) — тест на каждую строку таблицы.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_devices.dart';

void main() {
  group('D2 модель из HELLO', () {
    test('gen5 rev-1: оптический 0 → MG, 82 → 5.0, 40 → неизвестно', () {
      final mg = BandCaps.fromGen5Hello(helloRevision: 1, opticalDiscriminator: 0, firmware: '50.42.1.0');
      expect(mg.model, BandModel.whoopMg);
      expect(mg.ecg, isTrue);
      expect(mg.line, 'WHOOP 5.0 MG · прошивка 50.42.1.0');
      expect(mg.lowBatteryPct, 10);
      final g = BandCaps.fromGen5Hello(helloRevision: 1, opticalDiscriminator: 82);
      expect(g.model, BandModel.whoop5);
      expect(g.ecg, isFalse);
      expect(g.batteryDays, '14 дней');
      expect(BandCaps.fromGen5Hello(helloRevision: 1, opticalDiscriminator: 40).known, isFalse);
    });

    test('неизвестная ревизия HELLO не даёт MG (ЭКГ не открываем)', () {
      final x = BandCaps.fromGen5Hello(helloRevision: 2, opticalDiscriminator: 0);
      expect(x.model, isNot(BandModel.whoopMg));
    });

    test('gen4 → 4.0: батарея 4–5 дней, порог заряда 20 %', () {
      final c = BandCaps.gen4(serial: '4A123');
      expect(c.title, 'WHOOP 4.0');
      expect(c.lowBatteryPct, 20);
      expect(c.batteryDays, '4–5 дней');
      expect(c.deepBuffers, isFalse);
    });

    test('приоритет: HELLO > ручной > кэш по серийнику > старый флаг MG', () {
      const manual = BandCaps(model: BandModel.whoop4, origin: 'manual');
      const cached = BandCaps(model: BandModel.whoop5, serial: 'S', origin: 'hello');
      final hello = BandCaps.fromGen5Hello(helloRevision: 1, opticalDiscriminator: 0);
      expect(resolveBandCaps(hello: hello, manual: manual, cached: cached).model, BandModel.whoopMg);
      expect(resolveBandCaps(manual: manual, cached: cached).model, BandModel.whoop4);
      expect(resolveBandCaps(cached: cached).origin, 'cache');
      expect(resolveBandCaps(pairedIsMaverick: true).model, BandModel.whoopMg);
      expect(resolveBandCaps().known, isFalse);
    });

    test('кэш: JSON туда-обратно, серийник без модели не пишется', () {
      final c = BandCaps.fromJson(BandCaps.gen4(serial: 'X', firmware: '41.1').toJson());
      expect(c.model, BandModel.whoop4);
      expect(c.firmware, '41.1');
      const p = RitmDevicePrefs();
      expect(p.withHello(const BandCaps(serial: 'Y')).bySerial, isEmpty);
      expect(p.withHello(c).bySerial['X']!.model, BandModel.whoop4);
    });
  });

  group('D3/D4 второе устройство', () {
    test('Watch по продукту; Garmin по Connect; WHOOP-приложение → предупреждение', () {
      expect(detectSecondDevice(const [SourceProbe(product: 'Watch7,5')]).suggest, SecondDevice.watch);
      expect(
        detectSecondDevice(const [SourceProbe(bundle: 'com.garmin.connect.mobile')]).suggest,
        SecondDevice.garmin,
      );
      final w = detectSecondDevice(const [SourceProbe(bundle: 'com.whoop.iphone')]);
      expect(w.whoopApp, isTrue);
      expect(w.suggest, isNull);
      expect(detectSecondDevice(const [SourceProbe(product: 'iPhone15,2')]).suggest, isNull);
    });

    test('у каждой плитки две строки «даёт / не даёт»', () {
      for (final d in SecondDevice.values) {
        final (a, b) = secondDeviceGives(d);
        expect(a, isNotEmpty);
        expect(b, isNotEmpty);
      }
    });
  });

  group('D1 pickSource — строки таблицы §6', () {
    const W = SecondDevice.watch, G = SecondDevice.garmin, N = SecondDevice.none;

    test('пульс: ночь — браслет; бег с Watch ≥ 80 % — Watch; < 80 % — браслет', () {
      expect(pickSource(RMetric.hr, night: true, set: W, inCardioWorkout: true).source, 'band');
      expect(pickSource(RMetric.hr, set: W, inCardioWorkout: true).source, 'watch');
      expect(pickSource(RMetric.hr, set: W, inCardioWorkout: true, coverage: 0.7).source, 'band');
      expect(pickSource(RMetric.hr, set: W).source, 'band');
      expect(pickSource(RMetric.hr, set: G, inCardioWorkout: true, garminBroadcast: true).source, 'garmin_hr');
      expect(pickSource(RMetric.hr, set: G, inCardioWorkout: true).source, 'band');
    });

    test('ночные метрики — всегда браслет, при любом наборе', () {
      for (final s in SecondDevice.values) {
        for (final m in const [RMetric.rhr, RMetric.hrv, RMetric.resp, RMetric.temp, RMetric.sleep,
              RMetric.sleepScores, RMetric.recovery]) {
          expect(pickSource(m, set: s).source, 'band', reason: '$m $s');
        }
      }
      expect(pickSource(RMetric.temp).trust, 'B');
      expect(pickSource(RMetric.stages).trust, 'C');
    });

    test('SpO₂ ночью — только при замерах Watch', () {
      expect(pickSource(RMetric.spo2, set: W, watchSpo2Tonight: true).source, 'watch');
      expect(pickSource(RMetric.spo2, set: W).source, 'none');
      expect(pickSource(RMetric.spo2, set: N).source, 'none');
    });

    test('шаги: W ≥ 12 ч → браслет → iPhone; Garmin ≥ 12 ч', () {
      expect(pickSource(RMetric.steps, set: W, watchSteps12h: true).source, 'watch');
      expect(pickSource(RMetric.steps, set: W).source, 'band');
      expect(pickSource(RMetric.steps, set: G, garminSteps12h: true).source, 'garmin');
    });

    test('калории — один источник, доверие C', () {
      expect(pickSource(RMetric.kcal, set: W).trust, 'C');
      expect(pickSource(RMetric.kcal, set: G).source, 'garmin');
      expect(pickSource(RMetric.kcal).source, 'band');
    });

    test('тренировки, нагрузка, VO₂max, ЭКГ, HRR, стресс, давление', () {
      expect(pickSource(RMetric.workouts, set: W).source, 'watch');
      expect(pickSource(RMetric.workouts, set: G).trust, 'B');
      expect(pickSource(RMetric.strain, set: W).reason, contains('склеенный'));
      expect(pickSource(RMetric.vo2max, set: W).source, 'watch');
      expect(pickSource(RMetric.vo2max, manualVo2: true).source, 'manual');
      expect(pickSource(RMetric.vo2max).source, 'none');
      expect(pickSource(RMetric.ecg, bandEcg: true).source, 'band');
      expect(pickSource(RMetric.ecg, set: W).source, 'watch');
      expect(pickSource(RMetric.ecg).source, 'none');
      expect(pickSource(RMetric.hrr, set: W).source, 'watch');
      expect(pickSource(RMetric.hrr).source, 'band');
      expect(pickSource(RMetric.stressDay, set: W).source, 'band');
      expect(pickSource(RMetric.bloodPressure, set: W).source, 'none');
    });

    test('у каждой метрики есть причина по-русски', () {
      for (final m in RMetric.values) {
        final p = pickSource(m, set: W);
        expect(p.reason, isNotEmpty);
        expect(RegExp(r'[A-Za-z]{4,}').hasMatch(p.reason.replaceAll('Watch', '').replaceAll('Garmin', '').replaceAll('WHOOP', '').replaceAll('Apple', '').replaceAll('iPhone', '')), isFalse, reason: p.reason);
      }
    });
  });
}
