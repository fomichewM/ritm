// «Ритм» — засев личной нормы Монитора здоровья (ТЗ v2 §14 B2).
//
// Пока у браслета мало своих ночей, коридоры §10.4 можно построить по уже
// накопленной истории человека:
//   • CSV WHOOP («physiological_cycles.csv» из экспорта «Мои данные»):
//     пульс покоя, ВСР (rMSSD — та же шкала, что у браслета), дыхание;
//   • «Здоровье» (Apple Watch): пульс покоя за ночь; ВСР там — SDNN, другая
//     шкала, поэтому она подмешивается ТОЛЬКО после сверки: множитель
//     rMSSD/SDNN по ночам, где есть оба числа (≥ 3 ночи), иначе не берётся.
// Правило слияния по дате: своя ночь браслета > WHOOP > Watch. Засев — только
// норма (коридор), никогда не «измеренная ночь»: значения ночей на экранах —
// всегда браслета.
//
// Чистые функции сверху (тест test/ritm_seed_test.dart), хранение — внизу.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'ritm_calc.dart' show percentile;

/// Ночь из чужого источника (значения в шкалах браслета).
class SeedNight {
  final double? rhr, hrv, resp;

  /// FIX84: максимальный пульс цикла (CSV WHOOP «Max HR») — для HRmax.
  final double? maxHr;
  const SeedNight({this.rhr, this.hrv, this.resp, this.maxHr});
  Map<String, dynamic> toJson() => {
    if (rhr != null) 'rhr': rhr,
    if (hrv != null) 'hrv': hrv,
    if (resp != null) 'resp': resp,
    if (maxHr != null) 'mx': maxHr,
  };
  static SeedNight fromJson(Map m) => SeedNight(
    rhr: (m['rhr'] as num?)?.toDouble(),
    hrv: (m['hrv'] as num?)?.toDouble(),
    resp: (m['resp'] as num?)?.toDouble(),
    maxHr: (m['mx'] as num?)?.toDouble(),
  );
}

/// FIX84: окно основного сна ночи из «Здоровья» (секунды эпохи) и минуты сна.
class SeedSleep {
  final int onset, wake;
  final int tst;
  const SeedSleep(this.onset, this.wake, this.tst);
  List<int> toJson() => [onset, wake, tst];
  static SeedSleep? fromJson(Object? x) {
    if (x is! List || x.length < 3) return null;
    final a = (x[0] as num?)?.toInt(), b = (x[1] as num?)?.toInt(), t = (x[2] as num?)?.toInt();
    if (a == null || b == null || t == null || b <= a) return null;
    return SeedSleep(a, b, t);
  }
}

/// Разбор CSV с кавычками («"a,b"», «""»).
List<List<String>> parseCsvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var q = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (q) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          f.write('"');
          i++;
        } else {
          q = false;
        }
      } else {
        f.write(ch);
      }
    } else if (ch == '"') {
      q = true;
    } else if (ch == ',') {
      row.add(f.toString());
      f.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(f.toString());
      f.clear();
      if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      f.write(ch);
    }
  }
  if (f.isNotEmpty || row.isNotEmpty) {
    row.add(f.toString());
    if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
  }
  return rows;
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _ts(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  return DateTime.tryParse(t.replaceFirst(' ', 'T'));
}

/// «physiological_cycles.csv» WHOOP → ночи по дате ПРОБУЖДЕНИЯ (как у Edge).
/// Колонки ищутся по названию; файл без нужных колонок → пусто.
Map<String, SeedNight> parseWhoopCycles(String csv) {
  final rows = parseCsvRows(csv);
  if (rows.length < 2) return const {};
  final head = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(List<String> names) {
    for (final n in names) {
      final i = head.indexOf(n);
      if (i >= 0) return i;
    }
    return -1;
  }

  final cWake = col(['wake onset']);
  final cStart = col(['cycle start time', 'sleep onset']);
  final cRhr = col(['resting heart rate (bpm)', 'resting heart rate']);
  final cHrv = col([
    'heart rate variability (ms)',
    'heart rate variability (rmssd) (ms)',
  ]);
  final cResp = col(['respiratory rate (rpm)', 'respiratory rate']);
  final cMax = col(['max hr (bpm)', 'max hr']);
  if (cRhr < 0 && cHrv < 0) return const {};
  final out = <String, SeedNight>{};
  for (final r in rows.skip(1)) {
    String at(int i) => i >= 0 && i < r.length ? r[i] : '';
    double? n(int i) => double.tryParse(at(i).trim().replaceAll(',', '.'));
    DateTime? day = _ts(at(cWake));
    if (day == null) {
      final s = _ts(at(cStart));
      if (s == null) continue;
      // Цикл WHOOP начинается с засыпания: вечерний старт → утро следующего дня.
      day = s.hour >= 12 ? DateTime(s.year, s.month, s.day + 1) : s;
    }
    final rhr = n(cRhr), hrv = n(cHrv), resp = n(cResp), mx = n(cMax);
    if (rhr == null && hrv == null && resp == null) continue;
    out[_day(day)] = SeedNight(
      rhr: rhr != null && rhr >= 25 && rhr <= 140 ? rhr : null,
      hrv: hrv != null && hrv > 0 && hrv < 400 ? hrv : null,
      resp: resp != null && resp >= 5 && resp <= 40 ? resp : null,
      maxHr: mx != null && mx >= 100 && mx <= 220 ? mx : null,
    );
  }
  return out;
}

/// Множитель rMSSD/SDNN по ночам, где есть оба числа; < 3 ночей — null.
double? sdnnToRmssd(Map<String, double> bandRmssd, Map<String, double> sdnn) {
  final r = <double>[];
  for (final e in sdnn.entries) {
    final b = bandRmssd[e.key];
    if (b != null && e.value > 0) r.add(b / e.value);
  }
  if (r.length < 3) return null;
  return percentile(r, .5);
}

/// Ряд по дням (старые → новые, длина [days]): своя ночь браслета, иначе
/// значение засева. [band] — ряд браслета той же длины, [dates] — даты ряда.
({List<double?> series, int seeded}) mergeSeed(
  List<double?> band,
  List<String> dates,
  Map<String, double> seed,
) {
  var used = 0;
  final out = <double?>[];
  for (var i = 0; i < band.length; i++) {
    final b = band[i];
    if (b != null) {
      out.add(b);
    } else {
      final s = i < dates.length ? seed[dates[i]] : null;
      if (s != null) used++;
      out.add(s);
    }
  }
  return (series: out, seeded: used);
}

/// FIX84: история нормы Восстановления — своя ночь браслета, иначе засев
/// (CSV WHOOP, «Здоровье»). Все ряды — в шкале одного источника с «этой ночью».
class RecSeedHist {
  /// ВСР / пульс покоя / дыхание прошлых ночей (по порядку, ≤ окна).
  final List<double> hrv, rhr, resp;

  /// Значения «этой ночи» в той же шкале, что и ряд (браслет или Watch).
  final double? hrvTonight, rhrTonight;

  /// Сколько ночей ряда пульса покоя / ВСР взято из засева.
  final int seededRhr, seededHrv;

  /// Откуда засев: «WHOOP», «Apple Watch», «WHOOP и Apple Watch» или ''.
  final String src;

  /// Откуда ночи засева: «Здоровье» / экспорт CSV / оба (FIX84).
  final String via;
  const RecSeedHist({
    this.hrv = const [],
    this.rhr = const [],
    this.resp = const [],
    this.hrvTonight,
    this.rhrTonight,
    this.seededRhr = 0,
    this.seededHrv = 0,
    this.src = '',
    this.via = '',
  });
}

double? _median(List<double> xs) => percentile(xs, .5);

/// Ряды нормы на ночь [day] (дата пробуждения). [band*] — свои ночи браслета
/// строго раньше [day]; [tonight*] — эта ночь браслета.
///
/// Шкалы: WHOOP (CSV и «Здоровье») — та же, что у браслета (тот же датчик,
/// rMSSD и пульс покоя по ТЗ §7.1 «как WHOOP»). Apple Watch — после сверки по
/// ≥ 3 общим ночам (пульс — сдвиг по медиане разницы, ВСР — множитель
/// rMSSD/SDNN). Без общих ночей Watch годится только «сам с собой»: эта ночь
/// Watch против прошлых ночей Watch (z не зависит от шкалы).
RecSeedHist recSeedHist({
  required String day,
  required RitmSeed seed,
  Map<String, double> bandHrv = const {},
  Map<String, double> bandRhr = const {},
  Map<String, double> bandResp = const {},
  double? tonightHrv,
  double? tonightRhr,
  int window = 30,
  int maxAgeDays = 400,
}) {
  final d0 = DateTime.tryParse(day);
  if (d0 == null) return RecSeedHist(hrvTonight: tonightHrv, rhrTonight: tonightRhr);
  final oldest = _day(d0.subtract(Duration(days: maxAgeDays)));
  bool inWin(String d) => d.compareTo(day) < 0 && d.compareTo(oldest) >= 0;

  // Сверка Watch → браслет по общим ночам.
  final offs = <double>[
    for (final e in bandRhr.entries)
      if (seed.watch[e.key]?.rhr case final w?) e.value - w,
  ];
  final rhrOff = offs.length >= 3 ? _median(offs) : null;
  final hrvK = sdnnToRmssd(bandHrv, seed.watchSdnn);

  double? sRhr(String d) =>
      seed.whoop[d]?.rhr ?? seed.whoopHk[d]?.rhr ?? (rhrOff == null ? null : seed.watch[d]?.rhr?.let((w) => w + rhrOff));
  double? sHrv(String d) =>
      seed.whoop[d]?.hrv ?? (hrvK == null ? null : seed.watchSdnn[d]?.let((v) => v * hrvK));
  // FIX84: дыхание WHOOP/Watch и браслета — разные датчики и алгоритмы (у
  // калибровщика WHOOP и браслет расходятся на ~2 вдоха/мин). Засев дыхания — только со
  // сдвигом по ≥ 3 общим ночам, иначе дыхание сравнивается лишь со своими.
  double? rawResp(String d) => seed.whoop[d]?.resp ?? seed.whoopHk[d]?.resp ?? seed.watch[d]?.resp;
  final respOffs = <double>[
    for (final e in bandResp.entries)
      if (rawResp(e.key) case final w?) e.value - w,
  ];
  final respOff = respOffs.length >= 3 ? _median(respOffs) : null;
  double? sResp(String d) => respOff == null ? null : rawResp(d)?.let((v) => v + respOff);

  final dates = <String>{
    ...bandHrv.keys, ...bandRhr.keys, ...bandResp.keys,
    ...seed.whoop.keys, ...seed.whoopHk.keys, ...seed.watch.keys, ...seed.watchSdnn.keys,
  }.where(inWin).toList()
    ..sort();

  var fromWhoop = false, fromWatch = false, fromCsv = false, fromHk = false;
  ({List<double> xs, int seeded}) merged(Map<String, double> band, double? Function(String) s) {
    final xs = <double>[];
    final seededFlags = <bool>[];
    for (final d in dates) {
      final b = band[d];
      if (b != null) {
        xs.add(b);
        seededFlags.add(false);
      } else if (s(d) case final v?) {
        xs.add(v);
        seededFlags.add(true);
      }
    }
    final from = xs.length > window ? xs.length - window : 0;
    final tail = xs.sublist(from);
    final flags = seededFlags.sublist(from);
    return (xs: tail, seeded: flags.where((f) => f).length);
  }

  var rhr = merged(bandRhr, sRhr);
  var hrv = merged(bandHrv, sHrv);
  final resp = merged(bandResp, sResp);
  double? rT = tonightRhr, hT = tonightHrv;

  // Источник засева для подписи (по ночам, реально попавшим в окно).
  final tail = dates.length > window * 2 ? dates.sublist(dates.length - window * 2) : dates;
  for (final d in tail) {
    if (bandRhr.containsKey(d)) continue;
    if (seed.whoop[d]?.rhr != null) (fromWhoop, fromCsv) = (true, true);
    if (seed.whoop[d]?.rhr == null && seed.whoopHk[d]?.rhr != null) (fromWhoop, fromHk) = (true, true);
    if (rhrOff != null && seed.watch[d]?.rhr != null) fromWatch = true;
  }

  // «Сам с собой»: Watch этой ночью против прошлых ночей Watch.
  List<double> own(Map<String, double> m) {
    final ks = m.keys.where(inWin).toList()..sort();
    final xs = [for (final k in ks) m[k]!];
    return xs.length > window ? xs.sublist(xs.length - window) : xs;
  }

  final watchRhr = <String, double>{
    for (final e in seed.watch.entries) e.key: ?e.value.rhr,
  };
  if ((rT == null || rhr.xs.length < 4) && watchRhr[day] != null) {
    final h = own(watchRhr);
    if (h.length >= 4) {
      rhr = (xs: h, seeded: h.length);
      rT = watchRhr[day];
      fromWatch = true;
    }
  }
  if ((hT == null || hrv.xs.length < 4) && seed.watchSdnn[day] != null) {
    final h = own(seed.watchSdnn);
    if (h.length >= 4) {
      hrv = (xs: h, seeded: h.length);
      hT = seed.watchSdnn[day];
      fromWatch = true;
    }
  }
  if (hrv.seeded > 0 && seed.whoop.isNotEmpty) (fromWhoop, fromCsv) = (true, true);
  final src = fromWhoop && fromWatch
      ? 'WHOOP и Apple Watch'
      : fromWhoop
      ? 'WHOOP'
      : fromWatch
      ? 'Apple Watch'
      : '';
  // FIX84: откуда пришли ночи — экспорт CSV или история «Здоровья».
  final via = fromCsv && (fromHk || fromWatch)
      ? '«Здоровье» и CSV'
      : fromCsv
      ? 'экспорт CSV'
      : '«Здоровье»';
  return RecSeedHist(
    hrv: hrv.xs,
    rhr: rhr.xs,
    resp: resp.xs,
    hrvTonight: hT,
    rhrTonight: rT,
    seededRhr: rhr.seeded,
    seededHrv: hrv.seeded,
    src: rhr.seeded + hrv.seeded == 0 ? '' : src,
    via: rhr.seeded + hrv.seeded == 0 ? '' : via,
  );
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// FIX84: обычное время подъёма (минуты от полуночи) — медиана последних
/// [n] пробуждений между 03:00 и 13:00; null — меньше 3 таких ночей.
int? usualWakeMin(Iterable<int> wakeEpochSec, {int n = 14}) {
  final xs = <int>[];
  for (final s in wakeEpochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(s * 1000);
    final m = t.hour * 60 + t.minute;
    if (m >= 180 && m <= 780) xs.add(m);
  }
  if (xs.length < 3) return null;
  final tail = xs.length > n ? xs.sublist(xs.length - n) : xs;
  final s = [...tail]..sort();
  return s[s.length ~/ 2];
}

/// Хранимый засев: ночи WHOOP и Watch по датам.
class RitmSeed {
  final Map<String, SeedNight> whoop;
  final Map<String, SeedNight> watch;

  /// Сырые SDNN Watch (до сверки) — множитель считается при каждом показе.
  final Map<String, double> watchSdnn;

  /// FIX84: ночи, которые в «Здоровье» записало приложение WHOOP (пульс
  /// покоя, дыхание; ВСР WHOOP в «Здоровье» не пишет — rMSSD ≠ SDNN).
  final Map<String, SeedNight> whoopHk;

  /// FIX84: окна основного сна по дате пробуждения (любой источник
  /// «Здоровья») — обычное время подъёма и долг до своих ночей браслета.
  final Map<String, SeedSleep> sleep;

  /// Когда последний раз забирали историю «Здоровья» (мс эпохи; 0 — никогда).
  final int hkSyncedAt;
  const RitmSeed({
    this.whoop = const {},
    this.watch = const {},
    this.watchSdnn = const {},
    this.whoopHk = const {},
    this.sleep = const {},
    this.hkSyncedAt = 0,
  });

  bool get isEmpty =>
      whoop.isEmpty && watch.isEmpty && watchSdnn.isEmpty && whoopHk.isEmpty && sleep.isEmpty;

  /// Ночей истории «Здоровья» (любой показатель нормы).
  /// FIX84: HRmax по истории WHOOP (CSV) — второй по величине «Max HR»
  /// за последние 365 дней (одиночный выброс датчика не становится HRmax).
  double? hrMaxYear(DateTime now) {
    final oldest = _day(now.subtract(const Duration(days: 365)));
    final xs = [
      for (final e in whoop.entries)
        if (e.key.compareTo(oldest) >= 0) ?e.value.maxHr,
    ]..sort();
    return xs.length < 2 ? null : xs[xs.length - 2];
  }

  int get hkNights => {...watch.keys, ...watchSdnn.keys, ...whoopHk.keys}.length;

  /// Значения одного показателя по датам с приоритетом WHOOP > Watch.
  Map<String, double> values(String key, {Map<String, double>? bandRmssd}) {
    final out = <String, double>{};
    if (key == 'hrv' && bandRmssd != null) {
      final k = sdnnToRmssd(bandRmssd, watchSdnn);
      if (k != null) {
        for (final e in watchSdnn.entries) {
          out[e.key] = e.value * k;
        }
      }
    }
    for (final src in [watch, whoopHk, whoop]) {
      for (final e in src.entries) {
        final v = switch (key) {
          'rhr' => e.value.rhr,
          'hrv' => e.value.hrv,
          _ => e.value.resp,
        };
        if (v != null) out[e.key] = v;
      }
    }
    return out;
  }

  String sourceWord(String key, Set<String> usedDates) {
    final w = usedDates.any((d) => whoop.containsKey(d) || whoopHk.containsKey(d));
    final a = usedDates.any(
      (d) => watch.containsKey(d) || watchSdnn.containsKey(d),
    );
    if (w && a) return 'с историей WHOOP и Watch';
    if (w) return 'с историей WHOOP';
    if (a) return 'с историей Watch';
    return '';
  }

  Map<String, dynamic> toJson() => {
    'whoop': {for (final e in whoop.entries) e.key: e.value.toJson()},
    'watch': {for (final e in watch.entries) e.key: e.value.toJson()},
    'sdnn': watchSdnn,
    if (whoopHk.isNotEmpty) 'whoop_hk': {for (final e in whoopHk.entries) e.key: e.value.toJson()},
    if (sleep.isNotEmpty) 'sleep': {for (final e in sleep.entries) e.key: e.value.toJson()},
    if (hkSyncedAt > 0) 'hk_at': hkSyncedAt,
  };

  static RitmSeed fromJson(Map m) {
    Map<String, SeedNight> nights(Object? x) => {
      for (final e in ((x as Map?) ?? const {}).entries)
        e.key as String: SeedNight.fromJson(e.value as Map),
    };
    return RitmSeed(
      whoop: nights(m['whoop']),
      watch: nights(m['watch']),
      watchSdnn: {
        for (final e in ((m['sdnn'] as Map?) ?? const {}).entries)
          e.key as String: (e.value as num).toDouble(),
      },
      whoopHk: nights(m['whoop_hk']),
      sleep: {
        for (final e in ((m['sleep'] as Map?) ?? const {}).entries)
          e.key as String: ?SeedSleep.fromJson(e.value),
      },
      hkSyncedAt: (m['hk_at'] as num?)?.toInt() ?? 0,
    );
  }

  RitmSeed copyWith({
    Map<String, SeedNight>? whoop,
    Map<String, SeedNight>? watch,
    Map<String, double>? watchSdnn,
    Map<String, SeedNight>? whoopHk,
    Map<String, SeedSleep>? sleep,
    int? hkSyncedAt,
  }) => RitmSeed(
    whoop: whoop ?? this.whoop,
    watch: watch ?? this.watch,
    watchSdnn: watchSdnn ?? this.watchSdnn,
    whoopHk: whoopHk ?? this.whoopHk,
    sleep: sleep ?? this.sleep,
    hkSyncedAt: hkSyncedAt ?? this.hkSyncedAt,
  );

  // ── хранение (Documents/ritm_seed.json) ──
  static RitmSeed? _cache;
  static RitmSeed get cached => _cache ?? const RitmSeed();

  static Future<File> _file() async => File(
    '${(await getApplicationDocumentsDirectory()).path}/ritm_seed.json',
  );

  static Future<RitmSeed> load() async {
    try {
      final f = await _file();
      if (f.existsSync()) {
        _cache = fromJson(jsonDecode(await f.readAsString()) as Map);
        return _cache!;
      }
      return _cache = const RitmSeed();
    } catch (_) {}
    // Хранилище недоступно (тесты) — не затираем то, что уже в памяти.
    return _cache ??= const RitmSeed();
  }

  static Future<void> save(RitmSeed s) async {
    _cache = s;
    try {
      await (await _file()).writeAsString(jsonEncode(s.toJson()));
    } catch (_) {}
  }
}
