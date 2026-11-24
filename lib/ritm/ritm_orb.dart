// «Ритм» — 3D-шар биовозраста (ТЗ v3 §12, «как планета»; замена v2 §11 сл. 1).
//
// Слой 1 — фрагментный шейдер shaders/ritm_orb.frag v2 (сфера с освещением,
// 3D-шум по нормали, вращение uRotation = 0,6 + 2π/27·t, облака с
// параллаксом, атмосфера), при ошибке загрузки — RadialGradient со светом.
// Слой 2 — 70 частиц на орбите (наклон 20°): за шаром — альфа 0,35, перед —
// полная. Слой 3 — текст поверх (child).
// Один Ticker на виджет, фаза из `elapsed` (без AnimationController.repeat),
// RepaintBoundary вокруг шара. Анимация стоит, когда шар не виден (вне экрана
// прокрутки, вкладка неактивна — TickerMode) и при «Уменьшении движения»
// (MediaQuery.disableAnimations или iOS reduceMotion) — тогда статичный кадр uTime = 0.
//
// Замер кадров (DEBUG + --dart-define=RITM_FPS=true): FrameTiming за 10 с
// анимации → Documents/ritm_fps.json и строка «[ritm-fps] …» в журнал.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'ritm_ui.dart';

const bool _kFps = bool.fromEnvironment('RITM_FPS');

/// В `flutter test` шар статичен — иначе pumpAndSettle ждёт бесконечно.
/// В `flutter test` облачко статично (золотые снимки); тест тикера
/// выключает это флагом.
bool ritmOrbStillInTests = Platform.environment.containsKey('FLUTTER_TEST');

/// «Уменьшение движения» iOS (AccessibilityFeatures.reduceMotion).
/// Подменяется в тестах.
bool Function() ritmReduceMotion = () => WidgetsBinding
    .instance.platformDispatcher.accessibilityFeatures.reduceMotion;

class RitmOrb extends StatefulWidget {
  /// Цвет зоны (`green` / `brandA` / `yellow`; серый — калибровка).
  final Color color;

  /// Диаметр шара; квадрат шейдера — с запасом 1,2 (200 → 240).
  final double size;
  final Widget? child;

  /// Принудительно статично (тесты, скриншоты).
  final bool still;
  const RitmOrb({
    super.key,
    required this.color,
    this.size = 200,
    this.child,
    this.still = false,
  });

  /// Программа шейдера (одна на приложение). Null — не загрузилась.
  static Future<ui.FragmentProgram?>? _program;
  static Future<ui.FragmentProgram?> program() =>
      _program ??= ui.FragmentProgram.fromAsset('shaders/ritm_orb.frag')
          .then<ui.FragmentProgram?>((p) => p)
          .catchError((Object e) {
            debugPrint('[ritm-orb] шейдер не загрузился: $e');
            return null;
          });

  @override
  State<RitmOrb> createState() => _RitmOrbState();
}

class _RitmOrbState extends State<RitmOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _time = ValueNotifier<double>(0);
  ui.FragmentProgram? _prog;
  bool _progTried = false;
  ScrollPosition? _pos;
  bool _visible = true;
  bool _reduce = false;

  @override
  void initState() {
    super.initState();
    RitmOrb.program().then((p) {
      if (!mounted) return;
      setState(() {
        _prog = p;
        _progTried = true;
      });
    });
  }

  void _tick(Duration elapsed) {
    _time.value = _base + elapsed.inMicroseconds / 1e6;
    if (_kFps) {
      // Замер — с первого настоящего кадра шара (вкладка видна).
      _FpsProbe.instance.start();
      _FpsProbe.instance.onFrame();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // iOS «Уменьшение движения» приходит флагом reduceMotion (не
    // disableAnimations — тот у iOS не ставится), проверяем оба.
    _reduce = (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
        ritmReduceMotion();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _pos) {
      _pos?.removeListener(_onScroll);
      _pos = pos;
      _pos?.addListener(_onScroll);
    }
    _sync();
  }

  @override
  void didUpdateWidget(RitmOrb old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _onScroll() {
    final v = _onScreen();
    if (v != _visible) {
      _visible = v;
      _sync();
    }
  }

  bool _onScreen() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return true;
    final top = ro.localToGlobal(Offset.zero).dy;
    final h = MediaQuery.sizeOf(context).height;
    return top + ro.size.height > 0 && top < h;
  }

  /// Время, накопленное до последней остановки (чтобы после паузы фаза
  /// продолжалась, а не прыгала в 0).
  double _base = 0;

  void _sync() {
    final run = !_reduce && !widget.still && _visible && !ritmOrbStillInTests;
    if (run) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) {
        _base = _time.value;
        _ticker.stop();
      }
      // Уменьшение движения / статичный режим — кадр uTime = 0.
      if (_reduce || widget.still) {
        _base = 0;
        _time.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _pos?.removeListener(_onScroll);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final box = widget.size * 1.35;
    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              size: Size.square(box),
              painter: _OrbPainter(
                time: _time,
                program: _prog,
                fallback: _progTried && _prog == null,
                color: widget.color,
                radius: widget.size / 2,
              ),
            ),
          ),
          ?widget.child,
        ],
      ),
    );
  }
}

class _Particle {
  final double r0, a0, speed, size, alpha, phase;
  final bool spark;
  const _Particle(
    this.r0,
    this.a0,
    this.speed,
    this.size,
    this.alpha,
    this.phase,
    this.spark,
  );
}

/// Частицы на «орбите» вокруг шара (ТЗ v3 §12 п. 3): кольцо радиусом
/// 1,06…1,30 радиуса шара, наклон 20°; половина за шаром (альфа 0,35).
final List<_Particle> _particles = () {
  final rnd = math.Random(7);
  return [
    for (var i = 0; i < 70; i++)
      _Particle(
        1.06 + .24 * rnd.nextDouble(),
        rnd.nextDouble() * math.pi * 2,
        .6 + rnd.nextDouble() * .8,
        i < 10 ? 2.6 : 1 + rnd.nextDouble() * 1.4,
        .5 + rnd.nextDouble() * .5,
        rnd.nextDouble() * math.pi * 2,
        i < 10,
      ),
  ];
}();

/// Один оборот текстуры ≈ 27 с (ω = 2π/27); статичный кадр — 0,6 рад.
const double kOrbOmega = 2 * math.pi / 27;
const double kOrbStillRotation = 0.6;

class _OrbPainter extends CustomPainter {
  final ValueNotifier<double> time;
  final ui.FragmentProgram? program;
  final bool fallback;
  final Color color;
  final double radius;
  _OrbPainter({
    required this.time,
    required this.program,
    required this.fallback,
    required this.color,
    required this.radius,
  }) : super(repaint: time);

  static final _blur = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
  static final _dot = Paint();
  static const _tilt = 20 * math.pi / 180;

  void _orbit(Canvas canvas, Offset c, double t, double rr, {required bool behind}) {
    for (final q in _particles) {
      final a = q.a0 + kOrbOmega * 1.6 * t * q.speed ;
      final rad = rr * (q.r0 + .02 * math.sin(t * .5 + q.phase));
      final x = math.cos(a) * rad;
      final z0 = math.sin(a) * rad;
      final y = -z0 * math.sin(_tilt);
      final z = z0 * math.cos(_tilt);
      if ((z < 0) != behind) continue;
      // За шаром — только то, что не закрыто диском.
      if (behind && x * x + y * y < rr * rr) continue;
      final o = c + Offset(x, y);
      final tw = .5 + .5 * math.sin(t * (1.3 + q.speed) + q.phase);
      final al = (q.alpha * (.45 + .55 * tw) * (behind ? .35 : 1)).clamp(0.0, 1.0);
      if (q.spark) {
        _blur.color = Color.lerp(color, RC.ink, .35)!.withValues(alpha: al);
        canvas.drawCircle(o, q.size, _blur);
      } else {
        _dot.color = color.withValues(alpha: al);
        canvas.drawCircle(o, q.size, _dot);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size s) {
    final t = time.value;
    final c = s.center(Offset.zero);
    final rel = radius / (s.shortestSide / 2);
    final rot = t == 0 ? kOrbStillRotation : kOrbStillRotation + kOrbOmega * t;
    final rr = radius * (1 + .02 * math.sin(t * 2 * math.pi / 7));
    _orbit(canvas, c, t, rr, behind: true);
    final p = program;
    if (p != null) {
      final sh = p.fragmentShader()
        ..setFloat(0, s.width)
        ..setFloat(1, s.height)
        ..setFloat(2, t)
        ..setFloat(3, color.r)
        ..setFloat(4, color.g)
        ..setFloat(5, color.b)
        ..setFloat(6, 1)
        ..setFloat(7, RC.brandB.r)
        ..setFloat(8, RC.brandB.g)
        ..setFloat(9, RC.brandB.b)
        ..setFloat(10, 1)
        ..setFloat(11, rel)
        ..setFloat(12, 1)
        ..setFloat(13, rot);
      canvas.drawRect(Offset.zero & s, Paint()..shader = sh);
    } else if (fallback) {
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.35, -.4),
            colors: [
              Color.lerp(color, RC.ink, .25)!,
              color.withValues(alpha: .55),
              RC.bg,
            ],
            stops: const [.0, .55, 1],
          ).createShader(Rect.fromCircle(center: c, radius: rr)),
      );
    }
    _orbit(canvas, c, t, rr, behind: false);
  }

  @override
  bool shouldRepaint(_OrbPainter o) =>
      o.program != program ||
      o.color != color ||
      o.fallback != fallback ||
      o.radius != radius;
}

/// Замер кадров для B4_works.md (только DEBUG + RITM_FPS).
class _FpsProbe {
  static final instance = _FpsProbe();
  final _timings = <FrameTiming>[];
  int _ticks = 0;
  DateTime? _t0;
  bool _on = false;

  void start() {
    if (_on || !kDebugMode) return;
    _on = true;
    // Первые 2 с — прогрев (компиляция шейдера, первые кадры), потом 10 с.
    Future.delayed(const Duration(seconds: 2), () {
      _t0 = DateTime.now();
      _ticks = 0;
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      Future.delayed(const Duration(seconds: 10), _done);
    });
  }

  void onFrame() {
    if (_t0 != null) _ticks++;
  }

  void _onTimings(List<FrameTiming> t) => _timings.addAll(t);

  Future<void> _done() async {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    final secs = DateTime.now().difference(_t0!).inMilliseconds / 1000;
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = [for (final t in _timings) ms(t.buildDuration)]..sort();
    final raster = [for (final t in _timings) ms(t.rasterDuration)]..sort();
    final total = [for (final t in _timings) ms(t.totalSpan)]..sort();
    double pct(List<double> x, double p) =>
        x.isEmpty ? 0 : x[((x.length - 1) * p).round()];
    double avg(List<double> x) =>
        x.isEmpty ? 0 : x.reduce((a, b) => a + b) / x.length;
    // «Рывок» — кадр, у которого сборка или отрисовка дольше бюджета 16,7 мс.
    final janky = _timings
        .where(
          (t) => ms(t.buildDuration) > 16.7 || ms(t.rasterDuration) > 16.7,
        )
        .length;
    final out = {
      'seconds': double.parse(secs.toStringAsFixed(2)),
      'ticker_frames': _ticks,
      'fps': double.parse((_ticks / secs).toStringAsFixed(1)),
      'frames_timed': _timings.length,
      'build_ms_avg': double.parse(avg(build).toStringAsFixed(2)),
      'build_ms_p90': double.parse(pct(build, .9).toStringAsFixed(2)),
      'raster_ms_avg': double.parse(avg(raster).toStringAsFixed(2)),
      'raster_ms_p90': double.parse(pct(raster, .9).toStringAsFixed(2)),
      'raster_ms_max': double.parse(pct(raster, 1).toStringAsFixed(2)),
      'total_ms_p90': double.parse(pct(total, .9).toStringAsFixed(2)),
      'janky': janky,
      'janky_pct': _timings.isEmpty
          ? 0
          : double.parse((100 * janky / _timings.length).toStringAsFixed(1)),
      'mode': kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release'),
    };
    final line = jsonEncode(out);
    debugPrint('[ritm-fps] $line');
    try {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/ritm_fps.json').writeAsString(line);
    } catch (_) {}
  }
}
