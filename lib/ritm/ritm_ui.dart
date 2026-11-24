// «Ритм» — дизайн-система (ТЗ v2 §1): токены RC (цвета), RT (шрифт),
// RS (сетка) и компоненты RGauge, RCard, RTile, RButton, RSection, RSheet,
// RAvatar, RDot, RPage.
//
// Размеры — в pt для ширины 393 (iPhone 15/16 Pro), масштаб WHOOP ±5 %
// (замер по скринам владельца 15.10: кольцо WHOOP Ø≈79/4, плитка ≈79).
// Тёмная тема — единственная. Шрифт Inter (OFL, assets/fonts/Inter),
// запасной — системный SF Pro. Иконки Lucide; чужих логотипов нет.

import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'ritm_scores.dart';

/// Цвета (§1.1).
class RC {
  static const bg = Color(0xFF0E1114);
  static const bgTop = Color(0xFF15191E);
  static const card = Color(0xFF1C2026);
  static const cardHi = Color(0xFF262B32);
  static const line = Color(0x14FFFFFF);
  static const ink = Color(0xFFF2F4F6);
  static const ink2 = Color(0xFFA7ADB5);

  /// #8E959F вместо #6B7280 из таблицы ТЗ: тот даёт 3,4:1 на `card`,
  /// а критерий §1.1 — не ниже 4,5:1 (здесь 5,4:1 на card, 4,7:1 на cardHi).
  static const ink3 = Color(0xFF8E959F);

  static const green = Color(0xFF35D07F);
  static const yellow = Color(0xFFF5C542);
  static const red = Color(0xFFFF5A5A);
  static const strain0 = Color(0xFF5B8DEF);
  static const strain1 = Color(0xFF3B7BFF);
  static const strain2 = Color(0xFF2A66F0);
  static const strain3 = Color(0xFF1E4FD6);
  static const sleepBlue = Color(0xFF6C8CFF);
  static const brandA = Color(0xFF2FD7B5);
  static const brandB = Color(0xFF7CF29C);
  static const ringTrack = Color(0xFF2A2F36);

  // Совместимость со старыми именами слоя «Ритм».
  static const bgBottom = bg;
  static const track = ringTrack;
  static const accent = brandA;

  static Color zone(RitmZone? z) => switch (z) {
    RitmZone.green => green,
    RitmZone.yellow => yellow,
    RitmZone.red => red,
    null => ink3,
  };

  /// Нагрузка по уровням 0–9 / 10–13 / 14–17 / 18–21.
  static Color strain(num v) => switch (strainLevel(v)) {
    0 => strain0,
    1 => strain1,
    2 => strain2,
    _ => strain3,
  };

  /// Фон экрана: сверху градиент `bgTop` → `bg` высотой ≈240 pt.
  static const background = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [bgTop, bg, bg],
      stops: [0, .28, 1],
    ),
  );
}

/// Шрифт (§1.2). Числа — табличные.
class RT {
  static const family = 'Inter';
  static const fallback = ['.SF Pro Text', 'Manrope'];
  static const _tab = [FontFeature.tabularFigures()];

  static const display = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 44,
    height: 1.05,
    fontWeight: FontWeight.w600,
    letterSpacing: -1,
    color: RC.ink,
    fontFeatures: _tab,
  );
  static const h1 = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 28,
    height: 34 / 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -.5,
    color: RC.ink,
  );
  static const h2 = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -.3,
    color: RC.ink,
  );
  static const num = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 24,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: -.4,
    color: RC.ink,
    fontFeatures: _tab,
  );
  static const title = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 17,
    height: 22 / 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -.2,
    color: RC.ink,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: RC.ink2,
  );
  static const label = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 13,
    height: 16 / 13,
    fontWeight: FontWeight.w500,
    color: RC.ink,
  );
  static const cap = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 12,
    height: 15 / 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
    color: RC.ink,
  );
  static const small = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
    color: RC.ink3,
  );
  static const micro = TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w500,
    color: RC.ink3,
  );
}

/// Сетка и отступы (§1.3).
class RS {
  static const x1 = 4.0, x2 = 8.0, x3 = 12.0, x4 = 16.0, x5 = 20.0, x6 = 24.0;
  static const screen = 16.0;
  static const cardGap = 12.0;
  static const sectionGap = 24.0;
  static const cardPad = 16.0;
  static const tileHead = 10.0;
  static const rCard = 16.0;
  static const rTile = 12.0;
  static const rSheet = 24.0;

  /// Нижний отступ прокрутки на вкладках: пилюля 64 + 16 + запас.
  static const tabBarClearance = 104.0;
}

// ─────────────────────────── кольцо ───────────────────────────

/// Состояние кольца (§1.4).
enum GaugeKind { measured, calibrating, computing, none, provisional }

class GaugeState {
  final GaugeKind kind;

  /// 0…1 — заполнение дуги (для калибровки = have/need).
  final double? frac;
  final Color color;

  /// Число в центре («72%», «14,2», «5/14», «…», «–»).
  final String value;

  /// Одна строка под числом («7:12 из 8:05», «Готов», «калибровка»).
  final String? inner;

  final int? have, need;

  /// Целевой коридор нагрузки (доли 0…1).
  final double? targetLo, targetHi;

  const GaugeState({
    this.kind = GaugeKind.measured,
    this.frac,
    this.color = RC.ink3,
    required this.value,
    this.inner,
    this.have,
    this.need,
    this.targetLo,
    this.targetHi,
  });

  const GaugeState.none({String inner = 'нет данных'})
    : this(kind: GaugeKind.none, value: '–', inner: inner);

  const GaugeState.computing()
    : this(kind: GaugeKind.computing, value: '…', inner: 'считаю');

  GaugeState.calibrating(int have, int need)
    : this(
        kind: GaugeKind.calibrating,
        value: '$have/$need',
        inner: 'калибровка',
        have: have,
        need: need,
        frac: need <= 0 ? 0 : (have / need).clamp(0.0, 1.0).toDouble(),
      );

  bool get calibrating => kind == GaugeKind.calibrating;
  bool get provisional => kind == GaugeKind.provisional;
}

/// Кольцо-спидометр Ø84 / 5 pt, открытое снизу на 60°, подпись капсом + ›.
class RitmGauge extends StatefulWidget {
  final GaugeState s;
  final String label;
  final VoidCallback? onTap;
  final double size;
  final double stroke;

  const RitmGauge({
    super.key,
    required this.s,
    required this.label,
    this.onTap,
    this.size = 78,
    this.stroke = 4.5,
  });

  @override
  State<RitmGauge> createState() => _RitmGaugeState();
}

class _RitmGaugeState extends State<RitmGauge>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _phase = 0;

  bool _wantsTicker(BuildContext c) =>
      widget.s.kind == GaugeKind.computing &&
      !(MediaQuery.maybeDisableAnimationsOf(c) ?? false) &&
      TickerMode.valuesOf(c).enabled;

  void _syncTicker() {
    final want = _wantsTicker(context);
    if (want && _ticker == null) {
      _ticker = createTicker((e) {
        setState(() => _phase = (e.inMicroseconds / 1600000.0) % 1.0);
      })..start();
    } else if (!want && _ticker != null) {
      _ticker!.dispose();
      _ticker = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(RitmGauge old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final s = widget.s;
    final grey = s.kind != GaugeKind.measured;
    return Semantics(
      button: widget.onTap != null,
      label:
          '${widget.label}: ${s.value}${s.inner == null ? '' : ', ${s.inner}'}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: widget.size,
              height: widget.size,
              child: CustomPaint(
                painter: _GaugePainter(s, widget.stroke, _phase),
                child: Padding(
                  // Внутренняя подпись не касается дуги: хорда ниже центра уже.
                  padding: EdgeInsets.symmetric(horizontal: widget.stroke + 11),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          s.value,
                          maxLines: 1,
                          style: RT.num.copyWith(
                            color: grey ? RC.ink3 : RC.ink,
                            fontSize: widget.size >= 120
                                ? 44
                                : (s.value.length > 5 ? 17 : 22),
                            // Как у WHOOP: цифра в малом кольце полужирная, не чёрная.
                            fontWeight: widget.size >= 120
                                ? null
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (s.inner != null) ...[
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            s.inner!,
                            maxLines: 1,
                            style: RT.small.copyWith(
                              color: RC.ink2,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 16,
              child: OverflowBox(
                maxWidth: widget.size + 48,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label.toUpperCase(),
                        maxLines: 1,
                        style: RT.cap,
                      ),
                      if (widget.onTap != null) ...[
                        const SizedBox(width: 3),
                        Text('›', style: RT.cap.copyWith(color: RC.ink3)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final GaugeState s;
  final double stroke;
  final double phase;
  _GaugePainter(this.s, this.stroke, this.phase);

  static const start = 120 * math.pi / 180;
  static const sweep = 300 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - stroke / 2 - 3;
    final o = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: o, radius: r);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = RC.ringTrack;
    canvas.drawArc(rect, start, sweep, false, track);

    switch (s.kind) {
      case GaugeKind.none:
        return;
      case GaugeKind.computing:
        final run = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = RC.ink3;
        const seg = 60 * math.pi / 180;
        final a = start + (sweep - seg) * phase;
        canvas.drawArc(rect, a, seg, false, run);
        return;
      case GaugeKind.calibrating:
        // Пунктир 4/4 pt цвета ink3 на заполненной доле have/need.
        final f = (s.frac ?? 0).clamp(0.0, 1.0);
        if (f <= 0) return;
        final dash = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke - 1
          ..strokeCap = StrokeCap.butt
          ..color = RC.ink3;
        final dashA = 4 / r, gapA = 4 / r;
        final end = start + sweep * f;
        for (var a = start; a < end; a += dashA + gapA) {
          canvas.drawArc(rect, a, math.min(dashA, end - a), false, dash);
        }
        return;
      case GaugeKind.measured:
      case GaugeKind.provisional:
        final lo = s.targetLo, hi = s.targetHi;
        if (lo != null && hi != null && hi > lo) {
          final band = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round
            // Коридор цели — тем же цветом, что дуга, но прозрачнее.
            ..color = s.color.withValues(alpha: .5);
          canvas.drawArc(
            Rect.fromCircle(center: o, radius: r + stroke / 2 + 2.5),
            start + sweep * lo,
            sweep * (hi - lo),
            false,
            band,
          );
        }
        final f = s.frac;
        if (f == null || f <= 0) return;
        final arc = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = s.provisional ? RC.ink3 : s.color;
        canvas.drawArc(rect, start, sweep * f.clamp(0.0, 1.0), false, arc);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.s.frac != s.frac ||
      old.s.kind != s.kind ||
      old.s.color != s.color ||
      old.s.have != s.have ||
      old.s.targetLo != s.targetLo ||
      old.phase != phase ||
      old.stroke != stroke;
}

// ─────────────────────────── карточки ───────────────────────────

/// Карточка: `card`, радиус 16, padding 16.
class RCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry pad;
  final VoidCallback? onTap;
  final Color color;
  final Gradient? gradient;
  const RCard({
    super.key,
    required this.child,
    this.pad = const EdgeInsets.all(RS.cardPad),
    this.onTap,
    this.color = RC.card,
    this.gradient,
  });

  @override
  Widget build(BuildContext c) {
    final box = Container(
      width: double.infinity,
      padding: pad,
      decoration: BoxDecoration(
        color: gradient == null ? color : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(RS.rCard),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: box,
    );
  }
}

/// Заголовок карточки капсом (`cap`) + шеврон/иконка справа.
class RCardHead extends StatelessWidget {
  final String text;
  final IconData? trailing;
  final Widget? trailingWidget;
  const RCardHead(
    this.text, {
    super.key,
    this.trailing = LucideIcons.chevronRight,
    this.trailingWidget,
  });

  @override
  Widget build(BuildContext c) => Row(
    children: [
      Expanded(
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RT.cap,
        ),
      ),
      if (trailingWidget != null)
        trailingWidget!
      else if (trailing != null)
        Icon(trailing, size: 16, color: RC.ink3),
    ],
  );
}

/// Плитка монитора (§1.5): высота 80; заголовок `cap` + ›; через 10 —
/// иконка 16 + одна строка `body`.
class RTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final String text;
  final Color iconColor;
  final VoidCallback? onTap;
  const RTile({
    super.key,
    required this.title,
    required this.icon,
    required this.text,
    this.iconColor = RC.ink2,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) => Semantics(
    button: onTap != null,
    label: '$title: $text',
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 80,
        padding: const EdgeInsets.fromLTRB(14, 16, 12, 14),
        decoration: BoxDecoration(
          color: RC.card,
          borderRadius: BorderRadius.circular(RS.rCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      style: RT.cap,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(LucideIcons.chevronRight, size: 16, color: RC.ink3),
              ],
            ),
            const SizedBox(height: RS.tileHead),
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: RC.cardHi,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(icon, size: 14, color: iconColor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  // Длинная строка («Пульс покоя 55 ↑») чуть уменьшается,
                  // а не обрезается многоточием.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      text,
                      maxLines: 1,
                      style: RT.body.copyWith(fontSize: 14, height: 1.2),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

enum RButtonKind { primary, secondary, ghost }

/// Кнопка: высота 48, радиус 12, текст 13/600 капсом.
class RButton extends StatelessWidget {
  final IconData? icon;
  final String text;
  final VoidCallback? onTap;
  final RButtonKind kind;
  final double height;
  const RButton(
    this.icon,
    this.text, {
    super.key,
    this.onTap,
    this.kind = RButtonKind.secondary,
    this.height = 48,
  });

  @override
  Widget build(BuildContext c) {
    final (Color bg, Color fg, BorderSide side) = switch (kind) {
      RButtonKind.primary => (RC.ink, RC.bg, BorderSide.none),
      RButtonKind.secondary => (RC.cardHi, RC.ink, BorderSide.none),
      RButtonKind.ghost => (
        const Color(0x00000000),
        RC.ink,
        const BorderSide(color: Color(0x29FFFFFF)),
      ),
    };
    final r = BorderRadius.circular(RS.rTile);
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(borderRadius: r, side: side),
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: fg),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        text.toUpperCase(),
                        maxLines: 1,
                        style: RT.cap.copyWith(
                          fontSize: 13,
                          letterSpacing: 1,
                          color: fg,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Заголовок секции `h2` 22 + действие справа (кнопка 44×44, фон ink, «+»).
class RSection extends StatelessWidget {
  final String title;
  final VoidCallback? onAdd;
  final String addLabel;
  final Widget? trailing;
  const RSection(
    this.title, {
    super.key,
    this.onAdd,
    this.addLabel = 'Добавить',
    this.trailing,
  });

  @override
  Widget build(BuildContext c) => SizedBox(
    height: 44,
    child: Row(
      children: [
        Expanded(child: Text(title, style: RT.h2)),
        ?trailing,
        if (onAdd != null)
          Semantics(
            button: true,
            label: addLabel,
            excludeSemantics: true,
            child: Material(
              color: RC.ink,
              borderRadius: BorderRadius.circular(RS.rTile),
              child: InkWell(
                borderRadius: BorderRadius.circular(RS.rTile),
                onTap: onAdd,
                child: const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(LucideIcons.plus, color: RC.bg, size: 22),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Нижний лист: радиус 24, ручка 36×4.
Future<T?> showRSheet<T>(BuildContext c, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: c,
      backgroundColor: RC.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(RS.rSheet)),
      ),
      builder: (sc) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: RC.ink3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              builder(sc),
            ],
          ),
        ),
      ),
    );

/// Аватар: фото (`BoxFit.cover`) или инициал на `cardHi`.
class RAvatar extends StatelessWidget {
  final double size;
  final String? path;
  final String name;
  const RAvatar({super.key, this.size = 32, this.path, this.name = ''});

  @override
  Widget build(BuildContext c) {
    final p = path;
    final initial = name.trim().isEmpty
        ? null
        : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(shape: BoxShape.circle, color: RC.cardHi),
      alignment: Alignment.center,
      child: p != null
          ? Image.file(
              File(p),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _fallback(initial),
            )
          : _fallback(initial),
    );
  }

  Widget _fallback(String? initial) => initial == null
      ? Icon(LucideIcons.user, size: size * .5, color: RC.ink2)
      : Text(initial, style: RT.title.copyWith(fontSize: size * .45));
}

/// Точка статуса Ø8.
class RDot extends StatelessWidget {
  final Color color;
  final double size;
  const RDot(this.color, {super.key, this.size = 8});
  @override
  Widget build(BuildContext c) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Пунктир 1 pt `ink3` по ширине.
class RDashes extends StatelessWidget {
  const RDashes({super.key});
  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, box) {
      final n = (box.maxWidth / 7).floor().clamp(1, 60);
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < n; i++)
            Container(width: 3, height: 1, color: RC.ink3),
        ],
      );
    },
  );
}

/// Строка списка (настройки, «Ещё»): высота ≥56, иконка 20, `title` 15,
/// подпись `small`, справа значение/переключатель/шеврон.
class RRow extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final Color iconColor;
  const RRow({
    super.key,
    this.icon,
    required this.title,
    this.sub,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.iconColor = RC.ink2,
  });

  @override
  Widget build(BuildContext c) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: RT.title.copyWith(fontSize: 15)),
                  if (sub != null && sub!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub!, style: RT.small),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (chevron && onTap != null && trailing == null)
              const Icon(LucideIcons.chevronRight, size: 18, color: RC.ink3),
          ],
        ),
      ),
    ),
  );
}

/// Группа строк в одной карточке с разделителями.
class RGroup extends StatelessWidget {
  final String? title;
  final List<Widget> rows;
  const RGroup({super.key, this.title, required this.rows});

  @override
  Widget build(BuildContext c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (title != null)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title!.toUpperCase(),
            style: RT.cap.copyWith(color: RC.ink2),
          ),
        ),
      ClipRRect(
        borderRadius: BorderRadius.circular(RS.rCard),
        child: ColoredBox(
          color: RC.card,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 50,
                    color: RC.line,
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

/// Переключатель в цветах «Ритма».
class RSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const RSwitch({super.key, required this.value, this.onChanged});
  @override
  Widget build(BuildContext c) => Switch.adaptive(
    value: value,
    onChanged: onChanged,
    activeTrackColor: RC.green,
    inactiveTrackColor: RC.cardHi,
  );
}

/// Страница «Ритма»: тёмный фон, шапка 44 (‹ назад + заголовок `h2`),
/// прокручиваемое содержимое с полями 16.
class RPage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? action;

  /// Внешний контроллер прокрутки (демо-скриншоты нижней части экрана).
  final ScrollController? controller;

  /// Крупный заголовок `h1` 28 (экраны показателей, §3).
  final bool large;

  /// Своё тело вместо прокручиваемого списка [children] (чат: список + поле ввода).
  final Widget? body;
  const RPage({
    super.key,
    required this.title,
    this.children = const [],
    this.action,
    this.controller,
    this.large = false,
    this.body,
  });

  @override
  Widget build(BuildContext c) {
    final canPop = Navigator.of(c).canPop();
    return Scaffold(
      backgroundColor: RC.bg,
      body: DecoratedBox(
        decoration: RC.background,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    if (canPop)
                      Semantics(
                        button: true,
                        label: 'Назад',
                        excludeSemantics: true,
                        child: InkResponse(
                          onTap: () => Navigator.of(c).maybePop(),
                          radius: 22,
                          child: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(
                              LucideIcons.chevronLeft,
                              size: 26,
                              color: RC.ink,
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: large ? RT.h1 : RT.h2,
                      ),
                    ),
                    ?action,
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              Expanded(
                child:
                    body ??
                    ListView(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                      children: children,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Стеклянная подложка (размытие 20) — для таб-бара.
class RGlass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final Color color;
  const RGlass({
    super.key,
    required this.child,
    required this.radius,
    this.color = const Color(0xE61A1D22),
  });
  @override
  Widget build(BuildContext c) => ClipRRect(
    borderRadius: radius,
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: radius,
          border: Border.all(color: RC.line),
        ),
        child: child,
      ),
    ),
  );
}

/// Знак «Ритм» (бренд, §15, brand/README «Три такта»): три скруглённых
/// столбика разной высоты, градиент #8CF7A6 → #22CDB0.
class RitmMark extends StatelessWidget {
  final double size;
  const RitmMark({super.key, this.size = 24});
  @override
  Widget build(BuildContext c) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    // Геометрия из brand/ritm_icon_1024.svg, нормированная к 1024.
    const bars = [
      (215.0, 356.9, 310.2),
      (437.0, 182.0, 660.0),
      (659.0, 277.7, 468.6),
    ];
    final k = s.width / 1024 * 1.18;
    final dx = (s.width - 1024 * k) / 2, dy = (s.height - 1024 * k) / 2;
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF8CF7A6), Color(0xFF22CDB0)],
      ).createShader(Offset.zero & s);
    for (final (x, y, h) in bars) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(dx + x * k, dy + y * k, 150 * k, h * k),
          Radius.circular(75 * k),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}
