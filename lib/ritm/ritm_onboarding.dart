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
        lines: const [
          ('Подходит WHOOP 4.0, 5.0 и MG', 'Модель «Ритм» определит сам при подключении.'),
          ('Ночь — с браслета', 'Сон, пульс покоя, ВСР и дыхание считаются по браслету — носите его ночью.'),
          ('Прошивку не обновляйте', 'Обновление в приложении WHOOP может отключить чтение данных «Ритмом».'),
        ],
        action: RButton(LucideIcons.bluetooth, 'Найти браслет', onTap: () => go(c, const RitmBandScreen())),
      ),
      _Page(
        icon: LucideIcons.heartPulse,
        title: 'Здоровье',
        lines: const [
          ('Только чтение', '«Ритм» читает из «Здоровья» шаги, тренировки и данные Apple Watch и пишет туда сон.'),
          ('Apple Watch — днём', 'Тренировки и пульс днём точнее с часов. Ночью часы не нужны: ночь — с браслета.'),
          ('Всё на телефоне', 'Пульс, ВСР и стресс не уходят с телефона никуда.'),
        ],
        action: RButton(LucideIcons.shieldCheck, 'Разрешить доступ', onTap: _health),
        note: _healthNote,
      ),
      _Page(
        icon: LucideIcons.sparkles,
        title: 'Помощник',
        lines: const [
          ('Необязательно', 'Без ключа всё работает, кроме ответов помощника.'),
          ('Свой ключ OpenAI', 'Ключ хранится в связке ключей телефона, запросы идут напрямую в OpenAI, не через наш сервер.'),
          ('Что отправляется', 'Ваш вопрос и показатели, которые помощник запросит из базы на телефоне: сон, восстановление, нагрузка, пульс покоя, ВСР, тренировки. Сырой сигнал браслета не отправляется.'),
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
  final List<(String, String)> lines;
  final Widget action;
  final String? note;
  const _Page({required this.icon, required this.title, required this.lines, required this.action, this.note});

  @override
  Widget build(BuildContext c) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
    children: [
      Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: RC.cardHi, borderRadius: BorderRadius.circular(RS.rCard)),
        child: Icon(icon, size: 34, color: RC.brandA),
      ),
      const SizedBox(height: 20),
      Text(title, style: RT.h1),
      const SizedBox(height: 16),
      RCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              Text(lines[i].$1, style: RT.title),
              const SizedBox(height: 4),
              Text(lines[i].$2, style: RT.body),
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
