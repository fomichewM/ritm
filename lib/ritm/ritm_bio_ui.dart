// «Ритм» — экраны биовозраста (ТЗ v2 §4.1, §4.2, §10.7; сборка B4).
//
// Герой «Биовозраст» (облачко §11) открывает вкладку «Здоровье»; под ним
// карточка «Темп старения»; тап → экран «Биовозраст»: 90 дней, 8 вкладов
// (складываются в разницу с паспортом), «Как считается». Везде «оценка».
// Возраст — только из даты рождения в профиле (или «Взять из Здоровья»),
// числом нигде не зашит.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui2/screens/home_screen.dart' show go, pointsOf;
import 'ritm_bioage.dart';
import 'ritm_demo.dart' show ritmDemoBio, ritmDemoBirth, ritmDemoNoBirth;
import 'ritm_hk.dart' show HkSample;
import 'ritm_home.dart' show isStrengthType;
import 'ritm_orb.dart';
import 'ritm_scores.dart' show dec1;
import 'ritm_ui.dart';
import 'ritm_watch_store.dart';

/// Дата рождения и пол из профиля (в демо — демо-дата).
({DateTime? birth, bool female}) ritmBirthOf(BuildContext c) {
  final demo = ritmDemoBirth();
  if (demo != null) {
    return (birth: ritmDemoNoBirth.value ? null : demo, female: false);
  }
  try {
    final u = c.read<AppState>().user;
    return (
      birth: parseBirth(u?['birth_date']),
      female: '${u?['sex'] ?? ''}'.toLowerCase() == 'f' ||
          '${u?['sex'] ?? ''}'.toLowerCase() == 'female',
    );
  } catch (_) {
    return (birth: null, female: false);
  }
}

/// Возраст (полных лет) из профиля; null — даты рождения нет.
int? ritmAgeOf(BuildContext c, [DateTime? now]) {
  final b = ritmBirthOf(c).birth;
  return b == null ? null : ageOn(b, now ?? DateTime.now());
}

/// Сбор дневных рядов для §10.7 из базы (браслет) и «Здоровья» (VO₂max Watch).
class RitmBioStore {
  static final days = ValueNotifier<List<BioDay>?>(null);
  static DateTime? _at;
  static bool _busy = false;

  static Future<void> load(dynamic repo, {bool force = false}) async {
    final demo = ritmDemoBio();
    if (demo != null) {
      days.value = demo;
      return;
    }
    if (repo == null || _busy) return;
    final now = DateTime.now();
    if (!force && _at != null && now.difference(_at!).inMinutes < 30) return;
    _busy = true;
    try {
      days.value = await _read(repo, now);
      _at = now;
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  static String _id(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Future<List<BioDay>> _read(dynamic repo, DateTime now) async {
    const n = 120;
    final today = DateTime(now.year, now.month, now.day);
    Future<Map<String, double>> series(String k) async {
      final out = <String, double>{};
      try {
        for (final p in pointsOf(await repo.getChart(k))) {
          final d = DateTime.fromMillisecondsSinceEpoch(p.t * 1000);
          out[_id(d)] = p.v;
        }
      } catch (_) {}
      return out;
    }

    final sleep = await series('sleep');
    final onset = await series('sleep_onset_sec');
    final mid = await series('midsleep_sec');
    final steps = await series('steps');
    final rhr = await series('resting_hr');
    // Силовые — по тренировкам за 120 дней одним запросом.
    final strength = <String, double>{};
    final hadSessions = <String>{};
    try {
      final ss = await repo.getSessions(
        from: today.subtract(const Duration(days: n)).millisecondsSinceEpoch ~/ 1000,
        to: today.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
        includeDetected: false,
      );
      for (final s in ss as List) {
        final t = ((s['start_ts'] as num?) ?? 0).toInt();
        final id = _id(DateTime.fromMillisecondsSinceEpoch(t * 1000));
        hadSessions.add(id);
        if (isStrengthType(s['type']?.toString())) {
          strength[id] =
              (strength[id] ?? 0) + ((s['duration_min'] as num?) ?? 0).toDouble();
        }
      }
    } catch (_) {}
    // VO₂max Watch: последнее значение на каждый день.
    final vo2 = <HkSample>[...?RitmWatchStore.data.value?.vo2Series]
      ..sort((a, b) => a.s.compareTo(b.s));
    final out = <BioDay>[];
    for (var i = n - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final id = _id(d);
      double? z13, z45;
      // Зоны — из нагрузки дня (только за дни, когда браслет был на руке).
      if (sleep.containsKey(id) || rhr.containsKey(id)) {
        try {
          final m = await repo.getDayStrain(id);
          final z = m['zones'];
          if (z is Map && z.isNotEmpty) {
            double v(int k) => ((z['z$k'] as num?) ?? 0).toDouble();
            z13 = v(1) + v(2) + v(3);
            z45 = v(4) + v(5);
          }
        } catch (_) {}
      }
      double? v2;
      for (final s in vo2) {
        if (s.s.isAfter(d.add(const Duration(days: 1)))) break;
        v2 = s.v;
      }
      final on = onset[id], md = mid[id];
      final worn = sleep.containsKey(id) || rhr.containsKey(id);
      out.add(
        BioDay(
          d,
          sleepMin: sleep[id],
          onsetMin: on == null ? null : on / 60,
          wakeMin: on == null || md == null ? null : (2 * md - on) / 60,
          steps: steps[id],
          z13: z13,
          z45: z45,
          strength: worn || hadSessions.contains(id) ? (strength[id] ?? 0) : null,
          rhr: rhr[id],
          vo2: v2,
        ),
      );
    }
    return out;
  }
}

Color bioColor(BioResult r) {
  if (r.state != BioState.ready || r.delta == null) return RC.ink3;
  return switch (bioZone(r.delta!)) {
    -1 => RC.green,
    1 => RC.yellow,
    _ => RC.brandA,
  };
}

// ───────────────────────── герой ─────────────────────────

/// Блок 300 pt без карточки: облачко Ø 200, число, «БИОВОЗРАСТ · ОЦЕНКА»,
/// строка разницы; радиальное свечение цвета облака позади.
class BioHero extends StatelessWidget {
  final BioResult r;
  final VoidCallback? onTap;
  const BioHero({super.key, required this.r, this.onTap});

  @override
  Widget build(BuildContext c) {
    final col = bioColor(r);
    final ready = r.state == BioState.ready && r.bio != null;
    final (String sub, Color subColor) = switch (r.state) {
      BioState.ready => (
        bioDeltaText(r.delta!),
        switch (bioZone(r.delta!)) {
          -1 => RC.green,
          1 => RC.yellow,
          _ => RC.ink2,
        },
      ),
      BioState.calibrating => (
        'нужно $kBioMinDays дней · ${r.have}/$kBioMinDays',
        RC.ink2,
      ),
      BioState.noProfile => ('укажите дату рождения в профиле', RC.ink2),
      BioState.noData => ('нет данных браслета', RC.ink2),
    };
    return Semantics(
      button: onTap != null,
      label: ready
          ? 'Биовозраст, оценка: ${dec1(r.bio!)}, $sub'
          : 'Биовозраст: $sub',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 300,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Свечение позади: цвет облака 25 % → 0, радиус 260.
              Positioned(
                left: -200,
                right: -200,
                top: -110,
                bottom: -110,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: .5,
                        colors: [
                          col.withValues(alpha: ready ? .25 : .10),
                          col.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              RitmOrb(
                color: col,
                size: 200,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ready ? dec1(r.bio!) : '—',
                      style: RT.display.copyWith(
                        color: ready ? RC.ink : RC.ink2,
                        shadows: const [
                          Shadow(color: Color(0xAA000000), blurRadius: 12),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'БИОВОЗРАСТ · ОЦЕНКА',
                      style: RT.cap.copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: 170,
                      child: Text(
                        sub,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: RT.label.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: subColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── темп старения ─────────────────────────

/// Карточка «Темп старения» (§4.2): чип к неделе назад, число над шкалой,
/// 60 штрихов от −1,0x до 3,0x, курсор, «Медленно / Быстро».
class PaceCard extends StatelessWidget {
  final BioResult r;
  final VoidCallback? onMore;
  const PaceCard({super.key, required this.r, this.onMore});

  @override
  Widget build(BuildContext c) {
    final p = r.state == BioState.ready ? r.pace : null;
    final trend = paceTrend(r.pace, r.paceWeekAgo);
    final chip = p == null || r.paceWeekAgo == null
        ? null
        : switch (trend) {
            -1 => ('▼ медленнее, чем неделю назад', RC.green),
            1 => ('▲ быстрее, чем неделю назад', RC.yellow),
            _ => ('как неделю назад', RC.ink2),
          };
    final calib = switch (r.state) {
      BioState.calibrating => 'калибровка · ${r.have}/$kBioMinDays дней',
      BioState.noProfile => 'укажите дату рождения в профиле',
      BioState.noData => 'нет данных браслета',
      BioState.ready => 'нужно 28 дней истории биовозраста',
    };
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('ТЕМП СТАРЕНИЯ', style: RT.cap),
              const SizedBox(width: 8),
              const Spacer(),
              if (chip != null)
                Flexible(
                  flex: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: chip.$2.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        chip.$1,
                        maxLines: 1,
                        style: RT.micro.copyWith(
                          color: chip.$2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 78,
            child: LayoutBuilder(
              builder: (c, b) {
                final w = b.maxWidth;
                final x = p == null ? null : w * ((p - kPaceMin) / (kPaceMax - kPaceMin));
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: RC.ink3,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('Медленно', style: RT.small.copyWith(color: RC.ink2)),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Row(
                        children: [
                          Text('Быстро', style: RT.small.copyWith(color: RC.ink2)),
                          const SizedBox(width: 6),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: RC.ink2, width: 2),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (x != null)
                      Positioned(
                        left: (x - 40).clamp(0, w - 80),
                        width: 80,
                        top: 12,
                        child: Text(
                          paceText(p!),
                          textAlign: TextAlign.center,
                          style: RT.num,
                        ),
                      )
                    else
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 21,
                        child: Text(
                          calib,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: RT.small.copyWith(color: RC.ink2),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 42,
                      height: 24,
                      child: CustomPaint(painter: _PaceScale(p)),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          const Row(
            children: [
              Text('−1,0x', style: RT.micro),
              Spacer(),
              Text('1,0x', style: RT.micro),
              Spacer(),
              Text('3,0x', style: RT.micro),
            ],
          ),
          if (onMore != null) ...[
            const SizedBox(height: 14),
            RButton(
              LucideIcons.chartLine,
              'Подробнее',
              kind: RButtonKind.secondary,
              height: 44,
              onTap: onMore,
            ),
          ],
        ],
      ),
    );
  }
}

class _PaceScale extends CustomPainter {
  final double? pace;
  _PaceScale(this.pace);

  @override
  void paint(Canvas canvas, Size s) {
    const n = 60;
    final cur = pace == null ? null : (pace! - kPaceMin) / (kPaceMax - kPaceMin);
    final one = (1 - kPaceMin) / (kPaceMax - kPaceMin);
    final paint = Paint()
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final f = i / (n - 1);
      final x = 1 + (s.width - 2) * f;
      final near = cur == null ? 1.0 : (f - cur).abs();
      // Штрихи рядом с курсором ярче (как «волна» у шкалы).
      final a = cur == null ? .35 : (.28 + .6 * math.exp(-near * near * 900));
      paint.color = RC.ink.withValues(alpha: a.clamp(0, 1).toDouble());
      final h = (f - one).abs() < .5 / n ? 20.0 : 16.0;
      canvas.drawLine(
        Offset(x, (s.height - h) / 2),
        Offset(x, (s.height + h) / 2),
        paint,
      );
    }
    if (cur != null) {
      final x = 1 + (s.width - 2) * cur.clamp(0, 1);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, s.height),
        Paint()
          ..color = RC.ink
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_PaceScale o) => o.pace != pace;
}

// ───────────────────────── экран «Биовозраст» ─────────────────────────

class RitmBioScreen extends StatelessWidget {
  final BioResult r;
  final ScrollController? controller;
  const RitmBioScreen({super.key, required this.r, this.controller});

  @override
  Widget build(BuildContext c) {
    final ready = r.state == BioState.ready && r.bio != null;
    final col = bioColor(r);
    return RPage(
      title: 'Биовозраст',
      large: true,
      controller: controller,
      children: [
        Center(
          child: RitmOrb(
            color: col,
            size: 150,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ready ? dec1(r.bio!) : '—',
                  style: RT.display.copyWith(fontSize: 38),
                ),
                const SizedBox(height: 4),
                Text('ОЦЕНКА', style: RT.cap.copyWith(fontSize: 11)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            ready
                ? '${bioDeltaText(r.delta!)} · по паспорту ${dec1(r.age!)}'
                : (r.state == BioState.calibrating
                      ? 'Калибровка: ${r.have} из $kBioMinDays дней с браслетом'
                      : 'Укажите дату рождения в профиле'),
            textAlign: TextAlign.center,
            style: RT.body.copyWith(color: RC.ink),
          ),
        ),
        const SizedBox(height: RS.sectionGap),
        if (ready) ...[
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const RCardHead('90 дней · оценка', trailing: null),
                const SizedBox(height: 12),
                BioLine(values: r.history, passport: r.age!),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(width: 14, height: 2, color: col),
                    const SizedBox(width: 6),
                    const Text('биовозраст', style: RT.small),
                    const SizedBox(width: 16),
                    const SizedBox(width: 18, child: RDashes()),
                    const SizedBox(width: 6),
                    const Text('паспорт', style: RT.small),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: RS.cardGap),
          PaceCard(r: r),
          const SizedBox(height: RS.cardGap),
          _parts(),
          const SizedBox(height: RS.cardGap),
        ],
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RCardHead('Как считается', trailing: null),
              const SizedBox(height: 10),
              Text(_how, style: RT.body),
            ],
          ),
        ),
      ],
    );
  }

  static const _how =
      'Это оценка, а не медицинский показатель. Берём средние за 30 дней (нужно не меньше 14 дней с браслетом) и сравниваем с ориентирами по 8 привычкам: сон (7–8 ч — ноль, каждый час недосыпа старит на 1,5 года), режим (разброс отбоя и подъёма), шаги (от 8 000 в день молодят на 1,5 года), минуты в зонах 1–3 и 4–5 за неделю, силовые, VO₂max Apple Watch по возрастным таблицам Американского колледжа спортивной медицины для вашего возраста и пола, пульс покоя. '
      'Если чего-то не измеряем (например, нет Watch — нет VO₂max), считаем по остальным привычкам, как будто их 8; нужно хотя бы 5. Разница с паспортом ограничена ±10 годами и сглаживается по дням: число меняется не больше чем на 0,1 года в день. '
      'Темп старения — на сколько лет биовозраст вырос за последние 28 дней в пересчёте на год: 1,0x — как календарь, меньше — медленнее, от −1,0x до 3,0x.';

  Widget _parts() {
    final sum = r.parts.fold<double>(0, (a, b) => a + b) + r.smooth;
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Что влияет · 8 факторов', trailing: null),
          const SizedBox(height: 4),
          for (var i = 0; i < kBioOrder.length; i++)
            _partRow(kBioOrder[i], r.today.length > i ? r.today[i] : null, r.parts[i]),
          // Девятая строка: сглаживание по дням (EMA) — чтобы сумма строк
          // была ровно разницей с паспортом.
          SizedBox(
            height: 56,
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: RC.cardHi,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(LucideIcons.waves, size: 16, color: RC.ink2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Сглаживание по дням',
                        style: RT.title.copyWith(fontSize: 15),
                      ),
                      const Text(
                        'не больше 0,1 года за день',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RT.small,
                      ),
                    ],
                  ),
                ),
                Text(
                  bioPartText(r.smooth),
                  style: RT.num.copyWith(fontSize: 15, color: _c(r.smooth)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(height: 1, color: RC.line),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Text('Сумма вкладов', style: RT.title),
              ),
              Text(
                bioPartText(sum),
                style: RT.num.copyWith(fontSize: 17, color: _c(sum)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${dec1(r.age!)} по паспорту ${sum < 0 ? '−' : '+'} ${dec1(sum.abs())} = ${dec1(r.bio!)} · оценка',
            style: RT.small,
          ),
        ],
      ),
    );
  }

  static Color _c(double v) =>
      v <= -0.05 ? RC.green : (v >= 0.05 ? RC.yellow : RC.ink2);

  Widget _partRow(BioKey k, BioPart? p, double years) {
    final present = p?.present ?? false;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: RC.cardHi,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_icon(k), size: 16, color: present ? RC.ink2 : RC.ink3),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bioName(k),
                  style: RT.title.copyWith(
                    fontSize: 15,
                    color: present ? RC.ink : RC.ink2,
                  ),
                ),
                Text(
                  p?.value ?? 'нет данных',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RT.small,
                ),
              ],
            ),
          ),
          Text(
            present ? bioPartText(years) : 'не учитывается',
            style: present
                ? RT.num.copyWith(fontSize: 15, color: _c(years))
                : RT.small,
          ),
        ],
      ),
    );
  }

  static IconData _icon(BioKey k) => switch (k) {
    BioKey.sleep => LucideIcons.moon,
    BioKey.regular => LucideIcons.alarmClock,
    BioKey.steps => LucideIcons.footprints,
    BioKey.z13 => LucideIcons.gauge,
    BioKey.z45 => LucideIcons.zap,
    BioKey.strength => LucideIcons.dumbbell,
    BioKey.vo2 => LucideIcons.wind,
    BioKey.rhr => LucideIcons.heartPulse,
  };
}

/// Линия биовозраста 90 дней + пунктир паспорта.
class BioLine extends StatelessWidget {
  final List<double?> values;
  final double passport;
  const BioLine({super.key, required this.values, required this.passport});

  @override
  Widget build(BuildContext c) => SizedBox(
    height: 140,
    width: double.infinity,
    child: CustomPaint(painter: _BioLinePainter(values, passport)),
  );
}

class _BioLinePainter extends CustomPainter {
  final List<double?> v;
  final double passport;
  _BioLinePainter(this.v, this.passport);

  @override
  void paint(Canvas canvas, Size s) {
    final xs = [...v.whereType<double>(), passport];
    if (xs.length < 2) return;
    var lo = xs.reduce(math.min), hi = xs.reduce(math.max);
    lo = (lo - .5).floorToDouble();
    hi = (hi + .5).ceilToDouble();
    const left = 30.0, bottom = 16.0;
    final w = s.width - left, h = s.height - bottom;
    double y(double val) => h - h * (val - lo) / (hi - lo);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final t in [lo, (lo + hi) / 2, hi]) {
      tp.text = TextSpan(text: dec1(t), style: RT.micro);
      tp.layout();
      tp.paint(canvas, Offset(0, y(t) - tp.height / 2));
      canvas.drawLine(
        Offset(left, y(t)),
        Offset(s.width, y(t)),
        Paint()
          ..color = RC.line
          ..strokeWidth = 1,
      );
    }
    // Паспорт — пунктир.
    final py = y(passport);
    for (var x = left; x < s.width; x += 8) {
      canvas.drawLine(
        Offset(x, py),
        Offset(math.min(x + 4, s.width), py),
        Paint()
          ..color = RC.ink3
          ..strokeWidth = 1,
      );
    }
    final path = Path();
    var started = false;
    double? lastX, lastY;
    for (var i = 0; i < v.length; i++) {
      final val = v[i];
      if (val == null) continue;
      final x = left + w * i / math.max(1, v.length - 1);
      if (!started) {
        path.moveTo(x, y(val));
        started = true;
      } else {
        path.lineTo(x, y(val));
      }
      lastX = x;
      lastY = y(val);
    }
    final col = (v.whereType<double>().lastOrNull ?? passport) - passport <= -1
        ? RC.green
        : RC.brandA;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = col,
    );
    if (lastX != null) {
      canvas.drawCircle(Offset(lastX, lastY!), 4, Paint()..color = col);
    }
    for (final (f, t) in [(0.0, '90 дн.'), (.5, '45 дн.'), (1.0, 'сегодня')]) {
      tp.text = TextSpan(text: t, style: RT.micro);
      tp.layout();
      final x = left + w * f - tp.width * f;
      tp.paint(canvas, Offset(x, s.height - tp.height));
    }
  }

  @override
  bool shouldRepaint(_BioLinePainter o) => o.v != v || o.passport != passport;
}

/// Открыть экран «Биовозраст».
void openBio(BuildContext c, BioResult r) => go(c, RitmBioScreen(r: r));

