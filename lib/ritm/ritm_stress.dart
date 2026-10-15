// «Ритм» — Монитор стресса 0–3 (ТЗ v2 §5, §10.5, §2.7).
//
// Источник — браслет: секунды `decoded_onehz` (hr, hr_valid, ускорение,
// activity_class, on_wrist) и удары `decoded_rr`. Окно 5 мин, шаг 1 мин.
// Окно «тихое» (допускается к расчёту), если: hr_valid ≥ 80 %, средний ENMO
// ниже тихого порога Edge (0,02 g), ходьбы/бега ≤ 10 % секунд, вне тренировки,
// вне сна, ≥ 20 чистых RR-разностей.
//   z_hr  = (HR − HR_дн.покоя) / SD
//   z_hrv = (ln rMSSD_дн.покоя − ln rMSSD_окна) / SD
//   S     = clamp(1 + 0,6·(0,6·z_hr + 0,4·z_hrv), 0, 3)
// Норма (HR_дн.покоя, ln rMSSD_дн.покоя, SD) — по тихим ДНЕВНЫМ окнам 14 дней.
// Калибровка: 7 дней, в каждом ≥ 20 тихих окон; график рисуется с первого дня.
//
// Сырые секунды Edge хранит 5 дней (`rawRetentionDays`), поэтому тихие окна
// каждого дня сохраняются в маленький JSON (`Documents/ritm_stress/<день>.json`)
// — так норма копится 14 дней. Верх файла — чистые функции (тесты
// test/ritm_stress_test.dart), низ — чтение базы и кэш.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import '../data/db.dart' show LocalDb;
import '../data/local_repository.dart' show LocalRepository;
import 'ritm_calc.dart' show percentile;
import 'ritm_scores.dart' show dec1;

// ───────────────────────── входные данные ─────────────────────────

/// Одна секунда браслета.
class StressSec {
  final int ts; // unix, с
  final int? hr;
  final bool hrValid;
  final double? enmo; // |‖a‖ − 1| в g; null — ускорения нет
  final int? cls; // activity_class Edge: 1 — ходьба, 2 — бег
  final bool onWrist;
  const StressSec(
    this.ts, {
    this.hr,
    this.hrValid = true,
    this.enmo,
    this.cls,
    this.onWrist = true,
  });
}

/// Один RR-интервал (мс) со временем удара (с).
class StressBeat {
  final int ts;
  final int rr;
  const StressBeat(this.ts, this.rr);
}

typedef Span = ({int from, int to});

/// Почему окно не посчитано (для графика: сон — полоса, тренировка — штриховка).
enum StressGap { none, sleep, workout, motion, signal }

/// Признаки одного 5-минутного окна (t — конец окна, с).
class StressWin {
  final int t;
  final double? hr;
  final double? lnRmssd;
  final StressGap gap;
  const StressWin(this.t, {this.hr, this.lnRmssd, this.gap = StressGap.none});
  bool get quiet => gap == StressGap.none && hr != null && lnRmssd != null;
}

const int kStressWinSec = 300;
const int kStressStepSec = 60;
const double kStressQuietEnmo = 0.02; // Edge `_quietEnmoCutG` (gen4/gen5)
const int kStressMinRr = 20;
const int kStressCalDays = 7;
const int kStressCalWins = 20;
const int kStressBaseDays = 14;

/// Чистые RR-разности: 300–2000 мс, соседние отличаются ≤ 20 %.
List<double> cleanRrDiffs(List<int> rr) {
  final out = <double>[];
  for (var i = 1; i < rr.length; i++) {
    final a = rr[i - 1], b = rr[i];
    if (a < 300 || a > 2000 || b < 300 || b > 2000) continue;
    if ((b - a).abs() > 0.2 * a) continue;
    out.add((b - a).toDouble());
  }
  return out;
}

double? rmssdOf(List<double> diffs) {
  if (diffs.isEmpty) return null;
  var s = 0.0;
  for (final d in diffs) {
    s += d * d;
  }
  return math.sqrt(s / diffs.length);
}

bool _inAny(int t, List<Span> spans) {
  for (final s in spans) {
    if (t >= s.from && t < s.to) return true;
  }
  return false;
}

/// Окна дня с шагом 1 мин. [secs] и [beats] — по возрастанию времени.
List<StressWin> stressWindows(
  List<StressSec> secs,
  List<StressBeat> beats, {
  List<Span> sleep = const [],
  List<Span> workouts = const [],
  double quietEnmo = kStressQuietEnmo,
}) {
  if (secs.isEmpty) return const [];
  final out = <StressWin>[];
  final first = secs.first.ts, last = secs.last.ts;
  // Окна выровнены по целой минуте.
  var t = ((first + kStressWinSec) ~/ kStressStepSec) * kStressStepSec;
  var lo = 0, hi = 0, bLo = 0, bHi = 0;
  while (t <= last) {
    final from = t - kStressWinSec;
    while (lo < secs.length && secs[lo].ts < from) {
      lo++;
    }
    if (hi < lo) hi = lo;
    while (hi < secs.length && secs[hi].ts < t) {
      hi++;
    }
    while (bLo < beats.length && beats[bLo].ts < from) {
      bLo++;
    }
    if (bHi < bLo) bHi = bLo;
    while (bHi < beats.length && beats[bHi].ts < t) {
      bHi++;
    }
    final mid = t - kStressWinSec ~/ 2;
    if (_inAny(mid, sleep)) {
      out.add(StressWin(t, gap: StressGap.sleep));
    } else if (_inAny(mid, workouts)) {
      out.add(StressWin(t, gap: StressGap.workout));
    } else {
      var valid = 0, moving = 0, accel = 0;
      var hrSum = 0.0, enmoSum = 0.0;
      for (var i = lo; i < hi; i++) {
        final s = secs[i];
        if (s.onWrist && s.hrValid && s.hr != null && s.hr! > 25) {
          valid++;
          hrSum += s.hr!;
        }
        if (s.cls == 1 || s.cls == 2) moving++;
        if (s.enmo != null) {
          accel++;
          enmoSum += s.enmo!;
        }
      }
      final n = kStressWinSec;
      if (valid < 0.8 * n) {
        out.add(StressWin(t, gap: StressGap.signal));
      } else if (accel < 0.8 * n ||
          enmoSum / accel >= quietEnmo ||
          moving > 0.1 * n) {
        out.add(StressWin(t, gap: StressGap.motion));
      } else {
        final rr = [for (var j = bLo; j < bHi; j++) beats[j].rr];
        final diffs = cleanRrDiffs(rr);
        final r = rmssdOf(diffs);
        if (diffs.length < kStressMinRr || r == null || r <= 0) {
          out.add(StressWin(t, gap: StressGap.signal));
        } else {
          out.add(StressWin(t, hr: hrSum / valid, lnRmssd: math.log(r)));
        }
      }
    }
    t += kStressStepSec;
  }
  return out;
}

// ───────────────────────── норма и шкала ─────────────────────────

class StressBaseline {
  final double hr, hrSd, ln, lnSd;
  final int days; // дней с ≥ 20 тихими окнами (для калибровки N/7)
  const StressBaseline({
    required this.hr,
    required this.hrSd,
    required this.ln,
    required this.lnSd,
    required this.days,
  });
}

double _sd(List<double> xs, double m) {
  if (xs.length < 2) return 0;
  var s = 0.0;
  for (final x in xs) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / (xs.length - 1));
}

/// Норма по тихим окнам дней (каждый элемент — пары (hr, ln) одного дня),
/// не больше 14 последних дней. Медиана — центр, SD — разброс (с полом,
/// чтобы один ровный день не давал бесконечных z).
StressBaseline? stressBaseline(List<List<(double, double)>> days) {
  final use = days.length > kStressBaseDays
      ? days.sublist(days.length - kStressBaseDays)
      : days;
  final hr = <double>[], ln = <double>[];
  var full = 0;
  for (final d in use) {
    if (d.length >= kStressCalWins) full++;
    for (final (h, l) in d) {
      hr.add(h);
      ln.add(l);
    }
  }
  if (hr.length < 10) return null;
  final mh = percentile(hr, .5)!, ml = percentile(ln, .5)!;
  return StressBaseline(
    hr: mh,
    hrSd: math.max(_sd(hr, mh), 3.0),
    ln: ml,
    lnSd: math.max(_sd(ln, ml), 0.15),
    days: full,
  );
}

/// S = clamp(1 + 0,6·(0,6·z_hr + 0,4·z_hrv), 0, 3).
double stressScore(double hr, double lnRmssd, StressBaseline b) {
  final zHr = (hr - b.hr) / b.hrSd;
  final zHrv = (b.ln - lnRmssd) / b.lnSd;
  return (1 + 0.6 * (0.6 * zHr + 0.4 * zHrv)).clamp(0.0, 3.0).toDouble();
}

enum StressLevel { low, mid, high }

StressLevel stressLevel(double s) =>
    s < 1 ? StressLevel.low : (s < 2 ? StressLevel.mid : StressLevel.high);

String stressWord(StressLevel l) => switch (l) {
  StressLevel.low => 'Низкий',
  StressLevel.mid => 'Средний',
  StressLevel.high => 'Высокий',
};

/// Точка графика: значение или причина пропуска.
class StressPoint {
  final int t;
  final double? s;
  final StressGap gap;
  const StressPoint(this.t, this.s, this.gap);
}

/// Итог дня для плитки и экрана.
class StressDay {
  final List<StressPoint> points;
  final StressBaseline? base;

  /// Последнее окно со значением не старше 30 мин от [now].
  final StressPoint? latest;
  final int calDays;
  const StressDay({
    this.points = const [],
    this.base,
    this.latest,
    this.calDays = 0,
  });

  int get measured => points.where((p) => p.s != null).length;
  bool get calibrated => calDays >= kStressCalDays;
}

/// Собрать день: окна сегодня + норма по прошлым дням (и сегодняшним тихим
/// окнам, пока прошлых нет — график рисуется с первого дня).
StressDay stressDay(
  List<StressWin> wins, {
  required List<List<(double, double)>> pastQuiet,
  required int now,
}) {
  final todayQuiet = [
    for (final w in wins)
      if (w.quiet) (w.hr!, w.lnRmssd!),
  ];
  final base =
      stressBaseline(pastQuiet) ??
      stressBaseline([...pastQuiet, todayQuiet]);
  final cal = stressBaseline([...pastQuiet, todayQuiet])?.days ?? 0;
  final pts = <StressPoint>[];
  StressPoint? latest;
  for (final w in wins) {
    final s = w.quiet && base != null
        ? stressScore(w.hr!, w.lnRmssd!, base)
        : null;
    final p = StressPoint(w.t, s, w.gap);
    pts.add(p);
    if (s != null && now - w.t <= 30 * 60 && now >= w.t) latest = p;
  }
  return StressDay(
    points: pts,
    base: base,
    latest: latest,
    calDays: math.min(cal, kStressCalDays),
  );
}

/// Строка плитки «Монитор стресса» (§2 п. 4).
String stressTileText(StressDay? d) {
  if (d == null || d.points.isEmpty) return 'Нет данных';
  if (!d.calibrated) return 'Калибровка · ${d.calDays}/$kStressCalDays';
  final l = d.latest;
  if (l == null || l.s == null) return 'Нет замера';
  return '${stressWord(stressLevel(l.s!))} · ${dec1(l.s!)}';
}

// ───────────────────────── чтение базы и кэш ─────────────────────────

/// Тихие окна дня в кэше: [[t, hr, ln], …].
class RitmStressStore {
  static Future<Directory> _dir() async {
    final d = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/ritm_stress',
    );
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String dayId(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Future<void> save(String day, List<StressWin> wins) async {
    final q = [
      for (final w in wins)
        if (w.quiet)
          [w.t, (w.hr! * 10).round() / 10, (w.lnRmssd! * 1000).round() / 1000],
    ];
    final f = File('${(await _dir()).path}/$day.json');
    await f.writeAsString(jsonEncode({'q': q}));
  }

  static Future<List<(double, double)>?> quiet(String day) async {
    try {
      final f = File('${(await _dir()).path}/$day.json');
      if (!f.existsSync()) return null;
      final m = jsonDecode(await f.readAsString()) as Map;
      return [
        for (final e in (m['q'] as List))
          ((e[1] as num).toDouble(), (e[2] as num).toDouble()),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Секунды и удары браслета за [from, to) (unix, с) — постранично.
  static Future<(List<StressSec>, List<StressBeat>)> read(
    int from,
    int to,
  ) async {
    final secs = <StressSec>[];
    int? afterTs, afterCounter;
    while (true) {
      final page = await LocalDb.decodedOneHzBatchByRecTsRange(
        limit: 6000,
        fromRecTs: from,
        toRecTs: to - 1,
        afterRecTs: afterTs,
        afterCounter: afterCounter,
      );
      if (page.isEmpty) break;
      for (final r in page) {
        final ax = (r['ax'] as num?)?.toDouble();
        final ay = (r['ay'] as num?)?.toDouble();
        final az = (r['az'] as num?)?.toDouble();
        double? enmo;
        if (ax != null && ay != null && az != null) {
          final mag = math.sqrt(ax * ax + ay * ay + az * az);
          // Нулевой вектор — ускорения нет (не «покой»).
          if (mag > 0.2) enmo = (mag - 1).abs();
        }
        secs.add(
          StressSec(
            (r['rec_ts'] as num).toInt(),
            hr: (r['hr'] as num?)?.toInt(),
            hrValid: (r['hr_valid'] as num?)?.toInt() != 0,
            enmo: enmo,
            cls: (r['activity_class'] as num?)?.toInt(),
            onWrist: (r['on_wrist'] as num?)?.toInt() != 0,
          ),
        );
      }
      final last = page.last;
      afterTs = (last['rec_ts'] as num).toInt();
      afterCounter = (last['counter'] as num?)?.toInt() ?? 0;
      if (page.length < 6000) break;
    }
    secs.sort((a, b) => a.ts.compareTo(b.ts));
    final beats = <StressBeat>[];
    for (var a = from; a < to; a += 3600) {
      final rows = await LocalDb.decodedRrByRecTsRange(
        fromRecTs: a,
        toRecTs: math.min(a + 3600, to) - 1,
      );
      for (final r in rows) {
        final bt = (r['beat_ts_ms'] as num?) ?? (r['rr_ts_ms'] as num?);
        final rr = (r['rr_ms'] as num?)?.toInt();
        if (bt == null || rr == null) continue;
        beats.add(StressBeat(bt.toInt() ~/ 1000, rr));
      }
    }
    beats.sort((a, b) => a.ts.compareTo(b.ts));
    return (secs, beats);
  }
}

/// Сон и тренировки, пересекающие [from, to).
Future<(List<Span>, List<Span>)> _spans(
  LocalRepository repo,
  int from,
  int to,
) async {
  final sleep = <Span>[], work = <Span>[];
  try {
    for (final w in await repo.sleepWindows(days: 20)) {
      final a = (w['onset_ts'] as num?)?.toInt();
      final b = (w['wake_ts'] as num?)?.toInt();
      if (a != null && b != null && b > from && a < to) {
        sleep.add((from: a, to: b));
      }
    }
  } catch (_) {}
  try {
    for (final s in await repo.getSessions(
      from: from,
      to: to,
      includeDetected: false,
    )) {
      final a = (s['start_ts'] as num?)?.toInt();
      if (a == null) continue;
      final e =
          (s['end_ts'] as num?)?.toInt() ??
          a + (((s['duration_min'] as num?) ?? 0) * 60).round();
      if (e > a) work.add((from: a, to: e));
    }
  } catch (_) {}
  return (sleep, work);
}

Future<List<StressWin>> _dayWins(
  LocalRepository repo,
  DateTime day,
  int until,
) async {
  final from = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch ~/ 1000;
  final end = DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch ~/ 1000;
  final to = math.min(end, until);
  if (to <= from) return const [];
  final (secs, beats) = await RitmStressStore.read(from, to);
  if (secs.isEmpty) return const [];
  final (sleep, work) = await _spans(repo, from, to);
  return stressWindows(secs, beats, sleep: sleep, workouts: work);
}

/// День [day] целиком (сегодня — до [now]) + норма по 14 прошлым дням.
/// Прошлые дни, которых нет в кэше, досчитываются из сырых секунд, пока Edge
/// их хранит (5 дней).
Future<StressDay> loadStressDay(
  LocalRepository repo,
  DateTime day,
  DateTime now,
) async {
  final nowTs = now.millisecondsSinceEpoch ~/ 1000;
  final wins = await _dayWins(repo, day, nowTs);
  final id = RitmStressStore.dayId(day);
  if (wins.isNotEmpty) await RitmStressStore.save(id, wins);
  final past = <List<(double, double)>>[];
  for (var back = kStressBaseDays; back >= 1; back--) {
    final d = DateTime(day.year, day.month, day.day - back);
    final pid = RitmStressStore.dayId(d);
    var q = await RitmStressStore.quiet(pid);
    if (q == null && back <= 4) {
      final w = await _dayWins(repo, d, nowTs);
      if (w.isNotEmpty) {
        await RitmStressStore.save(pid, w);
        q = [
          for (final x in w)
            if (x.quiet) (x.hr!, x.lnRmssd!),
        ];
      }
    }
    if (q != null) past.add(q);
  }
  return stressDay(wins, pastQuiet: past, now: nowTs);
}
