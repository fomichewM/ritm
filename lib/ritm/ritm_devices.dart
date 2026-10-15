// «Ритм» B4½ — устройства и источники (ТЗ v3 §6, §11; MULTIDEVICE §3–§4).
//
//   D1 pickSource(metric, night, set, …) → {source, trust A/B/C, reason} —
//      одна таблица §6, тест на каждую строку (test/ritm_devices_test.dart);
//   D2 BandCaps из HELLO браслета (модель/прошивка/ЭКГ/батарея), кэш по
//      серийнику, ручное переопределение — только пока HELLO не получен;
//   D3 автоопределение второго устройства по источникам «Здоровья»;
//   D4 предупреждение: в «Здоровье» пишет приложение WHOOP (риск прошивки).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path_provider/path_provider.dart';

// ── D2: модель браслета ──────────────────────────────────────────────────────

enum BandModel { whoop4, whoop5, whoopMg, unknown }

class BandCaps {
  final BandModel model;
  final String firmware, serial;

  /// Откуда модель: 'hello' — из ответа браслета, 'manual' — выбрано вручную,
  /// 'cache' — запомнено по серийнику.
  final String origin;
  const BandCaps({
    this.model = BandModel.unknown,
    this.firmware = '',
    this.serial = '',
    this.origin = '',
  });

  /// gen5 HELLO rev-1: оптический дискриминатор 48..85 — 5.0, < 38 — MG
  /// (только при revision == 1; иначе модель не утверждаем).
  factory BandCaps.fromGen5Hello({
    required int helloRevision,
    required int opticalDiscriminator,
    String firmware = '',
    String serial = '',
  }) {
    var m = BandModel.unknown;
    if (helloRevision == 1 && opticalDiscriminator < 38) {
      m = BandModel.whoopMg;
    } else if (opticalDiscriminator >= 48 && opticalDiscriminator < 86) {
      m = BandModel.whoop5;
    }
    return BandCaps(model: m, firmware: firmware, serial: serial, origin: 'hello');
  }

  /// gen4 HELLO (опкод Harvard) — всегда 4.0.
  factory BandCaps.gen4({String serial = '', String firmware = ''}) =>
      BandCaps(model: BandModel.whoop4, serial: serial, firmware: firmware, origin: 'hello');

  bool get known => model != BandModel.unknown;
  bool get ecg => model == BandModel.whoopMg;

  /// Батарея, дней (§3.2): 4.0 — 4–5, 5.0/MG — 14.
  String get batteryDays => switch (model) {
    BandModel.whoop4 => '4–5 дней',
    BandModel.whoop5 || BandModel.whoopMg => '14 дней',
    BandModel.unknown => '',
  };

  /// Порог напоминания о заряде: 4.0 — 20 %, 5.0/MG — 10 %.
  int get lowBatteryPct => model == BandModel.whoop4 ? 20 : 10;

  /// Глубокие буферы (сырой PPG/IMU, R22) — только gen5.
  bool get deepBuffers => model == BandModel.whoop5 || model == BandModel.whoopMg;

  String get title => switch (model) {
    BandModel.whoop4 => 'WHOOP 4.0',
    BandModel.whoop5 => 'WHOOP 5.0',
    BandModel.whoopMg => 'WHOOP 5.0 MG',
    BandModel.unknown => 'WHOOP',
  };

  /// «WHOOP 5.0 MG · прошивка 50.42.1.0».
  String get line => [
    title,
    if (firmware.isNotEmpty) 'прошивка $firmware',
  ].join(' · ');

  /// Что умеет модель — 3–4 слова (без серых «недоступно»).
  String get can => switch (model) {
    BandModel.whoop4 => 'пульс, ВСР, сон, температура',
    BandModel.whoop5 => 'пульс, ВСР, сон, температура, 14 дней',
    BandModel.whoopMg => 'пульс, ВСР, сон, температура, ЭКГ',
    BandModel.unknown => 'модель определится при подключении',
  };

  Map<String, dynamic> toJson() => {
    'model': model.name,
    'firmware': firmware,
    'serial': serial,
    'origin': origin,
  };

  static BandCaps fromJson(Map m) => BandCaps(
    model: BandModel.values.firstWhere(
      (x) => x.name == m['model'],
      orElse: () => BandModel.unknown,
    ),
    firmware: '${m['firmware'] ?? ''}',
    serial: '${m['serial'] ?? ''}',
    origin: '${m['origin'] ?? ''}',
  );
}

/// Что показать: HELLO выше всего; без него — ручной выбор; затем кэш
/// по серийнику; затем старый флаг `pairedIsMaverick`.
BandCaps resolveBandCaps({
  BandCaps? hello,
  BandCaps? manual,
  BandCaps? cached,
  bool pairedIsMaverick = false,
}) {
  if (hello != null && hello.known) return hello;
  if (manual != null && manual.known) return manual;
  if (cached != null && cached.known) {
    return BandCaps(
      model: cached.model,
      firmware: cached.firmware,
      serial: cached.serial,
      origin: 'cache',
    );
  }
  if (pairedIsMaverick) return const BandCaps(model: BandModel.whoopMg, origin: 'cache');
  return const BandCaps();
}

// ── D3/D4: второе устройство ─────────────────────────────────────────────────

enum SecondDevice { none, watch, garmin }

String secondDeviceName(SecondDevice d) => switch (d) {
  SecondDevice.none => 'Нет',
  SecondDevice.watch => 'Apple Watch',
  SecondDevice.garmin => 'Garmin',
};

/// Что даёт / чего не даёт (MULTIDEVICE §4.3) — две строки под плиткой.
(String, String) secondDeviceGives(SecondDevice d) => switch (d) {
  SecondDevice.none => (
    'всё считает браслет: сон, восстановление, нагрузка',
    'нет ЭКГ Watch, VO₂max и пульса с точностью нагрудного',
  ),
  SecondDevice.watch => (
    'пульс на беге и велосипеде, VO₂max, ЭКГ, шаги',
    'ночь не берём — сон и ВСР считает браслет',
  ),
  SecondDevice.garmin => (
    'тренировки и шаги через «Здоровье», пульс трансляцией',
    'нет ВСР, SpO₂ и маршрута — Garmin их не отдаёт',
  ),
};

class SourceProbe {
  final String bundle, product, model, name;
  const SourceProbe({
    this.bundle = '',
    this.product = '',
    this.model = '',
    this.name = '',
  });
}

/// По источникам «Здоровья» за 7 дней: кого предложить вторым и пишет ли
/// в «Здоровье» приложение WHOOP (D4).
({SecondDevice? suggest, bool whoopApp}) detectSecondDevice(
  Iterable<SourceProbe> sources,
) {
  var watch = false, garmin = false, whoop = false;
  for (final s in sources) {
    final b = s.bundle.toLowerCase();
    if (b == 'com.whoop.iphone' || b.startsWith('com.whoop.')) whoop = true;
    if (b == 'com.garmin.connect.mobile') garmin = true;
    if (s.product.startsWith('Watch') || s.model.toLowerCase().contains('watch')) {
      watch = true;
    }
  }
  return (
    suggest: watch ? SecondDevice.watch : (garmin ? SecondDevice.garmin : null),
    whoopApp: whoop,
  );
}

// ── D1: схема «метрика × источник» (§6) ──────────────────────────────────────

enum RMetric {
  hr,
  rhr,
  hrv,
  resp,
  temp,
  spo2,
  sleep,
  stages,
  sleepScores,
  steps,
  kcal,
  workouts,
  workoutHr,
  strain,
  recovery,
  vo2max,
  ecg,
  hrr,
  stressDay,
  bloodPressure,
}

/// Код источника: band | watch | garmin | garmin_hr | iphone | manual | none.
class SourcePick {
  final String source;
  final String trust; // A | B | C | ''
  final String reason;
  const SourcePick(this.source, this.trust, this.reason);

  String get label => switch (source) {
    'band' => 'браслет',
    'watch' => 'Watch',
    'garmin' => 'Garmin',
    'garmin_hr' => 'Garmin (трансляция)',
    'iphone' => 'iPhone',
    'manual' => 'введено',
    _ => 'нет',
  };
}

/// Набор устройств: S1 браслет+Watch, S2/S3 только браслет, S4 браслет+Garmin.
SourcePick pickSource(
  RMetric m, {
  bool night = false,
  SecondDevice set = SecondDevice.none,

  /// Доля валидных секунд второго устройства в окне (для пульса дня).
  double coverage = 1,

  /// Минута внутри кардио-тренировки второго устройства (бег/вело/ходьба).
  bool inCardioWorkout = false,
  bool bandEcg = false,
  bool watchSpo2Tonight = false,
  bool garminBroadcast = false,
  bool watchSteps12h = false,
  bool garminSteps12h = false,
  bool manualVo2 = false,
}) {
  const b = 'band';
  final watch = set == SecondDevice.watch, garmin = set == SecondDevice.garmin;
  switch (m) {
    case RMetric.hr:
    case RMetric.workoutHr:
      if (night) return const SourcePick(b, 'A', 'ночью — всегда браслет');
      if (watch && inCardioWorkout && coverage >= 0.8) {
        return const SourcePick('watch', 'A', 'на беге и велосипеде пульс Watch точнее запястного');
      }
      if (garmin && garminBroadcast && inCardioWorkout && coverage >= 0.8) {
        return const SourcePick('garmin_hr', 'A', 'трансляция пульса Garmin на тренировке');
      }
      return const SourcePick(b, 'A', 'браслет носится весь день');
    case RMetric.rhr:
      return const SourcePick(b, 'A', 'пульс покоя — средний за сон, браслет');
    case RMetric.hrv:
      return const SourcePick(b, 'A', 'ВСР в глубоком сне — только браслет (у Watch другая шкала)');
    case RMetric.resp:
      return const SourcePick(b, 'A', 'дыхание ночью — браслет');
    case RMetric.temp:
      return const SourcePick(b, 'B', 'отклонение температуры кожи — браслет');
    case RMetric.spo2:
      if (watch && watchSpo2Tonight) {
        return const SourcePick('watch', 'A', 'спали в Watch — есть ночные замеры');
      }
      return const SourcePick('none', '', 'SpO₂ ночью — только если спите в Watch');
    case RMetric.sleep:
    case RMetric.sleepScores:
    case RMetric.recovery:
      return const SourcePick(b, 'A', 'ночь — всегда браслет');
    case RMetric.stages:
      return const SourcePick(b, 'C', 'стадии — оценка по пульсу и движению');
    case RMetric.steps:
      if (watch && watchSteps12h) return const SourcePick('watch', 'A', 'Watch на руке ≥ 12 ч');
      if (garmin && garminSteps12h) return const SourcePick('garmin', 'A', 'Garmin на руке ≥ 12 ч');
      return const SourcePick(b, 'A', 'шаги браслета; иначе iPhone, без сложения');
    case RMetric.kcal:
      if (watch) return const SourcePick('watch', 'C', 'один источник, без сложения, ±25 %');
      if (garmin) return const SourcePick('garmin', 'C', 'один источник, без сложения, ±25 %');
      return const SourcePick(b, 'C', 'оценка ±25 %');
    case RMetric.workouts:
      if (watch) return const SourcePick('watch', 'A', 'тренировка Watch — тип, дистанция, маршрут');
      if (garmin) return const SourcePick('garmin', 'B', 'тренировка Garmin через «Здоровье», без трека');
      return const SourcePick(b, 'B', 'автоопределение браслета');
    case RMetric.strain:
      if (night) return const SourcePick(b, 'A', 'ночь — браслет');
      if (watch) return const SourcePick(b, 'A', 'один склеенный ряд: Watch на беге, браслет — остальное');
      if (garmin) return const SourcePick(b, 'A', 'склеенный ряд: Garmin трансляцией, браслет — остальное');
      return const SourcePick(b, 'A', 'весь день по пульсу браслета');
    case RMetric.vo2max:
      if (watch) return const SourcePick('watch', 'A', 'VO₂max Apple проверена исследованиями');
      if (manualVo2) return const SourcePick('manual', 'C', 'введено вручную');
      return const SourcePick('none', '', 'нужны Apple Watch или ввод вручную');
    case RMetric.ecg:
      if (bandEcg) return const SourcePick(b, 'A', 'электроды есть у WHOOP MG');
      if (watch) return const SourcePick('watch', 'A', 'ЭКГ Apple Watch');
      return const SourcePick('none', '', 'электродов нет');
    case RMetric.hrr:
      if (watch) return const SourcePick('watch', 'A', 'пульс Watch после тренировки');
      if (garmin && garminBroadcast) return const SourcePick('garmin_hr', 'A', 'трансляция Garmin');
      return const SourcePick(b, 'B', 'расчёт по пульсу браслета');
    case RMetric.stressDay:
      return const SourcePick(b, 'B', 'непрерывные интервалы сердца есть только у браслета');
    case RMetric.bloodPressure:
      return const SourcePick('none', '', 'давление — только в приложении WHOOP');
  }
}

// ── хранение: кэш модели по серийнику, ручной выбор, второе устройство ──────

class RitmDevicePrefs {
  final Map<String, BandCaps> bySerial;
  final BandCaps? manual;
  final SecondDevice? second; // null — не выбирал (берём автоопределение)
  const RitmDevicePrefs({this.bySerial = const {}, this.manual, this.second});

  static RitmDevicePrefs cached = const RitmDevicePrefs();

  static Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/ritm_devices.json');
  }

  static Future<RitmDevicePrefs> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return cached;
      final m = jsonDecode(await f.readAsString()) as Map;
      final by = <String, BandCaps>{};
      final raw = m['by_serial'];
      if (raw is Map) {
        for (final e in raw.entries) {
          if (e.value is Map) by['${e.key}'] = BandCaps.fromJson(e.value as Map);
        }
      }
      cached = RitmDevicePrefs(
        bySerial: by,
        manual: m['manual'] is Map ? BandCaps.fromJson(m['manual'] as Map) : null,
        second: SecondDevice.values
            .where((x) => x.name == m['second'])
            .firstOrNull,
      );
    } catch (_) {}
    return cached;
  }

  Future<void> save() async {
    cached = this;
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'by_serial': {for (final e in bySerial.entries) e.key: e.value.toJson()},
          if (manual != null) 'manual': manual!.toJson(),
          if (second != null) 'second': second!.name,
        }),
      );
    } catch (_) {}
  }

  RitmDevicePrefs withHello(BandCaps c) => c.serial.isEmpty || !c.known
      ? this
      : RitmDevicePrefs(bySerial: {...bySerial, c.serial: c}, manual: manual, second: second);

  RitmDevicePrefs withSecond(SecondDevice d) =>
      RitmDevicePrefs(bySerial: bySerial, manual: manual, second: d);

  RitmDevicePrefs withManual(BandCaps? c) =>
      RitmDevicePrefs(bySerial: bySerial, manual: c, second: second);

  /// Модель из HELLO этого подключения (null — ещё не было HELLO).
  static final hello = ValueNotifier<BandCaps?>(null);

  /// Вызывается BLE-движком на HELLO браслета: запомнить модель и прошивку
  /// по серийнику (кэш на случай, когда браслет не на связи). Не бросает.
  static Future<void> noteHello(BandCaps c) async {
    if (!c.known) return;
    hello.value = c;
    try {
      final p = await load();
      await p.withHello(c).save();
    } catch (_) {}
  }

  /// Что показать сейчас: HELLO → ручной выбор → кэш по серийнику → флаг MG.
  static BandCaps current({String? serial, bool pairedIsMaverick = false}) => resolveBandCaps(
    hello: hello.value,
    manual: cached.manual,
    cached: serial == null ? (cached.bySerial.isEmpty ? null : cached.bySerial.values.last) : cached.bySerial[serial],
    pairedIsMaverick: pairedIsMaverick,
  );
}
