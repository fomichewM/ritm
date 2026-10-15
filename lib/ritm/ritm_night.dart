// «Ритм» B4¾ — экран «Ночь» (ТЗ v3 U2): гипнограмма с прокруткой по времени и
// кривые на общей оси: пульс, ВСР (rMSSD 5 мин), ночной стресс, сигнал браслета.
// Стадии — «оценка» (стейджер по пульсу и движению, §7.5 п. 1).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui2/screens/home_screen.dart' show repoOf;
import 'ritm_charts.dart' show StageBar;
import 'ritm_demo.dart' as demo;
import 'ritm_rings.dart' show TV;
import 'ritm_sleep.dart';
import 'ritm_ui.dart';

/// Гипнограмма точками {t, stage} (getDaySleep) → отрезки.
List<StageRun> stageRunsOf(Object? hypnogram) {
  final pts = hypnogram is List ? hypnogram : const [];
  Stage? st(Object? s) => switch ('$s') {
    'wake' || 'awake' => Stage.wake,
    'light' => Stage.light,
    'deep' => Stage.deep,
    'rem' => Stage.rem,
    _ => null,
  };
  return [
    for (var i = 0; i + 1 < pts.length; i++)
      if (pts[i] is Map && pts[i + 1] is Map && pts[i]['t'] is num && pts[i + 1]['t'] is num)
        (from: (pts[i]['t'] as num).toInt(), to: (pts[i + 1]['t'] as num).toInt(), stage: st(pts[i]['stage'])),
  ];
}

class RitmNightData {
  final int from, to;
  final List<StageRun> stages;
  final List<TV> hr, hrv, stress, signal;

  /// low / med — уверенность стадий (§7.5).
  final String stagesConf;
  const RitmNightData({
    required this.from,
    required this.to,
    required this.stages,
    required this.hr,
    required this.hrv,
    required this.stress,
    required this.signal,
    this.stagesConf = 'low',
  });

  static RitmNightData? of({required Map sleep, required Map heart, required Map hrv}) {
    final runs = stageRunsOf(sleep['hypnogram']);
    if (runs.isEmpty) return null;
    final from = runs.first.from, to = runs.last.to;
    List<TV> inWin(List<TV> x) => [for (final p in x) if (p.t >= from && p.t <= to) p];
    final hr = inWin(TV.parse(heart['hr']));
    final rm = inWin(TV.parse(hrv['timeline']));
    final sig = signalOf(hr, from, to);
    final good = sig.isEmpty ? 0.0 : sig.where((p) => p.v >= 80).length / sig.length;
    return RitmNightData(
      from: from,
      to: to,
      stages: runs,
      hr: hr,
      hrv: rm,
      stress: nightStressOf(hr, rm),
      signal: sig,
      stagesConf: good >= .85 ? 'med' : 'low',
    );
  }
}

class RitmNightScreen extends StatefulWidget {
  final String? day;
  final RitmNightData? data;
  const RitmNightScreen({super.key, this.day, this.data});
  @override
  State<RitmNightScreen> createState() => _RitmNightScreenState();
}

class _RitmNightScreenState extends State<RitmNightScreen> {
  RitmNightData? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _d = widget.data ?? demo.ritmDemoNight();
    if (_d != null) {
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) return setState(() => _loading = false);
    final n = DateTime.now();
    final day = widget.day ??
        '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
    try {
      final s = await repo.getDaySleep(day) as Map;
      final h = await repo.getDayHeart(day) as Map;
      final v = await repo.getDayHrv(day) as Map;
      if (!mounted) return;
      setState(() {
        _d = RitmNightData.of(sleep: s, heart: h, hrv: v);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final d = _d;
    return RPage(
      title: 'Ночь',
      children: [
        if (d == null)
          RCard(
            child: Text(_loading ? 'Считаем ночь…' : 'Ночь ещё не посчитана.', style: RT.body),
          )
        else ...[
          _summary(d),
          const SizedBox(height: RS.cardGap),
          RCard(
            pad: const EdgeInsets.fromLTRB(0, RS.cardPad, 0, RS.cardPad),
            child: _NightLanes(d: d),
          ),
          const SizedBox(height: RS.cardGap),
          const Text(
            'Листайте по времени. Стадии — оценка по пульсу и движению: точнее всего '
            'видно бодрствование и глубокий сон, граница лёгкого и быстрого — приблизительна.',
            style: RT.small,
          ),
        ],
      ],
    );
  }

  Widget _summary(RitmNightData d) {
    final m = stageMinutes(d.stages);
    final a = awakeningsOf(d.stages);
    String hm(int t) {
      final x = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      return '${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';
    }

    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Стадии', trailing: null),
          const SizedBox(height: RS.tileHead),
          Text('${hm(d.from)} → ${hm(d.to)}', style: RT.num.copyWith(fontSize: 22)),
          const SizedBox(height: 8),
          _ConfBadge(conf: d.stagesConf),
          const SizedBox(height: 12),
          StageBar(
            awake: m[Stage.wake]!,
            light: m[Stage.light]!,
            deep: m[Stage.deep]!,
            rem: m[Stage.rem]!,
          ),
          const SizedBox(height: 10),
          Text(
            'Пробуждений ${a.long} (≥ 5 мин), коротких ${a.short} · '
            'бодрствование между снами ${a.awakeMin} мин',
            style: RT.body,
          ),
        ],
      ),
    );
  }
}

/// Бейдж «оценка» с уверенностью (§7.5).
class _ConfBadge extends StatelessWidget {
  final String conf;
  const _ConfBadge({required this.conf});
  @override
  Widget build(BuildContext c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: RC.cardHi,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      conf == 'med'
          ? 'стадии — оценка по пульсу и движению · точность средняя'
          : 'стадии — оценка по пульсу и движению · точность низкая',
      style: RT.micro.copyWith(color: RC.ink2),
    ),
  );
}

/// Дорожки на общей оси времени; ширина — 96 px на час, листается.
class _NightLanes extends StatelessWidget {
  final RitmNightData d;
  const _NightLanes({required this.d});

  static const pxPerHour = 96.0;
  static const labelW = 16.0;

  @override
  Widget build(BuildContext c) {
    final hours = (d.to - d.from) / 3600;
    final w = math.max(320.0, hours * pxPerHour);
    final lanes = <(String, String, Widget)>[
      ('Стадии', '', _lane(_HypPainter(d), 72, w)),
      ('Пульс', _range(d.hr, 'уд/мин'), _lane(_CurvePainter(d, d.hr, RC.red), 64, w)),
      ('ВСР', _range(d.hrv, 'мс'), _lane(_CurvePainter(d, d.hrv, RC.brandA), 64, w)),
      (
        'Ночной стресс',
        '${((stressFracOf(d.stress) ?? 0) * 100).round()}\u00a0% ночи с заметным стрессом',
        _lane(_CurvePainter(d, d.stress, RC.yellow, lo: 0, hi: 3), 48, w),
      ),
      ('Сигнал браслета', _sigText(d.signal), _lane(_CurvePainter(d, d.signal, RC.ink2, lo: 0, hi: 100), 36, w)),
    ];
    return SingleChildScrollView(
      key: const Key('night-scroll'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: labelW),
      child: SizedBox(
        width: w,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lanes) ...[
              Row(
                children: [
                  Text(l.$1, style: RT.label.copyWith(color: RC.ink)),
                  const SizedBox(width: 8),
                  Text(l.$2, style: RT.small),
                ],
              ),
              const SizedBox(height: 6),
              l.$3,
              const SizedBox(height: 14),
            ],
            _lane(_AxisPainter(d), 16, w),
          ],
        ),
      ),
    );
  }

  static String _range(List<TV> x, String unit) {
    if (x.isEmpty) return 'нет данных';
    final v = [for (final p in x) p.v]..sort();
    return '${v.first.round()}–${v.last.round()} $unit';
  }

  static String _sigText(List<TV> s) {
    if (s.isEmpty) return 'нет данных';
    final good = s.where((p) => p.v >= 80).length / s.length;
    return 'браслет видел ${(good * 100).round()}\u00a0% ночи';
  }

  static Widget _lane(CustomPainter p, double h, double w) =>
      SizedBox(width: w, height: h, child: CustomPaint(painter: p));
}

double _x(RitmNightData d, int t, double w) => (t - d.from) / math.max(1, d.to - d.from) * w;

class _HypPainter extends CustomPainter {
  final RitmNightData d;
  _HypPainter(this.d);
  static int _row(Stage s) => switch (s) {
    Stage.wake => 0,
    Stage.rem => 1,
    Stage.light => 2,
    Stage.deep => 3,
  };
  static Color _col(Stage s) => switch (s) {
    Stage.wake => StageBar.awakeC,
    Stage.rem => StageBar.remC,
    Stage.light => StageBar.lightC,
    Stage.deep => StageBar.deepC,
  };
  @override
  void paint(Canvas c, Size z) {
    final rowH = z.height / 4;
    final grid = Paint()..color = RC.line;
    for (var i = 1; i < 4; i++) {
      c.drawLine(Offset(0, rowH * i), Offset(z.width, rowH * i), grid);
    }
    for (final r in d.stages) {
      final s = r.stage;
      if (s == null) continue;
      final y = _row(s) * rowH;
      c.drawRRect(
        RRect.fromLTRBR(_x(d, r.from, z.width), y + 2, math.max(_x(d, r.to, z.width), _x(d, r.from, z.width) + 1.5),
            y + rowH - 2, const Radius.circular(3)),
        Paint()..color = _col(s),
      );
    }
  }

  @override
  bool shouldRepaint(_HypPainter o) => o.d != d;
}

class _CurvePainter extends CustomPainter {
  final RitmNightData d;
  final List<TV> xs;
  final Color col;
  final double? lo, hi;
  _CurvePainter(this.d, this.xs, this.col, {this.lo, this.hi});
  @override
  void paint(Canvas c, Size z) {
    c.drawLine(Offset(0, z.height - .5), Offset(z.width, z.height - .5), Paint()..color = RC.line);
    if (xs.length < 2) return;
    final v = [for (final p in xs) p.v];
    final a = lo ?? v.reduce(math.min), b = hi ?? v.reduce(math.max);
    final span = math.max(1e-6, b - a);
    final path = Path();
    var gap = true;
    for (var i = 0; i < xs.length; i++) {
      final p = xs[i];
      if (i > 0 && p.t - xs[i - 1].t > 900) gap = true;
      final o = Offset(_x(d, p.t, z.width), z.height - 2 - (p.v - a) / span * (z.height - 4));
      if (gap) {
        path.moveTo(o.dx, o.dy);
        gap = false;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    c.drawPath(
      path,
      Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter o) => o.xs != xs;
}

class _AxisPainter extends CustomPainter {
  final RitmNightData d;
  _AxisPainter(this.d);
  @override
  void paint(Canvas c, Size z) {
    final first = DateTime.fromMillisecondsSinceEpoch(d.from * 1000);
    var t = DateTime(first.year, first.month, first.day, first.hour);
    if (t.isBefore(first)) t = t.add(const Duration(hours: 1));
    while (t.millisecondsSinceEpoch ~/ 1000 <= d.to) {
      final x = _x(d, t.millisecondsSinceEpoch ~/ 1000, z.width);
      final tp = TextPainter(
        text: TextSpan(text: '${t.hour.toString().padLeft(2, '0')}:00', style: RT.micro),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset((x - tp.width / 2).clamp(0, z.width - tp.width).toDouble(), 0));
      t = t.add(const Duration(hours: 1));
    }
  }

  @override
  bool shouldRepaint(_AxisPainter o) => false;
}
