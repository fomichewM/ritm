// «Ритм» — графики (ТЗ v2 §2 п. 7–8, §3, §4.3): стресс за день, нагрузка и
// восстановление за 7 дней, коридор 30 дней, кривая нагрузки дня, зоны.
// Только CustomPainter, цвета — токены RC.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ritm_rings.dart' show HrSegment, HrSrc;
import 'ritm_scores.dart' show dec1;
import 'ritm_stress.dart';
import 'ritm_ui.dart';

const _axis = TextStyle(
  fontFamily: RT.family,
  fontSize: 11,
  fontWeight: FontWeight.w500,
  color: RC.ink3,
  fontFeatures: [FontFeature.tabularFigures()],
);

void _text(Canvas c, String s, Offset at, {TextStyle style = _axis, double ax = 0, double ay = 0}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, at - Offset(tp.width * ax, tp.height * ay));
}

String _hh(int sec) {
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// ───────────────────────── стресс за день (§2.7) ─────────────────────────

class StressDayChart extends StatelessWidget {
  final StressDay day;
  final int dayStart; // полночь, unix с
  final int now; // правый край оси
  final double height;
  const StressDayChart({
    super.key,
    required this.day,
    required this.dayStart,
    required this.now,
    this.height = 180,
  });

  @override
  Widget build(BuildContext c) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: _StressPainter(day, dayStart, now)),
  );
}

class _StressPainter extends CustomPainter {
  final StressDay d;
  final int start, end;
  _StressPainter(this.d, this.start, this.end);

  @override
  void paint(Canvas c, Size s) {
    const left = 22.0, bottom = 18.0, top = 6.0;
    final w = s.width - left, h = s.height - bottom - top;
    final span = math.max(3600, end - start).toDouble();
    double x(int t) => left + w * ((t - start) / span).clamp(0.0, 1.0);
    double y(double v) => top + h * (1 - v / 3);
    final grid = Paint()
      ..color = RC.line
      ..strokeWidth = 1;
    for (final v in [0, 1, 2, 3]) {
      c.drawLine(Offset(left, y(v.toDouble())), Offset(s.width, y(v.toDouble())), grid);
      _text(c, '$v', Offset(left - 6, y(v.toDouble())), ax: 1, ay: .5);
    }
    // Полосы сна и штриховка тренировок.
    void spans(StressGap g, void Function(Rect) draw) {
      int? a;
      int? last;
      for (final p in d.points) {
        if (p.gap == g) {
          a ??= p.t - kStressStepSec;
          last = p.t;
        } else if (a != null) {
          draw(Rect.fromLTRB(x(a), top, x(last!), top + h));
          a = null;
        }
      }
      if (a != null) draw(Rect.fromLTRB(x(a), top, x(last!), top + h));
    }

    spans(StressGap.sleep, (r) {
      c.drawRect(r, Paint()..color = RC.sleepBlue.withValues(alpha: .12));
    });
    spans(StressGap.workout, (r) {
      c.save();
      c.clipRect(r);
      final hatch = Paint()
        ..color = RC.ink3.withValues(alpha: .55)
        ..strokeWidth = 1;
      for (var xx = r.left - r.height; xx < r.right; xx += 6) {
        c.drawLine(Offset(xx, r.bottom), Offset(xx + r.height, r.top), hatch);
      }
      c.restore();
    });
    // Линия и заливка по посчитанным окнам; разрыв > 10 мин — новый отрезок.
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..color = RC.brandA;
    final fill = Paint()..color = RC.brandA.withValues(alpha: .12);
    var seg = <Offset>[];
    int? lastT;
    void flush() {
      if (seg.length >= 2) {
        final p = Path()..moveTo(seg.first.dx, seg.first.dy);
        for (final o in seg.skip(1)) {
          p.lineTo(o.dx, o.dy);
        }
        c.drawPath(p, line);
        final f = Path.from(p)
          ..lineTo(seg.last.dx, y(0))
          ..lineTo(seg.first.dx, y(0))
          ..close();
        c.drawPath(f, fill);
      } else if (seg.length == 1) {
        c.drawCircle(seg.first, 1.5, Paint()..color = RC.brandA);
      }
      seg = <Offset>[];
    }

    for (final p in d.points) {
      if (p.s == null) continue;
      if (lastT != null && p.t - lastT > 600) flush();
      seg.add(Offset(x(p.t), y(p.s!)));
      lastT = p.t;
    }
    flush();
    // Метки X: 00:00 и далее каждые 7 ч, последняя — «сейчас».
    for (var k = 0; k * 7 * 3600 < span; k++) {
      final t = start + k * 7 * 3600;
      _text(c, _hh(t), Offset(x(t), top + h + 4), ax: k == 0 ? 0 : .5);
    }
  }

  @override
  bool shouldRepaint(_StressPainter o) => o.d != d || o.end != end;
}

// ───────────────────── нагрузка и восстановление 7 дней (§2.8) ─────────────

class WeekDayPoint {
  final DateTime day;
  final double? strain; // 0–21
  final double? recovery; // 0–100
  const WeekDayPoint(this.day, {this.strain, this.recovery});
}

const _wd = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

class WeekChart extends StatelessWidget {
  final List<WeekDayPoint> days;
  final double height;
  const WeekChart({super.key, required this.days, this.height = 220});
  @override
  Widget build(BuildContext c) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: _WeekPainter(days)),
  );
}

class _WeekPainter extends CustomPainter {
  final List<WeekDayPoint> d;
  _WeekPainter(this.d);

  @override
  void paint(Canvas c, Size s) {
    const left = 24.0, right = 34.0, top = 8.0, bottom = 34.0;
    final w = s.width - left - right, h = s.height - top - bottom;
    final n = d.length;
    if (n == 0) return;
    final grid = Paint()
      ..color = RC.line
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final yy = top + h * (1 - i / 3);
      c.drawLine(Offset(left, yy), Offset(left + w, yy), grid);
      _text(
        c,
        '${i * 7}',
        Offset(left - 6, yy),
        style: _axis.copyWith(color: RC.strain0),
        ax: 1,
        ay: .5,
      );
      final pctLabel = const ['0%', '33%', '66%', '100%'][i];
      final pc = i == 0 ? RC.red : (i == 1 ? RC.red : (i == 2 ? RC.yellow : RC.green));
      _text(
        c,
        pctLabel,
        Offset(left + w + 6, yy),
        style: _axis.copyWith(color: pc),
        ay: .5,
      );
    }
    final col = w / n;
    final pts = <Offset?>[];
    for (var i = 0; i < n; i++) {
      final cx = left + col * (i + .5);
      final st = d[i].strain;
      if (st != null) {
        final bh = h * (st / 21).clamp(0.0, 1.0);
        final r = RRect.fromRectAndCorners(
          Rect.fromLTWH(cx - 9, top + h - bh, 18, bh),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        );
        c.drawRRect(r, Paint()..color = RC.strain(st));
        _text(
          c,
          dec1(st),
          Offset(cx, top + h - bh - 3),
          style: _axis.copyWith(color: RC.ink2, fontSize: 10),
          ax: .5,
          ay: 1,
        );
      }
      final rc = d[i].recovery;
      pts.add(rc == null ? null : Offset(cx, top + h * (1 - rc / 100)));
      final dd = d[i].day;
      _text(
        c,
        '${_wd[dd.weekday - 1]} ${dd.day}',
        Offset(cx, top + h + 8),
        style: _axis.copyWith(color: i == n - 1 ? RC.ink : RC.ink3),
        ax: .5,
      );
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = RC.ink2;
    Offset? prev;
    for (final p in pts) {
      if (p != null && prev != null) c.drawLine(prev, p, line);
      if (p != null) prev = p;
    }
    for (var i = 0; i < n; i++) {
      final p = pts[i];
      if (p == null) continue;
      final v = d[i].recovery!;
      final z = v >= 67 ? RC.green : (v >= 34 ? RC.yellow : RC.red);
      c.drawCircle(p, 4, Paint()..color = RC.card);
      c.drawCircle(p, 3, Paint()..color = z);
    }
  }

  @override
  bool shouldRepaint(_WeekPainter o) => o.d != d;
}

// ───────────────────────── линия + коридор ─────────────────────────

/// Ряд по дням с полосой нормы [lo, hi] (p10–p90 и т. п.).
class CorridorChart extends StatelessWidget {
  final List<double?> values;
  final double? lo, hi;
  final Color color;
  final double height;
  final String Function(double) fmt;

  /// Выход за верх полосы — не тревога (ВСР выше обычной — хорошо).
  final bool highIsGood;
  const CorridorChart({
    this.highIsGood = false,
    super.key,
    required this.values,
    this.lo,
    this.hi,
    this.color = RC.brandA,
    this.height = 120,
    this.fmt = _round,
  });
  static String _round(double v) => v.round().toString();

  @override
  Widget build(BuildContext c) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: _CorridorPainter(this)),
  );
}

class _CorridorPainter extends CustomPainter {
  final CorridorChart w;
  _CorridorPainter(this.w);

  @override
  void paint(Canvas c, Size s) {
    final xs = w.values.whereType<double>().toList();
    if (xs.isEmpty) {
      _text(c, 'НЕТ ДАННЫХ', Offset(s.width / 2, s.height / 2), ax: .5, ay: .5);
      return;
    }
    var mn = xs.reduce(math.min), mx = xs.reduce(math.max);
    if (w.lo != null) mn = math.min(mn, w.lo!);
    if (w.hi != null) mx = math.max(mx, w.hi!);
    final pad = math.max((mx - mn) * .15, .5);
    mn -= pad;
    mx += pad;
    const left = 30.0, top = 6.0, bottom = 6.0;
    final ww = s.width - left, h = s.height - top - bottom;
    double y(double v) => top + h * (1 - (v - mn) / (mx - mn));
    double x(int i) => left + (w.values.length == 1 ? ww / 2 : ww * i / (w.values.length - 1));
    if (w.lo != null || w.hi != null) {
      // Полоса нормы; односторонняя норма — до края графика.
      c.drawRect(
        Rect.fromLTRB(left, y(w.hi ?? mx), s.width, y(w.lo ?? mn)),
        Paint()..color = RC.green.withValues(alpha: .10),
      );
      if (w.hi != null) {
        _text(c, w.fmt(w.hi!), Offset(left - 6, y(w.hi!)), ax: 1, ay: .5);
      }
      if (w.lo != null) {
        _text(c, w.fmt(w.lo!), Offset(left - 6, y(w.lo!)), ax: 1, ay: .5);
      }
    } else {
      _text(c, w.fmt(mx - pad), Offset(left - 6, y(mx - pad)), ax: 1, ay: .5);
      _text(c, w.fmt(mn + pad), Offset(left - 6, y(mn + pad)), ax: 1, ay: .5);
    }
    final p = Path();
    var started = false;
    for (var i = 0; i < w.values.length; i++) {
      final v = w.values[i];
      if (v == null) continue;
      final o = Offset(x(i), y(v));
      if (!started) {
        p.moveTo(o.dx, o.dy);
        started = true;
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    c.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = w.color,
    );
    for (var i = 0; i < w.values.length; i++) {
      final v = w.values[i];
      if (v == null) continue;
      final out = (!w.highIsGood && w.hi != null && v > w.hi!) ||
          (w.lo != null && v < w.lo!);
      if (i == w.values.length - 1 || out) {
        c.drawCircle(Offset(x(i), y(v)), 3, Paint()..color = out ? RC.yellow : w.color);
      }
    }
  }

  @override
  bool shouldRepaint(_CorridorPainter o) => true;
}

// ───────────────────────── кривая нагрузки дня ─────────────────────────

/// Нагрузка 0–21 по времени дня (ступенями, как копится).
class StrainCurveChart extends StatelessWidget {
  final List<({int t, double v})> curve;
  final int dayStart, end;
  const StrainCurveChart({
    super.key,
    required this.curve,
    required this.dayStart,
    required this.end,
  });
  @override
  Widget build(BuildContext c) => SizedBox(
    height: 140,
    width: double.infinity,
    child: CustomPaint(painter: _CurvePainter(this)),
  );
}

class _CurvePainter extends CustomPainter {
  final StrainCurveChart w;
  _CurvePainter(this.w);
  @override
  void paint(Canvas c, Size s) {
    const left = 22.0, bottom = 18.0, top = 6.0;
    final ww = s.width - left, h = s.height - top - bottom;
    final span = math.max(3600, w.end - w.dayStart).toDouble();
    double x(int t) => left + ww * ((t - w.dayStart) / span).clamp(0.0, 1.0);
    double y(double v) => top + h * (1 - (v / 21).clamp(0.0, 1.0));
    final grid = Paint()
      ..color = RC.line
      ..strokeWidth = 1;
    for (final v in [0, 7, 14, 21]) {
      c.drawLine(Offset(left, y(v.toDouble())), Offset(s.width, y(v.toDouble())), grid);
      _text(c, '$v', Offset(left - 6, y(v.toDouble())), style: _axis.copyWith(color: RC.strain0), ax: 1, ay: .5);
    }
    for (var k = 0; k * 6 * 3600 < span; k++) {
      final t = w.dayStart + k * 6 * 3600;
      _text(c, _hh(t), Offset(x(t), top + h + 4), ax: k == 0 ? 0 : .5);
    }
    if (w.curve.isEmpty) {
      _text(c, 'НЕТ ДАННЫХ', Offset(s.width / 2, top + h / 2), ax: .5, ay: .5);
      return;
    }
    final p = Path()..moveTo(x(w.curve.first.t), y(0));
    var lastY = y(0);
    for (final e in w.curve) {
      p.lineTo(x(e.t), lastY);
      lastY = y(e.v);
      p.lineTo(x(e.t), lastY);
    }
    p.lineTo(x(w.end), lastY);
    c.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = RC.strain1,
    );
    final f = Path.from(p)
      ..lineTo(x(w.end), y(0))
      ..close();
    c.drawPath(f, Paint()..color = RC.strain1.withValues(alpha: .14));
  }

  @override
  bool shouldRepaint(_CurvePainter o) => true;
}

/// Пять полос зон пульса (минуты).
class ZoneBars extends StatelessWidget {
  final List<int?> minutes; // z1..z5
  const ZoneBars({super.key, required this.minutes});
  static const colors = [
    Color(0xFF7FA7F5),
    RC.strain0,
    RC.green,
    RC.yellow,
    RC.red,
  ];
  @override
  Widget build(BuildContext c) {
    final mx = minutes.whereType<int>().fold<int>(1, math.max);
    return Column(
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  child: Text('Зона ${i + 1}', style: RT.small),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (c, b) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 10,
                        width: math.max(
                          4,
                          b.maxWidth * ((minutes[i] ?? 0) / mx),
                        ),
                        decoration: BoxDecoration(
                          color: colors[i],
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    minutes[i] == null ? '—' : _hm(minutes[i]!),
                    textAlign: TextAlign.right,
                    style: RT.label.copyWith(color: RC.ink),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _hm(int m) => '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
}

/// Полоса стадий сна 100 % ширины, высота 24.
class StageBar extends StatelessWidget {
  final int awake, light, deep, rem;
  const StageBar({
    super.key,
    required this.awake,
    required this.light,
    required this.deep,
    required this.rem,
  });
  static const awakeC = RC.ink3;
  static final lightC = RC.sleepBlue.withValues(alpha: .5);
  static const deepC = RC.sleepBlue;
  static const remC = RC.brandA;

  @override
  Widget build(BuildContext c) => SizedBox(
    height: 24,
    width: double.infinity,
    child: CustomPaint(painter: _StagePainter([
      (awake, awakeC),
      (light, lightC),
      (deep, deepC),
      (rem, remC),
    ])),
  );
}

class _StagePainter extends CustomPainter {
  final List<(int, Color)> parts;
  _StagePainter(this.parts);
  @override
  void paint(Canvas c, Size s) {
    final total = parts.fold<int>(0, (a, b) => a + b.$1);
    if (total <= 0) return;
    c.clipRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(6)));
    var x = 0.0;
    for (final (m, col) in parts) {
      if (m <= 0) continue;
      final w = s.width * m / total;
      c.drawRect(Rect.fromLTWH(x, 0, w + .5, s.height), Paint()..color = col);
      x += w;
    }
  }

  @override
  bool shouldRepaint(_StagePainter o) => true;
}

// ── B4½: таймлайн источников пульса 24 ч и мини-шкала Нагрузки 0–21 ─────────

/// Полоса 24 ч высотой 6: серый — браслет, синий — Watch, серо-голубой —
/// Garmin, пусто — не носился; после [now] — только дорожка.
class RitmHrTimeline extends StatelessWidget {
  final List<HrSegment> segments;
  final int from, to, now;
  final double height;
  const RitmHrTimeline({
    super.key,
    required this.segments,
    required this.from,
    required this.to,
    required this.now,
    this.height = 6,
  });

  @override
  Widget build(BuildContext c) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: _TimelinePainter(segments, from, to, now)),
  );
}

Color hrSrcColor(HrSrc s) => switch (s) {
  HrSrc.band => RC.ink3,
  HrSrc.watch => RC.strain0,
  HrSrc.garmin => const Color(0xFF7FA6C9),
};

class _TimelinePainter extends CustomPainter {
  final List<HrSegment> segs;
  final int from, to, now;
  _TimelinePainter(this.segs, this.from, this.to, this.now);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final span = math.max(1, to - from);
    double x(int t) => ((t - from) / span).clamp(0.0, 1.0) * size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = RC.ringTrack,
    );
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, r));
    // Прошедшая часть дня без данных — чуть темнее дорожки («не носился»).
    canvas.drawRect(
      Rect.fromLTRB(0, 0, x(now), size.height),
      Paint()..color = RC.bg,
    );
    for (final g in segs) {
      final s = g.src;
      if (s == null) continue;
      final a = x(g.from), b = x(math.min(g.to, now));
      if (b <= a) continue;
      canvas.drawRect(
        Rect.fromLTRB(a, 0, math.max(b, a + 1), size.height),
        Paint()..color = hrSrcColor(s),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TimelinePainter o) =>
      o.segs != segs || o.now != now || o.from != from || o.to != to;
}

/// Шкала 0–21 высотой 6 с коридором [lo; hi] и маркером [value].
class RitmStrainScale extends StatelessWidget {
  final double value, lo, hi;
  const RitmStrainScale({super.key, required this.value, required this.lo, required this.hi});

  @override
  Widget build(BuildContext c) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 14,
        child: CustomPaint(painter: _StrainScalePainter(value, lo, hi)),
      ),
      const SizedBox(height: 4),
      const Row(
        children: [
          Text('0', style: RT.micro),
          Spacer(),
          Text('7', style: RT.micro),
          Spacer(),
          Text('14', style: RT.micro),
          Spacer(),
          Text('21', style: RT.micro),
        ],
      ),
    ],
  );
}

class _StrainScalePainter extends CustomPainter {
  final double v, lo, hi;
  _StrainScalePainter(this.v, this.lo, this.hi);

  @override
  void paint(Canvas canvas, Size size) {
    const h = 6.0;
    final y0 = (size.height - h) / 2;
    double x(double s) => (s / 21).clamp(0.0, 1.0) * size.width;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, y0, size.width, h), const Radius.circular(3));
    canvas.drawRRect(track, Paint()..color = RC.ringTrack);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(0, y0, x(v), y0 + h), const Radius.circular(3)),
      Paint()..color = RC.strain(v),
    );
    // Коридор — рамка поверх дорожки.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(x(lo), y0 - 2, x(hi), y0 + h + 2), const Radius.circular(4)),
      Paint()
        ..color = RC.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.drawCircle(Offset(x(v), size.height / 2), 6, Paint()..color = RC.ink);
    canvas.drawCircle(Offset(x(v), size.height / 2), 3.5, Paint()..color = RC.strain(v));
  }

  @override
  bool shouldRepaint(_StrainScalePainter o) => o.v != v || o.lo != lo || o.hi != hi;
}
