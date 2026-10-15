// Демо-данные «Ритма» для скриншотов в симуляторе.
//
// Работают ТОЛЬКО в DEBUG-сборке и ТОЛЬКО с --dart-define=RITM_DEMO=true.
// В Release `kDebugMode == false`, и `ritmDemoHome` всегда возвращает null —
// компилятор выкидывает эту ветку целиком.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/day_label.dart' show dayLabelOf;
import '../models/metric.dart';
import '../ui2/screens/health_screen.dart' show HealthData;
import '../ui2/screens/home_screen.dart' show ChartPoint, HomeData;
import 'ritm_charts.dart' show WeekDayPoint;
import 'ritm_detail.dart' show RitmSleepView, RitmStrainView;
import 'ritm_home.dart' show RitmHomeSnapshot, RitmSuggestion;
import 'ritm_metrics.dart' show RitmMetricValues;
import 'ritm_scores.dart' show ritmRecovery, ritmSleepPct;
import 'ritm_stress.dart';
import 'ritm_devices.dart' show BandCaps, BandModel;
import 'ritm_rings.dart';
import 'ritm_rings_store.dart' show RingDayInputs, RitmRingsDay;
import 'ritm_night.dart' show RitmNightData;
import 'ritm_sleep.dart' show SleepScore, Stage, StageRun, nightStressOf, signalOf, sleepScoreV2, stressFracOf;
import 'ritm_sources.dart' show RitmSourcesData;
import 'ritm_hk.dart' show detectWorkouts;
import 'ritm_bioage.dart' show BioDay, ageOn;
import 'ritm_watch.dart' show WatchNight;
import 'ritm_workout.dart' show demoWalkSecs;

const bool _kDemoDefine = bool.fromEnvironment('RITM_DEMO');

/// Сценарий утра для скрина «считаю»: --dart-define=RITM_DEMO_NIGHT=computing.
const String _kDemoNight = String.fromEnvironment('RITM_DEMO_NIGHT');

/// Фото для аватара в демо (файл на диске Mac, симулятор его видит).
const String _kDemoAvatar = String.fromEnvironment('RITM_DEMO_AVATAR');

/// Путь к фото аватара в демо или null.
String? ritmDemoAvatarPath() =>
    kRitmDemo && _kDemoAvatar.isNotEmpty ? _kDemoAvatar : null;

/// Демо включено (только DEBUG + define).
bool get kRitmDemo => kDebugMode && _kDemoDefine;

/// Шаг автопилота для скриншотов: −1 — стоим. 0–2 сегодня (верх, «Мой день»,
/// «Мои показатели»), 3–5 прошлые дни (жёлтый, красный, калибровка),
/// 6 «Здоровье», 7 «Ещё», 8 «Источники и сверка», 9 «Значок», 10 «О приложении»,
/// 11 «Профиль», 12 «Браслет», 13 «Помощник», 14 «Источники» внизу (сверка),
/// 15–19 экраны Edge в теме «Ритма»: профиль, уведомления, данные, ключ помощника, будильник.
/// B2: 20 главная внизу (стресс, 7 дней), 21 Сон, 22 Восстановление,
/// 23 Нагрузка, 24 Монитор стресса, 25 Монитор здоровья подробно,
/// 26 «Настроить» показатели, 27 «Данные» (импорт CSV WHOOP, засев).
/// B3 (данные Watch — по Swift-каналу): 28 «Мой день» (бег с Watch +
/// карточка мягкого яруса), 29 «Здоровье» внизу (сверка, ЭКГ), 30 «Здоровье»
/// верх (SpO₂, VO₂max), 31 экран тренировки (HRR), 32 «Мои показатели»
/// (VO₂max, шаги Watch), 33–35 «Источники» (верх, чтение/запись, сверка),
/// 36 «Проверка канала Здоровья», 37 «Другой тип» (пикер).
/// B4: 38 «Здоровье» герой (облачко), 39 темп + Кардиоформа, 40–42 экран
/// «Биовозраст» (верх, 8 вкладов, «Как считается»), 43–44 калибровка
/// (< 14 дней), 45 профиль (дата рождения), 46 главная, 47 «Мой день»
/// (отбой), 48 «Мои показатели», 49–50 тренировка (пульс по зонам),
/// 51–52 вчера, 53 Монитор здоровья подробно, 54 ЭКГ, 55 герой без даты
/// рождения («укажите дату рождения»).
/// B4½: 56 главная (кольца v3, источник, таймлайн, коридор), 57–58
/// «Восстановление» (5 факторов; вклады и калибровка), 59–60 «Источники»
/// (модель, второе устройство; сверка браслет/Watch, вход в сверку), 61–64
/// «Сверка с WHOOP» (итог, по дням, вкладка «Сон», калибровка), 65 — без
/// общих дней (как у Михаила сейчас), 66–68 «Здоровье» — 3D-шар (0/9/18 с),
/// 69 «Источники» с предупреждением D4 (приложение WHOOP пишет в «Здоровье»).
final ritmDemoStep = ValueNotifier<int>(
  const int.fromEnvironment('RITM_DEMO_FROM', defaultValue: 0) - 1,
);
const int kRitmDemoLastStep = 95;
Timer? _autopilot;

/// Запустить автопилот (DEBUG + RITM_DEMO + RITM_DEMO_AUTOPILOT).
void startRitmDemoAutopilot() {
  if (!kRitmDemo || !const bool.fromEnvironment('RITM_DEMO_AUTOPILOT')) return;
  // Номер шага — в файл во временной папке приложения: скрипт съёмки ждёт
  // его, а не часы (таймер в DEBUG отстаёт под нагрузкой шейдера).
  if (_autopilot == null) {
    ritmDemoStep.addListener(() {
      try {
        File('${Directory.systemTemp.path}/ritm_demo_step').writeAsStringSync('${ritmDemoStep.value}');
      } catch (_) {}
    });
  }
  _autopilot ??= Timer.periodic(const Duration(seconds: 8), (t) {
    if (ritmDemoStep.value >= kRitmDemoLastStep ||
        ritmDemoStep.value >=
            const int.fromEnvironment('RITM_DEMO_TO', defaultValue: 999)) {
      t.cancel();
      return;
    }
    ritmDemoStep.value++;
  });
}

Metric _m(num v, [String? unit]) =>
    Metric(value: v, unit: unit, confidence: .9, tier: MetricTier.high);

Metric _note(String note) => Metric(note: note);

/// «Сейчас» для демо — 09:41 сегодня (как в строке состояния симулятора).
DateTime? ritmDemoNow() {
  if (!kRitmDemo) return null;
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, 9, 41);
}

/// Снимок главной для дня [day] (null — сегодня) или null вне демо.
RitmHomeSnapshot? ritmDemoHome(String? day) {
  if (!kRitmDemo) return null;
  final now = DateTime.now();
  String id(int back) =>
      dayLabelOf(DateTime(now.year, now.month, now.day - back));
  final days = [for (var i = 0; i < 17; i++) id(i)];
  final back = day == null ? 0 : days.indexOf(day).clamp(0, 99);
  final today = DateTime(now.year, now.month, now.day);

  Map<String, dynamic> session(
    int h,
    int m,
    int dur,
    String type,
    double strain, {
    String source = 'manual',
    int? avgHr,
    double? validShare,
  }) => {
    'start_ts':
        today
            .subtract(Duration(days: back))
            .add(Duration(hours: h, minutes: m))
            .millisecondsSinceEpoch ~/
        1000,
    'duration_min': dur,
    'type': type,
    'strain': strain,
    'source': source,
    'avg_hr': ?avgHr,
    'hr_valid_share': ?validShare,
  };

  final HomeData d;
  var sessions = <Map<String, dynamic>>[];
  if (back == 0 && _kDemoNight == 'computing') {
    // 07:05: проснулся, ночь ещё не закрыта, последние данные 25 мин назад.
    return RitmHomeSnapshot(
      d: HomeData(
        name: 'Михаил',
        dayId: id(0),
        readiness: const Metric(),
        sleepMin: const Metric(),
        sleepNeedMin: _m(537, 'min'),
        rhr: _m(51),
        steps: _m(320),
        strain: _m(0.8),
        illnessState: 'green',
        recoveryState: 'night_in_progress',
      ),
      days: days,
      battery: (pct: 86, charging: false),
      alarmAt: DateTime(now.year, now.month, now.day + 1, 7, 30),
      alarmOn: true,
      dataEdge: DateTime(now.year, now.month, now.day, 9, 16),
      syncing: true,
    );
  }
  switch (back % 4) {
    case 0: // зелёный день
      d = HomeData(
        name: 'Михаил',
        dayId: id(back),
        readiness: _m(62.05),
        drivers: const [
          {'label': 'hrv', 'contribution': 0.9},
          {'label': 'rhr', 'contribution': 0.4},
        ],
        sleepMin: _m(452, 'min'),
        sleepNeedMin: _m(537, 'min'),
        bedtime: _m(22 * 60 + 25),
        rhr: _m(51),
        steps: _m(10520),
        calories: _m(180),
        caloriesTotal: _m(1420),
        // Ходьба 1,6 + бег 10,0 (формула Edge: 46 мин @145) → день 10,8.
        strain: _m(demoStrainBack(0)),
        illnessState: 'green',
      );
      sessions = [
        // Бег: браслет 141 (пульс в 91 % секунд) — Watch 145 по каналу.
        session(7, 40, 46, 'running', 10.0, avgHr: 141, validShare: .91),
      ];
    case 1: // жёлтый день, недосып
      d = HomeData(
        name: 'Михаил',
        dayId: id(back),
        readiness: _m(44.9),
        drivers: const [
          {'label': 'rhr', 'contribution': -0.7},
        ],
        sleepMin: _m(372, 'min'),
        sleepNeedMin: _m(497, 'min'),
        bedtime: _m(22 * 60 + 10),
        rhr: _m(55),
        steps: _m(11204),
        calories: _m(910),
        caloriesTotal: _m(2780),
        // Силовая 9,7 + лёгкий велосипед 6,5 (47 мин @122) → день 12,8.
        strain: _m(demoStrainBack(1)),
        illnessState: 'amber',
      );
      sessions = [
        session(12, 30, 58, 'weight_training', 9.7),
        session(18, 5, 47, 'cycling', 6.5, source: 'auto', avgHr: 122),
      ];
    case 2: // красный день
      d = HomeData(
        name: 'Михаил',
        dayId: id(back),
        readiness: _m(30.8),
        drivers: const [
          {'label': 'hrv', 'contribution': -1.2},
        ],
        sleepMin: _m(301, 'min'),
        sleepNeedMin: _m(505, 'min'),
        bedtime: _m(21 * 60 + 55),
        rhr: _m(59),
        steps: _m(4120),
        calories: _m(310),
        caloriesTotal: _m(2050),
        strain: _m(demoStrainBack(2)),
        illnessState: 'red',
      );
    default: // калибровка (первые ночи)
      d = HomeData(
        name: 'Михаил',
        dayId: id(back),
        readiness: _note('need_baseline:have=13,need=14'),
        sleepMin: _m(428, 'min'),
        sleepNeedMin: _m(486, 'min'),
        rhr: _m(53),
        steps: _m(6230),
        calories: _m(420),
        caloriesTotal: _m(2210),
        strain: _m(demoStrainBack(back)),
        illnessState: 'green',
      );
  }
  return RitmHomeSnapshot(
    // Эффективность 94 % (как экран «Сон»): 8:09 сна = 8:40 в кровати.
    effPct: 94,
    d: d,
    days: days,
    sessions: sessions,
    battery: (pct: 87, charging: false),
    alarmAt: DateTime(now.year, now.month, now.day + 1, 7, 30),
    alarmOn: back == 0,
    pendingActivities: 0,
    // Прогулка 06:42–07:09 без Watch: классификатор §10.6 на секундах браслета
    // (мягкий ярус → карточка «Это была ходьба?»).
    soft: back == 0
        ? [
            for (final c in detectWorkouts(
              demoWalkSecs(today),
              rhr: 51,
              hrMax: 180,
            ))
              RitmSuggestion.soft(c),
          ]
        : const [],
    dataEdge: DateTime(now.year, now.month, now.day, 9, 38),
    rings: back == 0 ? ritmDemoRings(today) : null,
    stress: back == 0 ? ritmDemoStress() : null,
    week: _demoWeek(back),
    health: ritmDemoHealth(),
    metrics: back == 0
        ? const RitmMetricValues(
            hrv: 58,
            hrvNorm: 50,
            rhr: 51,
            rhrMean30: 52.3,
            steps: 10520,
            kcal: 1420,
            // Неделя ≥ дня (сегодня зоны 1–3 = 2:15): 2:28, всё ещё «75–150 мин».
            z13: 148,
            z45: 35,
            strength: 58,
          )
        : back == 1
        // Вчера: неделя «вчера и 6 дней до» известна — без прочерков.
        ? const RitmMetricValues(
            hrv: 41,
            hrvNorm: 50,
            rhr: 55,
            rhrMean30: 52.1,
            steps: 11204,
            kcal: 2780,
            z13: 138,
            z45: 38,
            strength: 58,
          )
        : null,
    hrv: switch (back % 4) {
      0 => 58,
      1 => 41,
      2 => 33,
      _ => 47,
    },
  );
}

/// Демо «Здоровья» (только DEBUG + RITM_DEMO), иначе null — экран читает базу.
HealthData? ritmDemoHealth() {
  if (!kRitmDemo) return null;
  final now = DateTime.now();
  Map<String, dynamic> env(num v) => {
    'value': v,
    'confidence': .9,
    'tier': 'HIGH',
  };
  List<ChartPoint> series(double base, double amp, int seed) => [
    for (var i = 29; i >= 0; i--)
      (
        t:
            DateTime(
              now.year,
              now.month,
              now.day - i,
              12,
            ).millisecondsSinceEpoch ~/
            1000,
        // Плавные ночные колебания, как у живого ряда (не пила).
        v:
            base +
            amp *
                (.55 * math.sin(i * .9 + seed) +
                    .3 * math.sin(i * 2.3 + seed * 1.7) +
                    .15 * math.sin(i * .31 + seed)),
      ),
  ];
  return HealthData(
    today: {
      'status': {'today_day': dayLabelOf(now)},
      'daily': {'resting_hr': env(51)},
      'hrv': {'rmssd': 58, 'confidence': .9, 'tier': 'HIGH'},
      'sleep': {'duration_min': env(452)},
      'resp': env(14.2),
      'skin_temp': {
        'value': .3,
        'dev_c': .2,
        'confidence': .8,
        'tier': 'RELATIVE',
      },
      'illness': {'state': 'green', 'date': dayLabelOf(now)},
    },
    charts: {
      // Вчера пульс покоя 55 (выше коридора — жёлтая точка), сегодня 51:
      // те же числа, что на главной за вчера и сегодня.
      'resting_hr': [
        ...series(52, 2, 1).sublist(0, 28),
        (t: series(52, 2, 1)[28].t, v: 55.0),
        (t: series(52, 2, 1)[29].t, v: 51.0),
      ],
      // ВСР: вчера 41 (ниже коридора — как в «Моих показателях» за вчера),
      // сегодня 58 (как на плитке). Средние 7/30 дней остаются 49/50.
      'hrv': [
        ...series(50, 6, 3).sublist(0, 28),
        (t: series(50, 6, 3)[28].t, v: 41.0),
        (t: series(50, 6, 3)[29].t, v: 58.0),
      ],
      'sleep': series(440, 35, 5),
      'resp_rate': series(14.2, .5, 2),
      'skin_temp_dev_c': series(0, .15, 4),
    },
    daysWithData: 30,
  );
}

/// Демо «Источников и сверки» (только DEBUG + RITM_DEMO).
RitmSourcesData? ritmDemoSources() {
  if (!kRitmDemo) return null;
  final n = DateTime.now();
  return RitmSourcesData(
    caps: const BandCaps(model: BandModel.whoopMg, firmware: '50.36.2.0', serial: 'demo', origin: 'hello'),
    bandSteps: 10520, // = «Мои показатели» (браслет); Watch 10 860 — −3 %
    model: 'WHOOP 5.0 MG',
    bandName: 'WHOOP 5.0 MG',
    paired: true,
    connected: true,
    battery: 87,
    lastSync: DateTime(n.year, n.month, n.day, 9, 37),
    healthAsked: true,
    bandRhr: 51,
    bandSleepMin: 452,
    bandTempDev: .2,
    bandWorkout: (
      start: DateTime(n.year, n.month, n.day, 7, 40),
      end: DateTime(n.year, n.month, n.day, 8, 26),
      avgHr: 141,
      validShare: .91,
    ),
    readWorkouts: true,
    writeOn: false,
    phoneSteps: true,
  );
}

/// Демо ночи Apple Watch: с B3 данные Watch в демо идут ТОЛЬКО через
/// Swift-канал (засев «Здоровья» симулятора), заглушки Dart нет.
WatchNight? ritmDemoWatch() => null;

/// Демо-дата рождения (возраст нигде не зашит числом: считается от неё).
DateTime? ritmDemoBirth() => kRitmDemo ? DateTime(1989, 3, 21) : null;

/// Возраст для оценки VO₂max в демо — из демо-даты рождения.
int? ritmDemoAge() {
  final b = ritmDemoBirth();
  return b == null ? null : ageOn(b, DateTime.now());
}

/// Сценарий «нет даты рождения» (шаг 55): биовозраст не считается.
final ritmDemoNoBirth = ValueNotifier<bool>(false);

/// Сценарий «калибровка» биовозраста (< 14 дней с браслетом) — переключает
/// автопилот на своём шаге.
final ritmDemoBioCalib = ValueNotifier<bool>(
  const String.fromEnvironment('RITM_DEMO_BIO') == 'calib',
);

/// Демо-история для биовозраста §10.7: 120 дней (или 6 дней в калибровке).
/// Сон медленно растёт (6:12 → 6:20 в среднем), режим «плавает» (±67 мин),
/// шаги ≈ 7 300, зоны 1–3 ≈ 2:10 и 4–5 ≈ 0:35 в неделю, силовые 2×29 мин,
/// пульс покоя ≈ 52, VO₂max Watch 44,8 → 46,2 (как засев «Здоровья»).
List<BioDay>? ritmDemoBio() {
  if (!kRitmDemo) return null;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  const n = 120;
  const vo2 = [44.8, 45.0, 45.3, 45.6, 45.9, 46.2]; // дни −75, −60 … 0
  final calib = ritmDemoBioCalib.value;
  return [
    for (var i = 0; i < n; i++)
      () {
        final back = n - 1 - i;
        final d = today.subtract(Duration(days: back));
        if (calib && back >= 6) return BioDay(d);
        final noise =
            .55 * math.sin(i * .9 + 5) +
            .3 * math.sin(i * 2.3 + 8.5) +
            .15 * math.sin(i * .31 + 5);
        final sleep = back == 0 ? 452.0 : 372 + .00035 * i * i + 12 * noise;
        final onset = 23 * 60 + 95 * math.sin(i * 1.7);
        double? v2;
        for (var k = 0; k < vo2.length; k++) {
          if (back <= 75 - 15 * k) v2 = vo2[k];
        }
        return BioDay(
          d,
          sleepMin: sleep,
          onsetMin: onset,
          wakeMin: onset + sleep + 31,
          steps: back == 0 ? 10520 : 7300 + 600 * math.sin(i * 1.3),
          z13: 18.6 + 6 * math.sin(i * .7),
          z45: (i % 7 == 2 || i % 7 == 5) ? 17.5 : 0,
          strength: (i % 7 == 1 || i % 7 == 4) ? 29 : 0,
          rhr: back == 0 ? 51 : (back == 1 ? 55 : 52 + 1.5 * math.sin(i * .8)),
          vo2: v2 ?? 44.8,
        );
      }(),
  ];
}

/// Демо записей ЭКГ браслета (MG; в симуляторе браслета нет).
List<({DateTime at, String category, int? hr})>? ritmDemoBandEcg() {
  if (!kRitmDemo) return null;
  final n = DateTime.now();
  return [
    (at: DateTime(n.year, n.month, n.day - 1, 7, 20), category: 'sinusRhythm', hr: 58),
    (at: DateTime(n.year, n.month, n.day - 4, 22, 5), category: 'sinusRhythm', hr: 61),
  ];
}

/// Демо 7 дней — те же дни, что листаются на главной (нагрузка и кольцо
/// восстановления считаются той же функцией, что и кольца).
/// Для теста «бар дня = Нагрузка дня».
@visibleForTesting
List<WeekDayPoint> demoWeekForTest(int endBack) => _demoWeek(endBack);

List<WeekDayPoint> _demoWeek(int endBack) {
  final now = DateTime.now();
  // Сегодня и вчера — как кольца на главной; раньше — обычная неделя.
  // Те же числа, что у экранов дней (кнопка «‹» на главной): сегодня 10,8,
  // вчера 12,8, позавчера (красный) 4,2, дальше — дни калибровки (13 из 14
  // ночей: Восстановления ещё нет, Нагрузка — по _kDemoStrainBack).
  const ready = <int, (double, int, int)>{
    0: (62.05, 452, 489),
    1: (44.9, 372, 497),
    2: (30.8, 301, 505),
  };
  return [
    for (var i = 0; i < 7; i++)
      () {
        final back = endBack + 6 - i;
        final r = ready[back];
        return WeekDayPoint(
          DateTime(now.year, now.month, now.day - back),
          strain: demoStrainBack(back),
          recovery: r == null
              ? null
              : ritmRecovery(r.$1, sleepPct: ritmSleepPct(r.$2, r.$3))?.toDouble(),
        );
      }(),
  ];
}

/// Демо Монитора стресса за сегодня: сон до 06:42, ходьба 06:42–07:09 и бег
/// 07:40–08:26 (без значений), спокойная работа 08:30–09:41.
StressDay? ritmDemoStress() {
  if (!kRitmDemo) return null;
  final now = DateTime.now();
  final start =
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
  int at(int h, int m) => start + h * 3600 + m * 60;
  final pts = <StressPoint>[];
  for (var t = at(0, 5); t <= at(9, 41); t += 60) {
    if (t < at(6, 42)) {
      pts.add(StressPoint(t, null, StressGap.sleep));
    } else if (t < at(7, 9)) {
      pts.add(StressPoint(t, null, StressGap.motion));
    } else if (t < at(7, 40)) {
      final k = (t - at(7, 9)) ~/ 60;
      pts.add(StressPoint(t, 0.8 + 0.12 * math.sin(k / 4), StressGap.none));
    } else if (t < at(8, 30)) {
      pts.add(StressPoint(t, null, StressGap.workout));
    } else {
      final k = (t - at(8, 30)) ~/ 60;
      // После бега стресс выше, к 09:40 — средний 1,4.
      final base = 1.9 - 0.5 * (k / 71);
      pts.add(
        StressPoint(
          t,
          base + 0.15 * math.sin(k / 5) + 0.06 * math.sin(k / 1.7),
          StressGap.none,
        ),
      );
    }
  }
  final fixed = StressPoint(pts.last.t, 1.4, StressGap.none);
  pts[pts.length - 1] = fixed;
  return StressDay(points: pts, latest: fixed, calDays: kStressCalDays);
}

/// Демо последней сессии дыхания с замером до/после.
({double pre, double post, DateTime at})? ritmDemoBreath() {
  if (!kRitmDemo) return null;
  final n = DateTime.now();
  return (pre: 41, post: 55, at: DateTime(n.year, n.month, n.day, 9, 12));
}

/// Демо экрана «Сон» за сегодняшнюю ночь (7:32 из 8:09).
RitmSleepView? ritmDemoSleepView() {
  if (!kRitmDemo) return null;
  final n = DateTime.now();
  final t0 = DateTime(n.year, n.month, n.day);
  return RitmSleepView(
    tst: 452,
    need: 537,
    awake: 31,
    light: 236,
    deep: 98,
    rem: 118,
    inBed: 483,
    effPct: 94,
    wakes: 3,
    latency: 9,
    debt: 67,
    strainAdd: 19,
    napCredit: 0,
    watchMin: 441,
    // Отбой 23:00 → подъём 07:03 (в кровати 8:03), как в кольцах демо.
    onset: t0.subtract(const Duration(hours: 1)),
    wake: t0.add(const Duration(hours: 7, minutes: 3)),
    wakesShort: 4,
    score: ritmDemoSleepScore(),
    stagesConf: 'med',
    tonightNeed: 516,
    tonightWake: t0.add(const Duration(days: 1, hours: 7, minutes: 3)),
  );
}

/// Оценка сна демо-ночи (одна на главной, «Сне» и «Восстановлении»).
SleepScore ritmDemoSleepScore() => sleepScoreV2(
  tstMin: 452,
  needMin: 537,
  consistency: 81,
  effPct: 94,
  stressFrac: stressFracOf(ritmDemoNightData().stress),
)!;

/// B4¾: демо «Ночь» 23:00–07:03 — 5 циклов, глубокий в начале, быстрый к утру;
/// 3 пробуждения ≥ 5 мин + 4 коротких; пульс, ВСР (5 мин) согласованы со стадиями.
RitmNightData? ritmDemoNight() => kRitmDemo ? ritmDemoNightData() : null;

RitmNightData ritmDemoNightData() {
  final n = DateTime.now();
  final t0 = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch ~/ 1000 - 3600;
  // (минуты от 23:00, стадия) — суммы: бодр. 31, лёгкий 236, глубокий 98, быстрый 118.
  const plan = <(int, Stage)>[
    (9, Stage.wake), (24, Stage.light), (38, Stage.deep), (14, Stage.light), (12, Stage.rem),
    (1, Stage.wake), (22, Stage.light), (32, Stage.deep), (16, Stage.light), (20, Stage.rem),
    (5, Stage.wake), (30, Stage.light), (18, Stage.deep), (20, Stage.light), (26, Stage.rem),
    (2, Stage.wake), (17, Stage.light), (2, Stage.wake), (17, Stage.light), (10, Stage.deep),
    (24, Stage.light), (28, Stage.rem), (5, Stage.wake), (18, Stage.light), (1, Stage.wake),
    (18, Stage.light), (32, Stage.rem), (5, Stage.wake), (16, Stage.light), (1, Stage.wake),
  ];
  final runs = <StageRun>[];
  var t = t0;
  for (final p in plan) {
    runs.add((from: t, to: t + p.$1 * 60, stage: p.$2));
    t += p.$1 * 60;
  }
  Stage at(int x) => runs.lastWhere((r) => r.from <= x, orElse: () => runs.first).stage ?? Stage.light;
  final hr = <TV>[], hrv = <TV>[];
  for (var x = t0; x < t; x += 60) {
    final k = (x - t0) / (t - t0);
    final s = at(x);
    final base = 56 - 6 * math.sin(k * math.pi); // минимум в середине ночи
    final add = switch (s) {
      Stage.wake => 9.0,
      Stage.rem => 4.0,
      Stage.light => 1.0,
      Stage.deep => -2.0,
    };
    final hole = x > t0 + 300 * 60 && x < t0 + 307 * 60; // браслет сдвинулся — 7 мин без пульса
    if (!hole) hr.add(TV(x, base + add + 1.5 * math.sin(x / 437)));
    if ((x - t0) % 300 == 0) {
      final r = switch (s) {
        Stage.deep => 62.0,
        Stage.light => 48.0,
        Stage.rem => 38.0,
        Stage.wake => 30.0,
      };
      hrv.add(TV(x, r + 6 * math.sin(x / 911)));
    }
  }
  return RitmNightData(
    from: t0,
    to: t,
    stages: runs,
    hr: hr,
    hrv: hrv,
    stress: nightStressOf(hr, hrv),
    signal: signalOf(hr, t0, t),
    stagesConf: 'med',
  );
}

/// Демо экрана «Нагрузка» за сегодня (10,8 к 09:41: ходьба + бег).
RitmStrainView? ritmDemoStrainView() {
  if (!kRitmDemo) return null;
  final n = DateTime.now();
  int at(int h, int m) =>
      DateTime(n.year, n.month, n.day, h, m).millisecondsSinceEpoch ~/ 1000;
  return RitmStrainView(
    curve: [
      (t: at(6, 50), v: 0.6),
      (t: at(7, 0), v: 1.2),
      (t: at(7, 9), v: 1.6),
      (t: at(7, 50), v: 4.1),
      (t: at(8, 0), v: 6.2),
      (t: at(8, 10), v: 8.0),
      (t: at(8, 20), v: 9.6),
      (t: at(8, 26), v: 10.3),
      (t: at(9, 10), v: 10.8),
    ],
    sessions: const [
      (name: 'Бег', time: '07:40–08:26 · 46 мин', strain: 10.0),
    ],
    // Зоны дня по доле резерва (покой 51, макс 182) ≥ зон бега (0:01/0:18/0:28/0/0).
    zones: const [64, 40, 31, 6, 0],
    kcal: 1420,
  );
}


/// B4½: кольца v3 демо-«сегодня» (09:41): Восстановление 78 % по §7.2 с
/// калиброванными θ (вклады — по той же формуле), Нагрузка 10,8 по ряду
/// «браслет 8 ч 40 мин + Watch 46 мин» (бег 07:40–08:26), душ 06:50–07:05 без браслета.
RitmRingsDay ritmDemoRings(DateTime today) {
  final t0 = today.millisecondsSinceEpoch ~/ 1000;
  int at(int h, int m) => t0 + h * 3600 + m * 60;
  // Сон 84 % при норме 86 — чуть ниже обычного (z −0,1); ВСР 52 при норме 45.
  const z = {'hrv': 0.64, 'rhr': 0.3, 'resp': -0.2, 'sleep': -0.1, 'temp': 0.0};
  var zbar = 0.0;
  z.forEach((k, v) => zbar += kRecWeights[k]! * v);
  double r(double zb) => 100 / (1 + math.exp(-(kRingTheta.recA * zb + kRingTheta.recB)));
  final rec = r(zbar);
  return RitmRingsDay(
    // Оценка сна v2: 452 из 537 мин (84 %), регулярность 81, эффективность 94,
    // ночной стресс — по той же демо-ночи, что на экране «Ночь».
    sleepScore: ritmDemoSleepScore(),
    // Потребность по θ §7.4.2: вчера сон 6:12 при базовой 7:37 (база 7:31 +
    // 1,52 × позавчерашние 4,2), долг вчера 0:40 → долг 0,58·40 + 0,511·85 ≈ 1:07;
    // нагрузка вчера 12,8 → +0:19. Итого 7:31 + 1:07 + 0:19 = 8:57.
    need: (need: 537, debt: 66.6, base: 451, strainAdd: 19.5, napCredit: 0),
    // На ночь: долг 0,58·66,6 + 0,511·(470,5 − 452) = 48; нагрузка 1,52 × 10,8 = 16 → 8:36.
    tonight: (need: 515.5, debt: 48.1, base: 451, strainAdd: 16.4, napCredit: 0),
    inputs: RingDayInputs(
      day: _demoDayId(today),
      night: NightInputs(
        rhrSleepMean: 51.4,
        rhrTrough30: 48,
        rmssdSwsLast: 52,
        rmssdNightMean: 47,
        swsFound: true,
        observedFrac: .97,
        hrValidFrac: .95,
        rrWindows: 84,
        onsetTs: at(0, 0) - 60 * 60,
        wakeTs: at(7, 3),
        tstMin: 452,
        inBedMin: 481,
      ),
      resp: 14.2, // = Монитор здоровья
      tempDev: .2, // = Монитор здоровья (+0,2 °C)
      sleepPct: 84,
      needMin: 537,
      eff: 94,
      debtMin: 66.6,
      strain: const StrainResult(
        strain: 10.8,
        load: 76,
        zoneMin: [425, 64, 40, 31, 6, 0],
        trimp: 74,
        minutes: 566,
        bySrc: {HrSrc.band: 520, HrSrc.watch: 46},
      ),
      timeline: [
        HrSegment(at(0, 0), at(6, 50), HrSrc.band, .96),
        HrSegment(at(6, 50), at(7, 5), null, 0),
        HrSegment(at(7, 5), at(7, 40), HrSrc.band, .93),
        HrSegment(at(7, 40), at(8, 26), HrSrc.watch, .99),
        HrSegment(at(8, 26), at(9, 41), HrSrc.band, .95),
      ],
    ),
    recovery: RecoveryResult(
      value: rec.round(),
      nights: 30,
      zbar: zbar,
      drivers: [
        for (final e in z.entries)
          RecDriver(e.key, e.value, kRecWeights[e.key]!, rec - r(zbar - kRecWeights[e.key]! * e.value)),
      ],
    ),
    prevRecovery: 70,
    norms: const {'hrv': 45, 'rhr': 53, 'resp': 14.4, 'sleep': 86, 'light': 228, 'deep': 92, 'rem': 104},
    // Долг за 14 ночей: неделя «как обычно», потом недосып 13–15 окт.
    debtHist: const [18, 12, 9, 14, 10, 6, 11, 8, 5, 9, 14, 41, 40, 66.6],
    dayFrom: t0,
    dayTo: t0 + 86400,
  );
}

String _demoDayId(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';


/// Нагрузка демо-дня по «сколько дней назад» — одна для экранов дней и
/// графика 7 дней (0 — сегодня 10,8; 1 — вчера 12,8; 2 — красный день 4,2).
double demoStrainBack(int back) => switch (back) {
  0 => 10.8,
  1 => 12.8,
  2 => 4.2,
  3 => 7.8,
  4 => 15.3,
  5 => 6.1,
  6 => 11.2,
  _ => 8.4,
};
