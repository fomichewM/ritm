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
  const SeedNight({this.rhr, this.hrv, this.resp});
  Map<String, dynamic> toJson() => {
    if (rhr != null) 'rhr': rhr,
    if (hrv != null) 'hrv': hrv,
    if (resp != null) 'resp': resp,
  };
  static SeedNight fromJson(Map m) => SeedNight(
    rhr: (m['rhr'] as num?)?.toDouble(),
    hrv: (m['hrv'] as num?)?.toDouble(),
    resp: (m['resp'] as num?)?.toDouble(),
  );
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
    final rhr = n(cRhr), hrv = n(cHrv), resp = n(cResp);
    if (rhr == null && hrv == null && resp == null) continue;
    out[_day(day)] = SeedNight(
      rhr: rhr != null && rhr >= 25 && rhr <= 140 ? rhr : null,
      hrv: hrv != null && hrv > 0 && hrv < 400 ? hrv : null,
      resp: resp != null && resp >= 5 && resp <= 40 ? resp : null,
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

/// Хранимый засев: ночи WHOOP и Watch по датам.
class RitmSeed {
  final Map<String, SeedNight> whoop;
  final Map<String, SeedNight> watch;

  /// Сырые SDNN Watch (до сверки) — множитель считается при каждом показе.
  final Map<String, double> watchSdnn;
  const RitmSeed({
    this.whoop = const {},
    this.watch = const {},
    this.watchSdnn = const {},
  });

  bool get isEmpty => whoop.isEmpty && watch.isEmpty && watchSdnn.isEmpty;

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
    for (final src in [watch, whoop]) {
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
    final w = usedDates.any((d) => whoop.containsKey(d));
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
  };

  static RitmSeed fromJson(Map m) => RitmSeed(
    whoop: {
      for (final e in ((m['whoop'] as Map?) ?? const {}).entries)
        e.key as String: SeedNight.fromJson(e.value as Map),
    },
    watch: {
      for (final e in ((m['watch'] as Map?) ?? const {}).entries)
        e.key as String: SeedNight.fromJson(e.value as Map),
    },
    watchSdnn: {
      for (final e in ((m['sdnn'] as Map?) ?? const {}).entries)
        e.key as String: (e.value as num).toDouble(),
    },
  );

  RitmSeed copyWith({
    Map<String, SeedNight>? whoop,
    Map<String, SeedNight>? watch,
    Map<String, double>? watchSdnn,
  }) => RitmSeed(
    whoop: whoop ?? this.whoop,
    watch: watch ?? this.watch,
    watchSdnn: watchSdnn ?? this.watchSdnn,
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
    } catch (_) {}
    return _cache = const RitmSeed();
  }

  static Future<void> save(RitmSeed s) async {
    _cache = s;
    try {
      await (await _file()).writeAsString(jsonEncode(s.toJson()));
    } catch (_) {}
  }
}
