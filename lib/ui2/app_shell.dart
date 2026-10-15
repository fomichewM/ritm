// The four-tab shell.
//
// Today · Sleep · Activity · Health. Stable: the contents personalise, the
// mental map does not. Each domain owns an accent, so colour tells you where
// you are before the label does. Profile is not a tab; every tab's header
// carries the avatar into it.
//
// There is no fifth tab, and the type system is what says so — [ShellDomain]
// is a closed enum and [AppShell] takes a builder keyed by it, so "just add a
// tab for X" is a change to this file with a reviewer attached, not something
// a screen can do on its own. Anything that feels like another destination is
// a section or a pushed screen inside the domain that owns it.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import 'grammar.dart';
import 'theme.dart';
import '../ritm/ritm_ui.dart' show RitmMark;

/// The four primary destinations, in bar order.
// «Ритм»: три вкладки — Сегодня · Здоровье · Ещё (RITM2_PROPOSAL п. 1).
// Сон и Активность Edge ушли внутрь «Сегодня» (датчики, «Мой день»).
enum ShellDomain {
  today('Today', LucideIcons.house, C.domHome),
  health('Health', LucideIcons.heartPulse, C.domHealth),
  // «Ритм» B5 (ТЗ v2 §0): четвёртая вкладка.
  community('Community', LucideIcons.users, C.n400),
  more('More', LucideIcons.menu, C.n400);

  const ShellDomain(this.label, this.icon, this.accent);

  final String label;
  final IconData icon;

  /// [label] in the user's language. Own keys rather than the screen titles,
  /// so two tabs can never end up with the same translated word.
  String title(BuildContext c) {
    final l = AppLocalizations.of(c);
    return switch (this) {
          // «Ритм»: «Главная» (ТЗ v2 §0), на других языках — как у Edge.
          ShellDomain.today => l == null
              ? null
              : (l.localeName.startsWith('ru') ? 'Главная' : l.tabToday),
          ShellDomain.health => l?.tabHealth,
          ShellDomain.community => l == null
              ? null
              : (l.localeName.startsWith('ru') ? 'Сообщество' : 'Community'),
          ShellDomain.more => l == null ? null : _moreWord(l.localeName),
        } ??
        label;
  }

  /// The domain's pigment. Use `P.of(context).on(accent)` for text and
  /// `.fill(accent)` for a filled surface — the raw value is not AA-safe.
  final Color accent;
}

/// «Ещё» на языке пользователя (своего ключа в arb пока нет).
String _moreWord(String locale) => switch (locale.split('_').first) {
      'ru' => 'Ещё',
      'de' => 'Mehr',
      'es' => 'Más',
      'fr' => 'Plus',
      'zh' => '更多',
      'hi' => 'अधिक',
      _ => 'More',
    };

// There is no `Domain` InheritedWidget. There was one, promising that a screen
// "and anything it pushes" could pick up its accent without threading it — but
// nothing ever read it, and a pushed route could not have: `MaterialApp.home`
// is the gate, so `Navigator.of` pushes above the shell entirely. Screens take
// their accent as a parameter, which is honest about where it comes from.

class AppShell extends StatefulWidget {
  /// Builds the body of one domain. Called lazily — a tab is not built until
  /// it is first selected, then kept alive by the [IndexedStack].
  final Widget Function(BuildContext context, ShellDomain domain) builder;

  final ShellDomain initial;

  /// Notified on every tab change, including a re-tap of the current tab
  /// (which domains conventionally use to scroll to top) and a return via Back.
  final void Function(ShellDomain domain)? onSelect;

  /// Pinned between the domain and the tab bar, above every tab. This is not
  /// a general slot — it exists for state that is RUNNING and is not on
  /// screen, which today means a minimised workout. A domain's own content
  /// belongs inside the domain.
  final Widget? banner;

  /// «Ритм»: круглая кнопка «Помощник» справа от пилюли (ТЗ v2 §0).
  final VoidCallback? onAssistant;

  const AppShell({
    super.key,
    required this.builder,
    this.initial = ShellDomain.today,
    this.onSelect,
    this.banner,
    this.onAssistant,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late ShellDomain _current = widget.initial;
  late final Set<ShellDomain> _built = {widget.initial};
  // Tabs are kept alive, not pushed onto the Navigator. Keep their history
  // here so Android Back can return to the previous tab. A restored tab or
  // cold-launch deep link has Today as its way back into the app.
  late final List<ShellDomain> _history = [
    if (widget.initial != ShellDomain.today) ShellDomain.today,
  ];

  void _select(ShellDomain d) {
    setState(() {
      // Each tab at most once, most recent last, so switching back and forth
      // between two tabs does not add a Back press per switch. Today stays in
      // as the way back into the app even while it is the tab on screen.
      if (d != _current) {
        _history.remove(_current);
        // Leaving Today puts it back at the bottom, never on top: it is the
        // last stop before Back leaves the app.
        if (_current == ShellDomain.today) {
          _history.insert(0, _current);
        } else {
          _history.add(_current);
        }
        if (d != ShellDomain.today) _history.remove(d);
      }
      _current = d;
      _built.add(d);
    });
    widget.onSelect?.call(d);
  }

  void _back() {
    if (_history.isEmpty) return;
    setState(() {
      _current = _history.removeLast();
      _built.add(_current);
    });
    widget.onSelect?.call(_current);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return PopScope<Object?>(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: p.bg,
        // «Ритм»: содержимое идёт под стеклянную пилюлю, как у WHOOP.
        extendBody: true,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: _current.index,
                  children: [
                    // An unvisited tab is an empty box, not a built screen — the
                    // old shell built all forty screens' worth of state on launch.
                    for (final d in ShellDomain.values)
                      if (_built.contains(d))
                        widget.builder(c, d)
                      else
                        const SizedBox.shrink(),
                  ],
                ),
              ),
              if (widget.banner != null)
                Padding(
                  // «Ритм»: таб-бар плавающий — баннер над ним.
                  padding: EdgeInsets.only(
                      bottom: 62 + MediaQuery.paddingOf(c).bottom),
                  child: widget.banner!,
                ),
            ],
          ),
        ),
        bottomNavigationBar: _TabBar(
          current: _current,
          onTap: _select,
          onAssistant: widget.onAssistant,
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final ShellDomain current;
  final ValueChanged<ShellDomain> onTap;
  final VoidCallback? onAssistant;

  const _TabBar({required this.current, required this.onTap, this.onAssistant});

  // «Ритм» (ТЗ v2 §0): стеклянная пилюля + круглая кнопка помощника.
  // Высота 56 и положение — по замеру WHOOP на iPhone владельца (±5 %).
  static const _h = 56.0;

  @override
  Widget build(BuildContext c) {
    final bottomInset = MediaQuery.paddingOf(c).bottom;
    final bottom = bottomInset > 0 ? (bottomInset - 10).clamp(12.0, 40.0) : 12.0;
    final radius = BorderRadius.circular(_h / 2);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 6, 16, bottom),
      child: SizedBox(
        height: _h,
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: C.ritmBar.withValues(alpha: .9),
                      borderRadius: radius,
                      border: Border.all(color: C.ritmBarLine, width: 1),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final d in ShellDomain.values)
                          Expanded(
                            child: _Tab(
                              domain: d,
                              on: d == current,
                              onTap: () => onTap(d),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (onAssistant != null) ...[
              const SizedBox(width: 8),
              _AssistantButton(size: _h, onTap: onAssistant!),
            ],
          ],
        ),
      ),
    );
  }
}

class _AssistantButton extends StatelessWidget {
  final double size;
  final VoidCallback onTap;
  const _AssistantButton({required this.size, required this.onTap});

  @override
  Widget build(BuildContext c) => Semantics(
        button: true,
        label: 'Помощник',
        excludeSemantics: true,
        child: Pressable(
          onTap: onTap,
          semanticLabel: 'Помощник',
          child: Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [C.ritmBrandA, C.ritmBrandB],
              ),
            ),
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: C.ritmAssistantCore,
              ),
              alignment: Alignment.center,
              child: const RitmMark(size: 24),
            ),
          ),
        ),
      );
}

class _Tab extends StatelessWidget {
  final ShellDomain domain;
  final bool on;
  final VoidCallback onTap;

  const _Tab({required this.domain, required this.on, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = on ? p.ink : p.ink3;
    final label = domain.title(c);
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        // «Ритм»: пилюля фиксированной высоты (как у WHOOP) — подпись растёт
        // с системным размером текста до 1,3×, дальше сжимается целиком.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(domain.icon, size: 22, color: ink),
              const SizedBox(height: 3),
              Text(
                label,
                textAlign: TextAlign.center,
                textScaler: MediaQuery.textScalerOf(c)
                    .clamp(maxScaleFactor: 1.3),
                style: F.ritmTab.copyWith(
                  color: ink,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
