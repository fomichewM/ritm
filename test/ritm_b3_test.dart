// «Ритм» B3 — Apple Watch и автоопределение (ТЗ v2 §10.6, §10.9, §10.10,
// §10.11, §10.12, §4.3–4.5): разбор ответа Swift-канала `ritm/health`,
// классификатор тренировок (мягкий ярус, приоритет Watch, отклонённые),
// сверка браслет / Watch, шаги, правила записи в «Здоровье».

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_calc.dart';
import 'package:openstrap_edge/ritm/ritm_hk.dart';
import 'package:openstrap_edge/ritm/ritm_workout.dart' show softCandidates, demoWalkSecs;
import 'package:openstrap_edge/ritm/ritm_write_gate.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Фикстура — ответ `snapshot` в формате RitmHealthKit.swift (единицы
/// HealthKit: SpO₂ долей 0…1, VO₂max мл/кг/мин, температура °C, пульс уд/мин;
/// источники как у настоящего «Здоровья»: Watch — bundle
/// `com.apple.health.<UUID>`, productType `Watch6,4`, модель `Watch`; iPhone —
/// `iPhone15,2`; свои записи — `com.oporagroup.ritm`; Oura — чужое приложение).
/// Время в файле — «часы на стене» 15.10.2026 09:41, записанные как UTC;
/// [_rebase] переносит их в локальный пояс машины, где идут тесты.
Object? _rebase(Object? x, [String? key]) {
  int r(num ms) {
    final u = DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
    return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second)
        .millisecondsSinceEpoch;
  }

  if (x is Map) {
    return {
      for (final e in x.entries)
        e.key: (const {'s', 'e', 'nowMs'}.contains(e.key) && e.value is num)
            ? r(e.value as num)
            : e.key == 'hrAfter'
            ? [
                for (final p in e.value as List)
                  [r((p as List)[0] as num), p[1]],
              ]
            : _rebase(e.value, e.key as String),
    };
  }
  if (x is List) return [for (final v in x) _rebase(v, key)];
  return x;
}

HkSnapshot _fixture() {
  final raw = jsonDecode(
    File('test/fixtures/ritm_hk_snapshot.json').readAsStringSync(),
  );
  return HkSnapshot.parse(_rebase(raw));
}

const _own = 'com.oporagroup.ritm';
final _now = DateTime(2026, 10, 15, 9, 41);
DateTime _at(int h, int m, [int day = 0]) =>
    DateTime(2026, 10, 15 + day, h, m);

/// Секунды браслета: [minutes] минут с пульсом [hr] (callback по секунде).
List<WkSec> _secs(
  DateTime from,
  int minutes, {
  required int Function(int k) hr,
  int? cls,
  int? cadence,
  double enmo = .1,
}) => [
  for (var k = 0; k < minutes * 60; k++)
    WkSec(
      from.millisecondsSinceEpoch ~/ 1000 + k,
      hr: hr(k),
      cls: cls,
      cadence: cadence,
      enmo: enmo,
    ),
];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('Swift-канал: разбор ответа HealthKit (фикстура)', () {
    test('снимок разбирается целиком', () {
      final s = _fixture();
      expect(s.available, isTrue);
      expect(s.now, _now);
      expect(s.vo2, hasLength(6));
      expect(s.spo2, hasLength(18));
      expect(s.ecg, hasLength(3));
      expect(s.workouts, hasLength(2));
      expect(s.workouts.first.hrAfter, hasLength(5));
      expect(s.steps.watch, 7520);
      expect(s.steps.watchHours, 10);
    });

    test('источник: Watch / iPhone / свои / чужие / засев', () {
      const w = HkSource(
        bundle: 'com.apple.health.81C6F1D0',
        product: 'Watch6,4',
        model: 'Watch',
      );
      const phone = HkSource(
        bundle: 'com.apple.health.5F2A',
        product: 'iPhone15,2',
        model: 'iPhone',
      );
      const own = HkSource(bundle: _own, product: 'iPhone15,2');
      const ownAsWatch = HkSource(bundle: _own, model: 'Watch');
      const seed = HkSource(bundle: _own, model: 'Watch', seed: true);
      expect(w.isWatch(own: _own), isTrue);
      expect(phone.isWatch(own: _own), isFalse);
      expect(own.isWatch(own: _own), isFalse);
      // Наша запись не становится «Watch», даже если устройство Watch.
      expect(ownAsWatch.isWatch(own: _own), isFalse);
      // Засев симулятора — только в DEBUG-режиме чтения.
      expect(seed.isWatch(own: _own), isFalse);
      expect(seed.isWatch(own: _own, allowSeed: true), isTrue);
    });

    test('Watch-данные: SpO₂ медиана ночи, VO₂max, пульс покоя, сон', () {
      final w = WatchData.from(_fixture(), own: _own);
      // 16 замеров Watch 23:00–06:30, медиана 0,96 → 96 %; 0,91 в 21:00 вне
      // окна, 0,90 от Oura — не Watch.
      expect(w.spo2, 96);
      expect(w.spo2N, 16);
      expect(w.vo2, 46.2);
      expect(w.vo2Series, hasLength(6));
      // Свою запись 49 (Ритм) не берём — пульс покоя Watch 52.
      expect(w.rhr, 52);
      // 95+50+60+40+70+30+55+41 = 441 (бодрствование 22 и «в кровати» iPhone не в счёт).
      expect(w.sleepMin, 441);
      expect(w.viaChannel, isTrue);
      expect(w.any, isTrue);
    });

    test('ЭКГ Watch: классификации словами, «фибрилляцию» не пишем', () {
      final w = WatchData.from(_fixture(), own: _own);
      expect(w.ecg, hasLength(3));
      expect(watchEcgText(w.ecg[0].cls, w.ecg[0].hr).text, 'Синусовый ритм · 62');
      final af = watchEcgText(w.ecg[1].cls, w.ecg[1].hr);
      expect(af.text, 'Нерегулярный ритм — покажите врачу');
      expect(af.attention, isTrue);
      for (final c in const [
        'sinusRhythm',
        'atrialFibrillation',
        'inconclusiveLowHeartRate',
        'inconclusiveHighHeartRate',
        'inconclusivePoorReading',
        'inconclusiveOther',
        'unrecognized',
        'notSet',
      ]) {
        expect(watchEcgText(c, 70).text.toLowerCase(), isNot(contains('фибрилл')));
      }
      // Браслет + Watch вперемешку, новые сверху, с подписью источника.
      final list = mergeEcg(
        band: [(at: _at(7, 20, -1), category: 'sinusRhythm', hr: 58)],
        watch: w.ecg,
      );
      expect(list.map((e) => e.source).take(3).toList(), [
        'Apple Watch',
        'браслет',
        'Apple Watch',
      ]);
      expect(list[1].text, 'Синусовый ритм · 58');
      expect(ecgUnclear(watchEcgText('inconclusiveOther', 71).text), isTrue);
      expect(ecgUnclear(list[0].text), isFalse);
    });

    test('тренировка Watch: дистанция, пульс, HRR (замер Watch и по пульсу)', () {
      final w = WatchData.from(_fixture(), own: _own);
      // Тренировка «Ритма» (наша запись) — не тренировка Watch.
      expect(w.workouts, hasLength(1));
      final run = w.workouts.single;
      expect(hkTypeName(run.type), 'Бег');
      expect(hkTypeKey(run.type), 'running');
      expect(distRu(run.distM!), '7,24 км');
      expect(run.hrAvg!.round(), 146);
      // Замер heartRateRecoveryOneMinute Watch в 08:27 — приоритетнее.
      expect(w.hrrOf(run)!.drop, 31);
      expect(w.hrrOf(run)!.source, 'Watch');
      // Без замера — по пульсу после финиша: 158 → 127 через 60 с.
      expect(hrrFromSamples(run.e, run.hrAfter), 31);
      expect(const WorkoutHrr(31, 'Watch').word, 'отлично');
      expect(const WorkoutHrr(15, 'Watch').word, 'обычно');
    });

    test('температура запястья: отклонение последней ночи от медианы', () {
      final w = WatchData.from(_fixture(), own: _own);
      // Медиана прошлых 10 ночей 34,62, последняя 35,05 → +0,43.
      expect(w.wristDev, closeTo(.43, .02));
    });

    test('выключенный тип чтения не попадает в данные', () {
      final w = WatchData.from(
        _fixture(),
        own: _own,
        off: const {'spo2', 'vo2', 'ecg', 'workouts'},
      );
      expect(w.spo2, isNull);
      expect(w.vo2, isNull);
      expect(w.ecg, isEmpty);
      expect(w.workouts, isEmpty);
      expect(w.rhr, 52);
    });

    test('пустой/неверный ответ канала не падает', () {
      final s = HkSnapshot.parse(null);
      expect(s.available, isFalse);
      final w = WatchData.from(HkSnapshot.parse({'available': false, 'spo2': 'x'}));
      expect(w.any, isFalse);
      expect(w.spo2, isNull);
    });
  });

  group('VO₂max и Кардиоформа', () {
    test('оценка по возрасту (ACSM)', () {
      expect(vo2Word(46.2, age: 42), 'отлично для 42 лет');
      expect(vo2Word(40, age: 42), 'хорошо для 42 лет');
      expect(vo2Word(36, age: 42), 'средне для 42 лет');
      expect(vo2Word(30, age: 42), 'ниже среднего для 42 лет');
      expect(vo2Word(36, age: 41, female: true), 'хорошо для 41 года');
      expect(vo2Word(46, age: null), isNull);
    });

    test('дельта к месяцу всегда числом (оговорка B2)', () {
      expect(deltaToMonth(4.2), '↑ +4 к месяцу');
      expect(deltaToMonth(-2.6), '↓ −3 к месяцу');
      expect(deltaToMonth(.4), '↑ +0,4 к месяцу');
      expect(deltaToMonth(-.3), '↓ −0,3 к месяцу');
      expect(deltaToMonth(.02), '0 к месяцу');
      final w = WatchData.from(_fixture(), own: _own);
      // 46,2 сейчас против 45,3 месяц назад (ближайший замер ≥ 21 дня назад).
      expect(vo2DeltaMonth(w.vo2Series), closeTo(.9, 1e-9));
      expect(vo2Form(.9), 0);
      expect(vo2Form(1.2), 1);
    });
  });

  group('классификатор §10.6', () {
    const rhr = 51.0, hrMax = 180.0;

    test('пороги ярусов', () {
      final th = wkThresholds(rhr, hrMax);
      expect(th.soft, closeTo(51 + .3 * 129, 1e-9));
      expect(th.hard, closeTo(51 + .45 * 129, 1e-9));
    });

    test('прогулка 25 мин без Watch → мягкий ярус, «Это была ходьба?»', () {
      final secs = [
        ..._secs(_at(6, 30), 10, hr: (_) => 68, cls: 0, cadence: 0, enmo: .01),
        ..._secs(_at(6, 40), 25, hr: (k) => 99 + k % 4, cls: 1, cadence: 112),
        ..._secs(_at(7, 5), 10, hr: (_) => 70, cls: 0, cadence: 0, enmo: .01),
      ];
      final found = detectWorkouts(secs, rhr: rhr, hrMax: hrMax);
      expect(found, hasLength(1));
      final c = found.single;
      expect(c.hard, isFalse);
      expect(c.type, WkType.walk);
      expect(c.minutes, inInclusiveRange(24, 26));
      expect(wkQuestion(c.type), 'Это была ходьба?');
      expect(wkTypeWord(c.type), 'ходьба');
    });

    test('демо-прогулка симулятора тоже проходит через классификатор', () {
      final c = detectWorkouts(
        demoWalkSecs(DateTime(2026, 10, 15)),
        rhr: rhr,
        hrMax: hrMax,
      ).single;
      expect(c.type, WkType.walk);
      expect(c.hard, isFalse);
    });

    test('прогулка 15 мин — меньше 20 мин мягкого яруса → ничего', () {
      final secs = _secs(_at(6, 40), 15, hr: (_) => 100, cls: 1, cadence: 110);
      expect(detectWorkouts(secs, rhr: rhr, hrMax: hrMax), isEmpty);
    });

    test('без движения пульс высокий (стресс, жара) → не тренировка', () {
      final secs = _secs(
        _at(14, 0),
        30,
        hr: (_) => 100,
        cls: 0,
        cadence: 0,
        enmo: .01,
      );
      expect(detectWorkouts(secs, rhr: rhr, hrMax: hrMax), isEmpty);
    });

    test('бег 45 мин → жёсткий ярус, тип «бег»', () {
      final secs = _secs(_at(7, 40), 45, hr: (k) => 145 + k % 6, cls: 2, cadence: 168);
      final c = detectWorkouts(secs, rhr: rhr, hrMax: hrMax).single;
      expect(c.hard, isTrue);
      expect(c.type, WkType.run);
      expect(wkQuestion(c.type), 'Это был бег?');
    });

    test('силовая 50 мин без Watch → «силовая?» (пики с падением ≥ 15)', () {
      // Подход 50 с (пульс 90 → 150), за 20 с падает до 90, отдых 80 с.
      int hr(int k) {
        final p = k % 150;
        if (p < 50) return 90 + (60 * p / 50).round();
        if (p < 70) return 150 - (60 * (p - 50) / 20).round();
        return 90;
      }

      final secs = _secs(_at(12, 30), 50, hr: hr, cls: 0, cadence: 4, enmo: .15);
      final c = detectWorkouts(secs, rhr: rhr, hrMax: hrMax).single;
      expect(c.type, WkType.strength);
      expect(hrPeaks(secs), greaterThanOrEqualTo(4));
      expect(wkQuestion(c.type), 'Это была силовая?');
    });

    test('ровное кардио без шагов → «кардио»', () {
      final secs = _secs(_at(19, 0), 30, hr: (k) => 120 + k % 3, cls: 0, cadence: 0, enmo: .2);
      final c = detectWorkouts(secs, rhr: rhr, hrMax: hrMax).single;
      expect(c.type, WkType.cardio);
    });

    test('во сне тренировок не ищем', () {
      final secs = _secs(_at(3, 0), 30, hr: (_) => 100, cls: 1, cadence: 100);
      final from = _at(0, 0).millisecondsSinceEpoch ~/ 1000;
      expect(
        detectWorkouts(
          secs,
          rhr: rhr,
          hrMax: hrMax,
          sleep: [(from: from, to: from + 7 * 3600)],
        ),
        isEmpty,
      );
    });
  });

  group('приоритет Watch и отклонённые (§6, §10.6)', () {
    final watchRun = HkWorkout(s: _at(7, 40), e: _at(8, 26), type: 37, distM: 7240);

    test('пересечение с Watch ≥ 50 % → авто, без карточки', () {
      expect(
        wkAction(_at(7, 45), _at(8, 30), watch: [watchRun]),
        WkAction.autoWatch,
      );
      expect(watchMatch(_at(7, 45), _at(8, 30), [watchRun]), watchRun);
    });

    test('пересечение < 50 % → карточка', () {
      // 08:10–09:10 пересекает 16 мин из 60.
      expect(wkAction(_at(8, 10), _at(9, 10), watch: [watchRun]), WkAction.ask);
      expect(overlapShare(_at(8, 10), _at(9, 10), watchRun.s, watchRun.e), closeTo(16 / 60, 1e-9));
    });

    test('«Нет» не предлагается повторно', () {
      final from = _at(6, 42);
      expect(
        wkAction(
          from,
          _at(7, 9),
          watch: const [],
          dismissed: {from.millisecondsSinceEpoch ~/ 1000},
        ),
        WkAction.dismissed,
      );
    });

    test('мягкий ярус: без жёстких (у них карточка Edge), сохранённых и Watch', () {
      int ts(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
      final found = [
        WkCandidate(ts(_at(6, 42)), ts(_at(7, 9)), WkType.walk, 100),
        WkCandidate(ts(_at(7, 40)), ts(_at(8, 26)), WkType.run, 146),
        WkCandidate(ts(_at(12, 0)), ts(_at(12, 40)), WkType.run, 150, hard: true),
        WkCandidate(ts(_at(17, 0)), ts(_at(17, 30)), WkType.walk, 98),
      ];
      final soft = softCandidates(
        found,
        busy: [(from: ts(_at(17, 5)), to: ts(_at(17, 40)))],
        watch: [watchRun],
      );
      expect(soft.map((c) => c.from), [ts(_at(6, 42))]);
    });
  });

  group('сверка браслет / Watch §10.9', () {
    test('пульс покоя: две цифры за ночь и пороги', () {
      final w = WatchData.from(_fixture(), own: _own);
      expect(reconcileRhr(51, w.rhr!), Agree.match); // браслет 51 · Watch 52
      expect(reconcileRhr(51, 56), Agree.differ);
      expect(reconcileRhr(51, 58), Agree.check);
      expect(agreeWord(reconcileRhr(51, 58)), 'проверьте посадку браслета');
    });

    test('сон: ±20 / 21–45 / > 45 мин', () {
      expect(reconcileSleep(452, 441), Agree.match);
      expect(reconcileSleep(452, 420), Agree.differ);
      expect(reconcileSleep(452, 400), Agree.check);
    });

    test('температура: совпадение знака отклонения', () {
      expect(reconcileTemp(.1, -.2), Agree.match);
      expect(tempWords(.1, -.2), 'оба в норме');
      expect(reconcileTemp(.4, .43), Agree.match);
      expect(tempWords(.4, .43), 'оба выше обычного');
      expect(reconcileTemp(.4, -.5), Agree.differ);
    });

    test('тренировка: точнее тот, у кого больше секунд с пульсом', () {
      final w = WatchData.from(_fixture(), own: _own).workouts.single;
      final r = workoutHrWinner(
        bandShare: .91,
        watchN: w.hrN,
        seconds: w.e.difference(w.s).inSeconds,
      );
      expect(r.winner, 'Watch');
      expect(r.watchShare, 1.0);
      expect(
        workoutHrLine(bandAvg: 138, watchAvg: 146, winner: r.winner),
        'пульс ср. браслет 138 · Watch 146 · точнее Watch (больше секунд с пульсом)',
      );
      expect(
        workoutHrWinner(bandShare: .98, watchN: 200, seconds: 2760).winner,
        'браслет',
      );
      expect(workoutHrWinner(bandShare: .97, watchN: 540, seconds: 2760).winner, 'оба');
    });

    test('Watch не носился ночью', () {
      expect(reconcileSummary(), 'Watch не носился ночью');
    });
  });

  group('шаги §10.10', () {
    test('Watch весь день (≥ 12 ч) → Здоровье, без сложения', () {
      final r = ritmSteps(
        watch: 11850,
        watchHours: 15,
        band: 11200,
        now: DateTime(2026, 10, 15, 22),
      );
      expect(r.value, 11850);
      expect(r.source, 'Apple Watch');
    });

    test('утром 09:41: Watch 10 ч (< 12) → браслет, не Watch', () {
      final s = _fixture();
      final r = ritmSteps(
        watch: s.steps.watch,
        watchHours: s.steps.watchHours,
        band: 10260,
        now: _now,
      );
      expect(r.value, 10260);
      expect(r.source, 'браслет');
    });

    test('Watch 6 ч к вечеру → браслет', () {
      final r = ritmSteps(
        watch: 4100,
        watchHours: 6,
        band: 9800,
        now: DateTime(2026, 10, 15, 21),
      );
      expect(r.value, 9800);
      expect(r.source, 'браслет');
    });

    test('браслет снят → телефон', () {
      final r = ritmSteps(band: 300, phone: 5200, bandWorn: false, now: _now);
      expect(r.source, 'телефон');
      expect(r.value, 5200);
    });

    test('прошлый день: нужно 12 ч ношения', () {
      final r = ritmSteps(
        watch: 9000,
        watchHours: 11,
        band: 8700,
        now: _now,
        today: false,
      );
      expect(r.source, 'браслет');
    });
  });

  group('запись в «Здоровье» §10.11', () {
    final watchRun = HkWorkout(s: _at(7, 40), e: _at(8, 26), type: 37);

    test('тренировка браслета при тренировке Watch не пишется (нет дубля в «Фитнесе»)', () {
      expect(ritmMayWriteWorkout(_at(7, 42), _at(8, 25), [watchRun]), isFalse);
      // Даже частичное пересечение — не пишем.
      expect(ritmMayWriteWorkout(_at(8, 20), _at(9, 0), [watchRun]), isFalse);
      expect(ritmMayWriteWorkout(_at(18, 0), _at(18, 40), [watchRun]), isTrue);
      expect(ritmMayWriteWorkout(_at(18, 0), _at(18, 40), const []), isTrue);
    });

    test('калории: при Watch — выключены', () {
      expect(ritmMayWriteEnergy(toggle: true, watchPresent: true), isFalse);
      expect(ritmMayWriteEnergy(toggle: true, watchPresent: false), isTrue);
      expect(ritmMayWriteEnergy(toggle: false, watchPresent: false), isFalse);
    });

    test('ворота записи: калории закрываются, когда Watch встречался', () {
      Prefs.setBool(kRitmWatchPresentKey, false);
      expect(RitmWriteGate.allows(RitmWriteKind.energy), isTrue);
      Prefs.setBool(kRitmWatchPresentKey, true);
      expect(RitmWriteGate.allows(RitmWriteKind.energy), isFalse);
      // Остальные типы не трогаем.
      expect(RitmWriteGate.allows(RitmWriteKind.sleep), isTrue);
      Prefs.setBool(kRitmWatchPresentKey, false);
    });
  });

  group('Монитор здоровья: SpO₂ из Watch', () {
    test('пороги 95/93 и подпись «Watch»', () {
      final r = monitorRow(MonKind.spo2, history: const [], last: 96);
      expect(r.value, '96');
      expect(r.note, 'норма 95–100 · Watch');
      expect(r.status, MonStatus.ok);
      expect(
        monitorRow(MonKind.spo2, history: const [], last: 94).status,
        MonStatus.warn,
      );
      expect(
        monitorRow(MonKind.spo2, history: const [], hasSource: false).note,
        'нет источника: нужны Apple Watch',
      );
    });
  });
}
