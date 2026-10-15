// «Ритм» — тренировки сборки B3 (ТЗ v2 §6, §10.6, §10.9):
// мягкий ярус автоопределения по секундам браслета, приоритет Apple Watch,
// пикер типа, экран тренировки с восстановлением пульса (HRR) и сверкой
// пульса браслет / Watch.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../data/db.dart' show LocalDb;
import '../state/app_state.dart';
import '../state/prefs.dart';
import 'ritm_bio_ui.dart' show ritmAgeOf;
import 'ritm_charts.dart' show ZoneBars;
import 'ritm_demo.dart' show kRitmDemo;
import 'ritm_hk.dart';
import 'ritm_rings_store.dart' show RitmRingsStore;
import 'ritm_scores.dart' show clock, dec1, thousands;
import 'ritm_ui.dart';

// ───────────────────────── отклонённые ─────────────────────────

class RitmWkDismissed {
  static const _key = 'ritm.wk.dismissed';

  /// Начала (unix, с) отклонённых «Нет» тренировок — повторно не предлагаем.
  static Set<int> get all => {
    for (final x in Prefs.getString(_key, '').split(','))
      if (int.tryParse(x) != null) int.parse(x),
  };

  static void add(int startTs) {
    final s = all..add(startTs);
    // Храним последние 200.
    final l = s.toList()..sort();
    Prefs.setString(
      _key,
      (l.length > 200 ? l.sublist(l.length - 200) : l).join(','),
    );
  }
}

// ───────────────────────── мягкий ярус по секундам браслета ─────────────────────────

/// Секунды браслета за [from, to) (unix, с) для классификатора.
Future<List<WkSec>> readWkSecs(int from, int to) async {
  final out = <WkSec>[];
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
        final m2 = ax * ax + ay * ay + az * az;
        if (m2 > 0.04) enmo = (_sqrt(m2) - 1).abs();
      }
      out.add(
        WkSec(
          (r['rec_ts'] as num).toInt(),
          hr: (r['hr'] as num?)?.toInt(),
          valid: (r['hr_valid'] as num?)?.toInt() != 0,
          cls: (r['activity_class'] as num?)?.toInt(),
          cadence: (r['step_cadence'] as num?)?.toInt(),
          enmo: enmo,
        ),
      );
    }
    final last = page.last;
    afterTs = (last['rec_ts'] as num).toInt();
    afterCounter = (last['counter'] as num?)?.toInt() ?? 0;
    if (page.length < 6000) break;
  }
  return out;
}

double _sqrt(double x) {
  var r = x;
  for (var i = 0; i < 20; i++) {
    r = 0.5 * (r + x / r);
  }
  return r;
}

/// Тренировки мягкого яруса за день, которых нет ни в сохранённых
/// тренировках, ни в пендингах Edge (жёсткий ярус), ни у Watch, ни в
/// отклонённых.
List<WkCandidate> softCandidates(
  List<WkCandidate> found, {
  required List<({int from, int to})> busy,
  required List<HkWorkout> watch,
  Set<int> dismissed = const {},
}) => [
  for (final c in found)
    if (!c.hard &&
        !busy.any((b) => c.from < b.to && b.from < c.to) &&
        wkAction(
              DateTime.fromMillisecondsSinceEpoch(c.from * 1000),
              DateTime.fromMillisecondsSinceEpoch(c.to * 1000),
              watch: watch,
              dismissed: dismissed,
            ) ==
            WkAction.ask)
      c,
];

/// Демо (DEBUG): секунды браслета прогулки 06:42–07:09 (ходьба, каденс
/// ~114, пульс ~100) — классификатор работает на них так же, как на живых.
List<WkSec> demoWalkSecs(DateTime day) {
  final t0 = DateTime(day.year, day.month, day.day, 6, 30)
          .millisecondsSinceEpoch ~/
      1000;
  final out = <WkSec>[];
  for (var k = 0; k < 50 * 60; k++) {
    final t = t0 + k;
    final walking = k >= 12 * 60 && k < 39 * 60;
    out.add(
      WkSec(
        t,
        hr: walking ? 98 + (k % 97) ~/ 20 : 66 + (k % 7),
        cls: walking ? 1 : 0,
        cadence: walking ? 108 + (k % 13) : 0,
        enmo: walking ? .12 : .01,
      ),
    );
  }
  return out;
}

// ───────────────────────── пикер типа ─────────────────────────

const kRitmWkPicker = [
  ('running', 'Бег'),
  ('walking', 'Ходьба'),
  ('cycling', 'Велосипед'),
  ('weight_training', 'Силовая'),
  ('elliptical', 'Кардио'),
  ('swimming', 'Плавание'),
  ('other', 'Другое'),
];

/// Своя иконка у каждого типа в выборе (у Edge бег и ходьба — одна).
const kRitmWkIcons = <String, IconData>{
  'running': LucideIcons.footprints,
  'walking': LucideIcons.personStanding,
  'cycling': LucideIcons.bike,
  'weight_training': LucideIcons.dumbbell,
  'elliptical': LucideIcons.heartPulse,
  'swimming': LucideIcons.waves,
  'other': LucideIcons.ellipsis,
};

/// Выбор типа тренировки (кнопка «Другой тип»). Возвращает ключ Edge.
Future<String?> showRitmWkTypePicker(BuildContext c) => showRSheet<String>(
  c,
  (sc) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text('Какая это была тренировка?', style: RT.title),
      ),
      for (final (k, name) in kRitmWkPicker)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: RButton(
            kRitmWkIcons[k] ?? LucideIcons.activity,
            name,
            height: 44,
            onTap: () => Navigator.of(sc).pop(k),
          ),
        ),
    ],
  ),
);

// ───────────────────────── экран тренировки ─────────────────────────

/// Тренировка дня: браслет, Watch или обе (слиты по времени ≥ 50 %).
class RitmDayWorkout {
  final String name;
  final DateTime start, end;
  final double? strain;
  final int? bandAvgHr;

  /// Доля секунд с валидным пульсом браслета (null — не считали).
  final double? bandValidShare;
  final HkWorkout? watch;
  final WorkoutHrr? hrr;
  final IconData icon;
  final bool auto;
  const RitmDayWorkout({
    required this.name,
    required this.start,
    required this.end,
    this.strain,
    this.bandAvgHr,
    this.bandValidShare,
    this.watch,
    this.hrr,
    this.icon = LucideIcons.activity,
    this.auto = false,
  });

  int get minutes => end.difference(start).inMinutes;
  String get span =>
      '${clock(start.hour * 60 + start.minute)}–${clock(end.hour * 60 + end.minute)}';
}

/// Зоны пульса — доля РЕЗЕРВА (HR − покой)/(макс − покой), как у Нагрузки
/// (ТЗ v3 §7.3): 1 — 40–60 %, 2 — 60–70, 3 — 70–80, 4 — 80–90, 5 — от 90 %.
const kZoneFrac = [.4, .6, .7, .8, .9];

/// Пульс на нижней границе зоны [z] (0..4 → зоны 1..5).
double zoneHr(int z, double hrMax, double rhr) => rhr + (hrMax - rhr) * kZoneFrac[z];

/// Номер зоны 0–5 (0 — ниже зоны 1) по доле резерва.
int hrZone(double hr, double hrMax, double rhr) {
  final f = (hr - rhr) / math.max(20.0, hrMax - rhr);
  var z = 0;
  for (var i = 0; i < kZoneFrac.length; i++) {
    if (f >= kZoneFrac[i]) z = i + 1;
  }
  return z;
}

/// Минуты в зонах 1–5 по ряду пульса (каждый замер «живёт» до следующего,
/// но не дольше 30 с — дыры не заливаем).
List<int> zoneMinutes(List<(DateTime, double)> s, double hrMax, double rhr) {
  final sec = List<double>.filled(5, 0);
  for (var i = 0; i < s.length; i++) {
    final z = hrZone(s[i].$2, hrMax, rhr);
    if (z == 0) continue;
    final dt = i + 1 < s.length
        ? s[i + 1].$1.difference(s[i].$1).inMilliseconds / 1000
        : 5.0;
    sec[z - 1] += dt.clamp(0, 30);
  }
  return [for (final x in sec) (x / 60).round()];
}

/// Максимальный пульс: из профиля, иначе по формуле Танаки от возраста.
double workoutHrMax({num? profileMax, int? age}) {
  if (profileMax != null && profileMax > 120) return profileMax.toDouble();
  if (age != null) return (208 - .7 * age).roundToDouble();
  return 185;
}

/// График пульса тренировки по зонам: цветные полосы зон, линия пульса
/// цветом зоны каждого участка, ось времени.
class WorkoutHrChart extends StatelessWidget {
  final List<(DateTime, double)> s;
  final double hrMax, rhr;
  const WorkoutHrChart({super.key, required this.s, required this.hrMax, required this.rhr});

  @override
  Widget build(BuildContext c) => SizedBox(
    height: 180,
    width: double.infinity,
    child: CustomPaint(painter: _HrZonePainter(s, hrMax, rhr)),
  );
}

class _HrZonePainter extends CustomPainter {
  final List<(DateTime, double)> s;
  final double hrMax, rhr;
  _HrZonePainter(this.s, this.hrMax, this.rhr);

  @override
  void paint(Canvas canvas, Size sz) {
    if (s.length < 2) return;
    const left = 34.0, bottom = 18.0;
    final w = sz.width - left, h = sz.height - bottom;
    final lo = (rhr + (hrMax - rhr) * .3).floorToDouble();
    final hi = hrMax;
    double y(double v) => h - h * ((v - lo) / (hi - lo)).clamp(0, 1);
    final t0 = s.first.$1, t1 = s.last.$1;
    final span = math.max(1, t1.difference(t0).inSeconds);
    double x(DateTime t) => left + w * t.difference(t0).inSeconds / span;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    // Полосы зон.
    for (var z = 0; z < 5; z++) {
      final a = zoneHr(z, hrMax, rhr);
      final b = z == 4 ? hi : zoneHr(z + 1, hrMax, rhr);
      canvas.drawRect(
        Rect.fromLTRB(left, y(b), sz.width, y(a)),
        Paint()..color = ZoneBars.colors[z].withValues(alpha: .10),
      );
      tp.text = TextSpan(
        text: '${a.round()}',
        style: RT.micro.copyWith(color: ZoneBars.colors[z]),
      );
      tp.layout();
      tp.paint(canvas, Offset(0, y(a) - tp.height / 2));
    }
    // Линия пульса: каждый участок — цветом своей зоны.
    final p = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < s.length; i++) {
      final z = hrZone((s[i - 1].$2 + s[i].$2) / 2, hrMax, rhr);
      p.color = z == 0 ? RC.ink3 : ZoneBars.colors[z - 1];
      canvas.drawLine(
        Offset(x(s[i - 1].$1), y(s[i - 1].$2)),
        Offset(x(s[i].$1), y(s[i].$2)),
        p,
      );
    }
    for (final f in [0.0, .5, 1.0]) {
      final t = t0.add(Duration(seconds: (span * f).round()));
      tp.text = TextSpan(
        text: clock(t.hour * 60 + t.minute),
        style: RT.micro,
      );
      tp.layout();
      tp.paint(canvas, Offset(left + w * f - tp.width * f, sz.height - tp.height));
    }
  }

  @override
  bool shouldRepaint(_HrZonePainter o) => o.s != s || o.hrMax != hrMax || o.rhr != rhr;
}

class RitmWorkoutScreen extends StatelessWidget {
  final RitmDayWorkout w;

  /// Пульс браслета внутри тренировки (если нет ряда Watch).
  final List<(DateTime, double)> bandHr;

  /// Демо-скриншот нижней части экрана.
  final bool scrollEnd;
  const RitmWorkoutScreen({
    super.key,
    required this.w,
    this.bandHr = const [],
    this.scrollEnd = false,
  });

  @override
  Widget build(BuildContext c) {
    final ww = w.watch;
    final hrr = w.hrr;
    final series = (ww?.hrSeries.isNotEmpty ?? false) ? ww!.hrSeries : bandHr;
    num? profMax;
    try {
      final u = c.read<AppState>().user;
      profMax = (u?['max_hr'] as num?) ?? (u?['hr_max'] as num?);
    } catch (_) {}
    final hrMax = workoutHrMax(profileMax: profMax, age: ritmAgeOf(c, w.start));
    // Пульс покоя — тот же, что у Нагрузки дня (кэш колец), иначе 60.
    final rhr = RitmRingsStore.dayResult(_dayKey(w.start))?.inputs.rhrForStrain ??
        (kRitmDemo ? 51.0 : 60.0);
    final stat = <(String, String, String)>[
      ('Время', w.span, '${w.minutes} мин'),
      if (ww?.distM != null) ('Дистанция', distRu(ww!.distM!), 'Apple Watch'),
      if (w.strain != null) ('Нагрузка', dec1(w.strain!), 'браслет'),
      if (ww?.kcal != null)
        ('Калории', thousands(ww!.kcal!.round()), 'ккал · Apple Watch'),
    ];
    Widget cell((String, String, String) x) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(x.$1.toUpperCase(), style: RT.cap),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(x.$2, style: RT.num.copyWith(fontSize: 22)),
          ),
          const SizedBox(height: 2),
          Text(x.$3, style: RT.small),
        ],
      ),
    );
    final rows = <Widget>[];
    for (var i = 0; i < stat.length; i += 2) {
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
          child: Row(
            children: [
              cell(stat[i]),
              const SizedBox(width: 12),
              if (i + 1 < stat.length) cell(stat[i + 1]) else const Spacer(),
            ],
          ),
        ),
      );
    }
    // Пульс: у кого больше секунд с пульсом.
    String? hrLine;
    String? hrWin;
    if (w.bandAvgHr != null && ww?.hrAvg != null) {
      final win = workoutHrWinner(
        bandShare: w.bandValidShare ?? 1,
        watchN: ww!.hrN,
        seconds: w.end.difference(w.start).inSeconds,
      );
      hrLine = 'браслет ${w.bandAvgHr} · Watch ${ww.hrAvg!.round()}';
      hrWin = switch (win.winner) {
        'Watch' =>
          'Точнее Watch: пульс есть в ${(win.watchShare * 100).round()} % секунд, у браслета — в ${(win.bandShare * 100).round()} %. В итог идёт пульс Watch.',
        'браслет' =>
          'Точнее браслет: пульс есть в ${(win.bandShare * 100).round()} % секунд, у Watch — в ${(win.watchShare * 100).round()} %. В итог идёт пульс браслета.',
        _ => 'Оба записали пульс всю тренировку.',
      };
    } else if (ww?.hrAvg != null) {
      hrLine = 'Watch ${ww!.hrAvg!.round()} · максимум ${ww.hrMax?.round() ?? '—'}';
    } else if (w.bandAvgHr != null) {
      hrLine = 'браслет ${w.bandAvgHr}';
    }
    final ctl = scrollEnd ? ScrollController() : null;
    if (ctl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ctl.hasClients) ctl.jumpTo(ctl.position.maxScrollExtent);
      });
    }
    return RPage(
      title: w.name,
      controller: ctl,
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: w.strain == null ? RC.cardHi : RC.strain(w.strain!),
                      borderRadius: BorderRadius.circular(RS.rTile),
                    ),
                    child: Icon(w.icon, color: RC.ink, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(w.name, style: RT.title),
                        Text(
                          [
                            if (ww != null) 'Apple Watch',
                            if (w.strain != null || w.bandAvgHr != null)
                              'браслет',
                          ].join(' + '),
                          style: RT.small,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...rows,
            ],
          ),
        ),
        if (series.length >= 10) ...[
          const SizedBox(height: RS.cardGap),
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RCardHead(
                  'Пульс по зонам',
                  trailing: null,
                  trailingWidget: Text(
                    ww?.hrSeries.isNotEmpty == true ? 'Apple Watch' : 'браслет',
                    style: RT.small,
                  ),
                ),
                const SizedBox(height: 12),
                WorkoutHrChart(s: series, hrMax: hrMax, rhr: rhr),
                const SizedBox(height: 14),
                ZoneBars(minutes: zoneMinutes(series, hrMax, rhr)),
                const SizedBox(height: 8),
                Text(
                  'Зоны — доля резерва пульса (от покоя ${rhr.round()} до максимума ${hrMax.round()}), как в Нагрузке: '
                  '1 — 40–60\u00a0%, 2 — 60–70\u00a0%, 3 — 70–80\u00a0%, 4 — 80–90\u00a0%, 5 — от 90\u00a0%.',
                  style: RT.small,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: RS.cardGap),
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Восстановление пульса', trailing: null),
              const SizedBox(height: 10),
              if (hrr == null)
                const Text(
                  'Нет замера: для него нужен пульс в первую минуту после финиша (Apple Watch или браслет на руке).',
                  style: RT.body,
                )
              else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('−${hrr.drop}', style: RT.num.copyWith(fontSize: 34)),
                    const SizedBox(width: 6),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text('уд/мин за 1 минуту', style: RT.small),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          RDot(
                            hrr.drop >= 21
                                ? RC.green
                                : (hrr.drop >= 12 ? RC.yellow : RC.red),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            hrr.word,
                            style: RT.body.copyWith(color: RC.ink),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Насколько упал пульс за минуту после финиша. Чем больше, тем лучше тренировано сердце: меньше 12 — медленно, 12–20 — обычно, 21–29 — хорошо, от 30 — отлично. Источник: ${hrr.source}.',
                  style: RT.small,
                ),
              ],
            ],
          ),
        ),
        if (hrLine != null) ...[
          const SizedBox(height: RS.cardGap),
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const RCardHead('Пульс в среднем', trailing: null),
                const SizedBox(height: 10),
                Text(hrLine, style: RT.title),
                if (hrWin != null) ...[
                  const SizedBox(height: 6),
                  Text(hrWin, style: RT.small),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Открыть экран тренировки; без ряда Watch — подгрузить пульс браслета.
Future<void> openRitmWorkout(BuildContext c, RitmDayWorkout w) async {
  var band = const <(DateTime, double)>[];
  if (w.watch?.hrSeries.isEmpty ?? true) {
    try {
      final rows = await LocalDb.hrSamplesInRange(
        w.start.millisecondsSinceEpoch ~/ 1000,
        w.end.millisecondsSinceEpoch ~/ 1000,
      );
      // 1 Гц → раз в 5 с: для графика хватает.
      band = [
        for (var i = 0; i < rows.length; i += 5)
          if (rows[i]['rec_ts'] is num && rows[i]['hr'] is num)
            (
              DateTime.fromMillisecondsSinceEpoch(
                (rows[i]['rec_ts'] as num).toInt() * 1000,
              ),
              (rows[i]['hr'] as num).toDouble(),
            ),
      ];
    } catch (_) {}
  }
  if (!c.mounted) return;
  await Navigator.of(c).push(
    MaterialPageRoute<void>(builder: (_) => RitmWorkoutScreen(w: w, bandHr: band)),
  );
}

String _dayKey(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
