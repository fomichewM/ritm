// «Ритм» B6 — онбординг (ТЗ v3 U7): три экрана при первом входе в приложение.
// 1) браслет (модель, поиск/сопряжение, прошивку не обновлять);
// 2) «Здоровье» (права; Apple Watch — днём, ночью не нужны);
// 3) Помощник: свой ключ OpenAI — необязательно, «что отправляется» (честно:
//    помощник Edge сам запрашивает производные показатели из базы — run_sql
//    по представлениям, без сырого сигнала).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/prefs.dart';
import '../ui2/screens/home_screen.dart' show go;
import 'ritm_more.dart' show RitmAssistantSettings, RitmBandScreen;
import 'ritm_ui.dart';
import 'ritm_watch.dart' show RitmWatchReader;

const String kRitmOnboardKey = 'ritm.onboard.v1';

/// Показать ли онбординг (один раз на установку). Пока настройки не
/// прочитаны (тесты оболочки, первые миллисекунды) — не показываем.
bool get ritmNeedsOnboarding => Prefs.loaded && !Prefs.getBool(kRitmOnboardKey, false);

void ritmMarkOnboarded() => Prefs.setBool(kRitmOnboardKey, true);

class RitmOnboarding extends StatefulWidget {
  final VoidCallback onDone;
  final int initialPage;
  const RitmOnboarding({super.key, required this.onDone, this.initialPage = 0});
  @override
  State<RitmOnboarding> createState() => _RitmOnboardingState();
}

class _RitmOnboardingState extends State<RitmOnboarding> {
  late final _pc = PageController(initialPage: widget.initialPage);
  late int _page = widget.initialPage;
  String? _healthNote;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _next() {
    if (_page >= 2) {
      ritmMarkOnboarded();
      widget.onDone();
      return;
    }
    _pc.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  Future<void> _health() async {
    final ok = await RitmWatchReader().requestAccess();
    if (mounted) {
      setState(
        () => _healthNote = ok
            ? 'Готово. Если Apple Watch есть — дневные тренировки и шаги подтянутся сами.'
            : 'Доступ можно выдать позже: Ещё → Источники.',
      );
    }
  }

  @override
  Widget build(BuildContext c) {
    final pages = [
      _Page(
        icon: LucideIcons.watch,
        title: 'Браслет',
        lead: 'Ночь и восстановление «Ритм» считает по браслету WHOOP.',
        lines: const [
          (LucideIcons.badgeCheck, 'WHOOP 4.0, 5.0 и MG', 'Модель «Ритм» определит сам.'),
          (LucideIcons.moon, 'Носите ночью', 'Сон, пульс покоя, ВСР и дыхание — с браслета.'),
          (LucideIcons.ban, 'Прошивку не обновляйте', 'Обновление в приложении WHOOP может закрыть чтение данных.'),
        ],
        action: RButton(LucideIcons.bluetooth, 'Найти браслет', onTap: () => go(c, const RitmBandScreen())),
      ),
      _Page(
        icon: LucideIcons.heartPulse,
        title: 'Здоровье',
        lead: 'Днём точнее часы, ночью — браслет. «Ритм» берёт лучшее из обоих.',
        lines: const [
          (LucideIcons.bookOpen, 'Читает', 'Шаги, тренировки и пульс Apple Watch из «Здоровья».'),
          (LucideIcons.penLine, 'Пишет только сон', 'Остальное в «Здоровье» не меняется.'),
          (LucideIcons.lock, 'Пульс и ВСР — на телефоне', 'На сервер «Ритма» они не уходят никогда.'),
        ],
        action: RButton(LucideIcons.shieldCheck, 'Разрешить доступ', onTap: _health),
        note: _healthNote,
      ),
      _Page(
        icon: LucideIcons.sparkles,
        title: 'Помощник',
        lead: 'Ответит, почему сегодня так, и подскажет план. Необязательно — без него работает всё остальное.',
        lines: const [
          (LucideIcons.keyRound, 'Свой ключ', 'OpenAI или свой сервер (Ollama, LM Studio). Ключ — в связке ключей телефона.'),
          (LucideIcons.send, 'Напрямую, не через нас', 'Уходят ваш вопрос и нужные показатели: сон, восстановление, нагрузка, пульс, ВСР, тренировки.'),
          (LucideIcons.lock, 'Посекундные записи — нет', 'Записи браслета не отправляются.'),
        ],
        action: RButton(LucideIcons.keyRound, 'Указать ключ', onTap: () => go(c, const RitmAssistantSettings())),
      ),
    ];
    return Scaffold(
      backgroundColor: RC.bg,
      body: DecoratedBox(
        decoration: RC.background,
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    const RitmMark(size: 22),
                    const SizedBox(width: 8),
                    const Text('Ритм', style: RT.title),
                    const Spacer(),
                    TextButton(
                      key: const Key('onboard.skip'),
                      onPressed: () {
                        ritmMarkOnboarded();
                        widget.onDone();
                      },
                      child: Text('Пропустить', style: RT.label.copyWith(color: RC.ink2)),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pc,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: pages,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 3; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _page ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page ? RC.brandA : RC.cardHi,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: RButton(
                  null,
                  _page < 2 ? 'Далее' : 'Начать',
                  key: const Key('onboard.next'),
                  kind: RButtonKind.primary,
                  onTap: _next,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final IconData icon;
  final String title;
  final String lead;
  final List<(IconData, String, String)> lines;
  final Widget action;
  final String? note;
  const _Page({required this.icon, required this.title, required this.lead, required this.lines, required this.action, this.note});

  @override
  Widget build(BuildContext c) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    children: [
      SizedBox(height: 176, child: Center(child: _Hero(icon: icon))),
      const SizedBox(height: 8),
      Text(title, style: RT.h1, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Text(lead, style: RT.body.copyWith(color: RC.ink2), textAlign: TextAlign.center),
      const SizedBox(height: 20),
      RCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: RC.cardHi, borderRadius: BorderRadius.circular(10)),
                    child: Icon(lines[i].$1, size: 18, color: RC.brandA),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(lines[i].$2, style: RT.title),
                        const SizedBox(height: 2),
                        Text(lines[i].$3, style: RT.small.copyWith(color: RC.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: RS.cardGap),
      action,
      if (note != null) ...[const SizedBox(height: 10), Text(note!, style: RT.small)],
    ],
  );
}

/// Заставка экрана онбординга: три кольца «Ритма» (сон, восстановление,
/// нагрузка) вокруг значка шага — тот же язык, что на главной.
class _Hero extends StatelessWidget {
  final IconData icon;
  const _Hero({required this.icon});

  @override
  Widget build(BuildContext c) => SizedBox(
    width: 160,
    height: 160,
    child: CustomPaint(
      painter: _RingsPainter(),
      child: Center(child: Icon(icon, size: 44, color: RC.ink)),
    ),
  );
}

class _RingsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const rings = [(RC.sleepBlue, 76.0, .72), (RC.green, 62.0, .80), (RC.strain1, 48.0, .55)];
    for (final (color, r, frac) in rings) {
      final track = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..color = RC.ringTrack;
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawCircle(c, r, track);
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -1.5708, 6.2832 * frac, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
