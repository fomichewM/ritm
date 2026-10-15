// «Ритм» — вкладка «Сообщество» (ТЗ v2 §7, сборка B5): приглашение, команды,
// рейтинг Сегодня/Неделя по 4 метрикам, лента с реакциями, настройки
// публикации, удаление аккаунта. Вход и согласие — ritm_community_auth.dart.
// Чат и пуши — сборка B6 (вкладку «Чат» не показываем, пока её нет).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import 'ritm_avatar.dart';
import 'ritm_community_api.dart';
import 'ritm_community_auth.dart';
import 'ritm_demo.dart' show kRitmDemo, ritmDemoStep, ritmDemoNow;
import 'ritm_push.dart' show RitmPushBridge, ritmPushOpen;
import 'ritm_scores.dart' show RitmZone;
import 'ritm_ui.dart';

// ───────────────────────── форматы ─────────────────────────

String ritmDec1(num v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Значение метрики в рейтинге: «12,4» / «92 %».
String ritmMetricText(RMetric m, double? v) {
  if (v == null) return '—';
  return m.isStrain ? ritmDec1(v) : '${v.round()}\u00a0%';
}

/// Цвет числа по зоне (§1.1, §10.1–10.3).
Color ritmMetricColor(RMetric m, double? v) {
  if (v == null) return RC.ink3;
  return switch (m) {
    RMetric.sleep => RC.zone(v >= 85 ? RitmZone.green : v >= 70 ? RitmZone.yellow : RitmZone.red),
    RMetric.recovery => RC.zone(v >= 67 ? RitmZone.green : v >= 34 ? RitmZone.yellow : RitmZone.red),
    RMetric.strainDay => RC.strain(v),
    // Неделя — сумма до ~150: цвет по среднему дню.
    RMetric.strainWeek => RC.strain(v / 7),
  };
}

/// «3-й из 8».
String ritmPlaceText(int? place, int of) => place == null ? '—' : '$place-й из $of';

/// «только что» / «25 мин назад» / «2 ч назад» / «вчера» / «3 дн. назад».
String ritmAgo(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  final today = DateTime(now.year, now.month, now.day);
  if (!at.isBefore(today)) return '${d.inHours} ч назад';
  final days = today.difference(DateTime(at.year, at.month, at.day)).inDays;
  return days <= 1 ? 'вчера' : '$days дн. назад';
}

/// Строка ленты: «Михаил · бег 46 мин · нагрузка 10,0».
String ritmFeedText(RFeedItem x) {
  if (x.kind == 'workout') {
    return [
      x.name,
      '${ritmWorkoutWord(x.type)} ${x.minutes ?? 0} мин',
      if (x.strain != null) 'нагрузка ${ritmDec1(x.strain!)}',
    ].join(' · ');
  }
  return [
    x.name,
    if (x.recovery != null) 'восстановление ${x.recovery}\u00a0%',
    if (x.sleepPct != null) 'сон ${x.sleepPct}\u00a0%',
  ].join(' · ');
}

DateTime _now() => ritmDemoNow() ?? DateTime.now();

const _teamEmojis = ['🏃', '🚴', '🏋️', '🧘', '🏊', '⚽', '🏡', '💼', '🔥', '🌿'];

// ───────────────────────── вкладка ─────────────────────────

class RitmCommunityScreen extends StatefulWidget {
  const RitmCommunityScreen({super.key});
  @override
  State<RitmCommunityScreen> createState() => _RitmCommunityScreenState();
}

class _RitmCommunityScreenState extends State<RitmCommunityScreen> {
  RitmCommunity get _c => RitmCommunity.I;
  final _scroll = ScrollController();
  final _inviteKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(_c.start().then((_) => RitmPushBridge.ensure(_c)));
    _c.addListener(_onStage);
    ritmPushOpen.addListener(_openFromPush);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openFromPush());
    if (kRitmDemo) ritmDemoStep.addListener(_demoStep);
    WidgetsBinding.instance.addPostFrameCallback((_) => _demoStep());
  }

  @override
  void dispose() {
    if (kRitmDemo) ritmDemoStep.removeListener(_demoStep);
    _c.removeListener(_onStage);
    ritmPushOpen.removeListener(_openFromPush);
    _scroll.dispose();
    super.dispose();
  }

  RStage? _stage;
  void _onStage() {
    if (_c.stage == _stage) return;
    _stage = _c.stage;
    if (_stage == RStage.ready) unawaited(RitmPushBridge.ensure(_c));
  }

  /// Тап по пушу чата → экран команды на вкладке «Чат».
  Future<void> _openFromPush() async {
    final tid = ritmPushOpen.value;
    if (tid == null || !mounted) return;
    ritmPushOpen.value = null;
    if (_c.teams.isEmpty) await _c.refreshTeams();
    final t = _c.teams.where((x) => x.id == tid).firstOrNull;
    if (t == null || !mounted) return;
    final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
    unawaited(nav.push(ritmRoute(RitmTeamScreen(team: t, chat: true))));
  }

  // ── демо-автопилот (скриншоты B5): шаги 74–88 = сценарий 56–70 ──
  int _lastDemo = -1;
  void _demoStep() {
    if (!kRitmDemo || !mounted) return;
    final raw = ritmDemoStep.value;
    // B6: 89 — чат команды, 90 — отправка + ответ «друга», 91 — меню с уведомлениями.
    if (raw >= 89 && raw <= 91 && raw != _lastDemo) {
      _lastDemo = raw;
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted || ritmDemoStep.value != raw || _c.teams.isEmpty) return;
        final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
        unawaited(nav.push(ritmRoute(RitmTeamScreen(
          team: _c.teams.first,
          chat: true,
          demoDraft: raw == 90 ? 'Беру с собой Наталью, нас будет пятеро 👍' : null,
          demoMenu: raw == 91,
        ))));
      });
      return;
    }
    final st = raw - 18;
    if (st < 56 || st > 70 || st == _lastDemo) return;
    _lastDemo = st;
    Future.delayed(const Duration(milliseconds: 700), () async {
      if (!mounted || ritmDemoStep.value - 18 != st) return;
      final nav = Navigator.of(context);
      nav.popUntil((r) => r.isFirst);
      final c = _c;
      switch (st) {
        case 56:
          await c.signOut();
          (c.api as dynamic).reset();
        case 57:
          unawaited(nav.push(ritmRoute(const RitmSignInScreen())));
        case 58:
        case 59:
          unawaited(nav.push(ritmRoute(RitmConsentScreen(demoChecked: st == 59))));
        case 60:
          if (c.stage != RStage.ready) {
            await c.signInApple('demo', 'demo', localName: 'Михаил');
            await c.acceptConsent(processing: true, team: true);
          }
          c.setMetric(RMetric.strainDay);
          if (_scroll.hasClients) _scroll.jumpTo(0);
        case 61:
          _openMetricMenu(context);
        case 62:
          _openActions(context);
        case 63:
          _createTeam(context, demo: true);
        case 64:
          _joinTeam(context, demoCode: 'RUN7QK');
        case 65:
        case 66:
        case 67:
          unawaited(nav.push(ritmRoute(RitmTeamScreen(
            team: c.teams.first,
            demoPeriod: st == 66 ? RPeriod.week : RPeriod.day,
            demoScrollFeed: st == 67,
          ))));
        case 68:
          unawaited(nav.push(ritmRoute(const RitmCommunitySettings())));
        case 69:
          unawaited(nav.push(ritmRoute(const RitmCommunitySettings(demoDelete: true))));
        case 70:
          c.setMetric(RMetric.recovery);
      }
    });
  }

  @override
  Widget build(BuildContext c) {
    final bottom = RS.tabBarClearance + MediaQuery.paddingOf(c).bottom;
    return DecoratedBox(
      decoration: RC.background,
      child: ListenableBuilder(
        listenable: _c,
        builder: (c, _) {
          final st = _c.stage;
          return RefreshIndicator(
            onRefresh: _c.refreshTeams,
            color: RC.ink,
            backgroundColor: RC.card,
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(RS.screen, 4, RS.screen, bottom),
              children: [
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      const Expanded(child: Text('Сообщество', style: RT.h1)),
                      if (st == RStage.ready)
                        _IconBtn(
                          LucideIcons.settings,
                          'Настройки сообщества',
                          () => Navigator.of(c).push(ritmRoute(const RitmCommunitySettings())),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _InviteCard(key: _inviteKey, team: _c.teams.isEmpty ? null : _c.teams.first),
                const SizedBox(height: RS.sectionGap),
                if (st == RStage.loading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator(color: RC.ink3, strokeWidth: 2)),
                  )
                else if (st == RStage.signedOut)
                  _SignInCard(onTap: () => Navigator.of(c).push(ritmRoute(const RitmSignInScreen())))
                else if (st == RStage.needsConsent)
                  _ConsentCard(onTap: () => Navigator.of(c).push(ritmRoute(const RitmConsentScreen())))
                else
                  ..._teamsBlock(c),
                if (_c.error != null) ...[
                  const SizedBox(height: 12),
                  Text(_c.error!, style: RT.small.copyWith(color: RC.yellow)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _teamsBlock(BuildContext c) {
    final teams = _c.teams;
    return [
      RSection(
        'Команды',
        trailing: _IconBtn(LucideIcons.ellipsis, 'Создать или войти по коду', () => _openActions(c)),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          const Expanded(child: Text('МОИ КОМАНДЫ', style: RT.cap)),
          Builder(builder: (bc) => _MetricPicker(onTap: () => _openMetricMenu(bc))),
        ],
      ),
      const SizedBox(height: 10),
      if (teams.isEmpty)
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Пока нет команд', style: RT.title),
              const SizedBox(height: 6),
              const Text(
                'Создайте свою и отправьте код друзьям — или введите код, который прислали вам.',
                style: RT.body,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: RButton(LucideIcons.plus, 'Создать', kind: RButtonKind.primary, onTap: () => _createTeam(c))),
                  const SizedBox(width: 12),
                  Expanded(child: RButton(LucideIcons.keyRound, 'Ввести код', onTap: () => _joinTeam(c))),
                ],
              ),
            ],
          ),
        )
      else
        RCard(
          pad: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < teams.length; i++) ...[
                if (i > 0) const Divider(height: 1, thickness: 1, indent: 72, color: RC.line),
                _TeamRow(
                  team: teams[i],
                  onTap: () => Navigator.of(c).push(ritmRoute(RitmTeamScreen(team: teams[i]))),
                ),
              ],
            ],
          ),
        ),
      const SizedBox(height: 8),
      Text(
        'Место — за сегодня.',
        style: RT.small,
      ),
    ];
  }

  Future<void> _openMetricMenu(BuildContext c) async {
    final box = c.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(c).context.findRenderObject() as RenderBox?;
    RelativeRect pos = const RelativeRect.fromLTRB(200, 200, 16, 0);
    if (box != null && overlay != null && box.hasSize) {
      final tl = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
      pos = RelativeRect.fromLTRB(tl.dx, tl.dy, 16, 0);
    }
    final m = await showMenu<RMetric>(
      context: c,
      position: pos,
      color: RC.cardHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(RS.rTile)),
      items: [
        for (final m in RMetric.values)
          PopupMenuItem(
            value: m,
            height: 44,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: m == _c.metric ? const Icon(LucideIcons.check, size: 16, color: RC.ink) : null,
                ),
                Text(m.title, style: RT.title.copyWith(fontSize: 15)),
              ],
            ),
          ),
      ],
    );
    if (m != null) _c.setMetric(m);
  }

  void _openActions(BuildContext c) {
    showRSheet<void>(
      c,
      (sc) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Команды', style: RT.h2),
          const SizedBox(height: 12),
          RGroup(rows: [
            RRow(
              icon: LucideIcons.plus,
              title: 'Создать команду',
              sub: 'Вы получите код, чтобы позвать друзей',
              onTap: () {
                Navigator.of(sc).pop();
                _createTeam(c);
              },
            ),
            RRow(
              icon: LucideIcons.keyRound,
              title: 'Войти по коду',
              sub: '6 букв и цифр из приглашения',
              onTap: () {
                Navigator.of(sc).pop();
                _joinTeam(c);
              },
            ),
          ]),
        ],
      ),
    );
  }

  Future<void> _createTeam(BuildContext c, {bool demo = false}) async {
    final t = await showRSheet<RTeam>(c, (sc) => _CreateTeamSheet(demo: demo));
    if (t != null && c.mounted) {
      unawaited(Navigator.of(c).push(ritmRoute(RitmTeamScreen(team: t, justCreated: true))));
    }
  }

  Future<void> _joinTeam(BuildContext c, {String? demoCode}) async {
    final t = await showRSheet<RTeam>(c, (sc) => _JoinSheet(demoCode: demoCode));
    if (t != null && c.mounted) {
      unawaited(Navigator.of(c).push(ritmRoute(RitmTeamScreen(team: t))));
    }
  }
}

Route<T> ritmRoute<T>(Widget w) => MaterialPageRoute<T>(builder: (_) => w);

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _IconBtn(this.icon, this.label, this.onTap);
  @override
  Widget build(BuildContext c) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: InkResponse(
      onTap: onTap,
      radius: 22,
      child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: RC.ink)),
    ),
  );
}

class _MetricPicker extends StatelessWidget {
  final VoidCallback onTap;
  const _MetricPicker({required this.onTap});
  @override
  Widget build(BuildContext c) {
    final m = RitmCommunity.I.metric;
    return Semantics(
      button: true,
      label: 'Рейтинг: ${m.title}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: RC.card, borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(m.title.toUpperCase(), style: RT.cap.copyWith(fontSize: 11, color: RC.ink)),
              const SizedBox(width: 4),
              const Icon(LucideIcons.chevronDown, size: 14, color: RC.ink2),
            ],
          ),
        ),
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  final RTeam? team;
  const _InviteCard({super.key, this.team});

  @override
  Widget build(BuildContext c) => RCard(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.lerp(RC.cardHi, RC.brandA, .2)!,
        Color.lerp(RC.cardHi, RC.brandB, .2)!,
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(LucideIcons.userPlus, size: 16, color: RC.ink),
            SizedBox(width: 8),
            Text('ПРИГЛАСИТЬ ДРУГА', style: RT.cap),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Отправьте ссылку — друг установит Ритм и попадёт в вашу команду',
          style: RT.body.copyWith(color: RC.ink),
        ),
        const SizedBox(height: 14),
        Builder(
          builder: (bc) => RButton(
            LucideIcons.share,
            'Поделиться',
            kind: RButtonKind.primary,
            height: 44,
            onTap: () => ritmShareInvite(bc, team),
          ),
        ),
      ],
    ),
  );
}

/// Текст приглашения: код команды + страница с инструкцией на сервере.
String ritmInviteText(RTeam? t) {
  final link = t == null ? '$kRitmServer/join' : '$kRitmServer/join?code=${t.code}';
  return t == null
      ? 'Давай соревноваться в «Ритме» — сон, восстановление и нагрузка за день. Как установить: $link'
      : 'Вступай в мою команду «${t.name}» в «Ритме»: код ${t.code}. Как установить и войти: $link';
}

Future<void> ritmShareInvite(BuildContext c, RTeam? t) async {
  final box = c.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : const Rect.fromLTWH(0, 0, 1, 1);
  try {
    await Share.share(ritmInviteText(t), subject: 'Приглашение в «Ритм»', sharePositionOrigin: origin);
  } catch (_) {}
}

class _SignInCard extends StatelessWidget {
  final VoidCallback onTap;
  const _SignInCard({required this.onTap});
  @override
  Widget build(BuildContext c) => RCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Соревнуйтесь с друзьями', style: RT.title),
        const SizedBox(height: 6),
        const Text(
          'Команды, рейтинг по сну, восстановлению и нагрузке, лента тренировок. Вход — через Apple, на сервер уходят только итоги дня.',
          style: RT.body,
        ),
        const SizedBox(height: 14),
        RButton(LucideIcons.logIn, 'Войти', kind: RButtonKind.primary, onTap: onTap),
      ],
    ),
  );
}

class _ConsentCard extends StatelessWidget {
  final VoidCallback onTap;
  const _ConsentCard({required this.onTap});
  @override
  Widget build(BuildContext c) => RCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Осталось одно согласие', style: RT.title),
        const SizedBox(height: 6),
        const Text(
          'Без согласия на обработку данных команды и рейтинг не работают.',
          style: RT.body,
        ),
        const SizedBox(height: 14),
        RButton(LucideIcons.shieldCheck, 'Открыть согласие', kind: RButtonKind.primary, onTap: onTap),
      ],
    ),
  );
}

class _TeamAvatar extends StatelessWidget {
  final String emoji;
  final double size;
  const _TeamAvatar(this.emoji) : size = 44;
  @override
  Widget build(BuildContext c) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(color: RC.cardHi, shape: BoxShape.circle),
    child: Text(emoji, style: TextStyle(fontSize: size * .5)),
  );
}

class _TeamRow extends StatelessWidget {
  final RTeam team;
  final VoidCallback onTap;
  const _TeamRow({required this.team, required this.onTap});
  @override
  Widget build(BuildContext c) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            _TeamAvatar(team.emoji),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(team.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: RT.title),
                  const SizedBox(height: 2),
                  Text(_members(team.members), style: RT.small),
                ],
              ),
            ),
            Text(ritmPlaceText(team.myPlace, team.members), style: RT.label),
            const SizedBox(width: 6),
            const Icon(LucideIcons.chevronRight, size: 18, color: RC.ink3),
          ],
        ),
      ),
    ),
  );
}

String _members(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = (m10 == 1 && m100 != 11)
      ? 'участник'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'участника'
          : 'участников';
  return '$n $w';
}

// ───────────────────────── создать / войти ─────────────────────────

InputDecoration _input(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: RT.body.copyWith(color: RC.ink3),
  filled: true,
  fillColor: RC.cardHi,
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(RS.rTile), borderSide: BorderSide.none),
);

class _CreateTeamSheet extends StatefulWidget {
  final bool demo;
  const _CreateTeamSheet({this.demo = false});
  @override
  State<_CreateTeamSheet> createState() => _CreateTeamSheetState();
}

class _CreateTeamSheetState extends State<_CreateTeamSheet> {
  late final _name = TextEditingController(text: widget.demo ? 'Вечерний зал' : '');
  String _emoji = '🏃';
  @override
  void initState() {
    super.initState();
    if (widget.demo) _emoji = '🏋️';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final com = RitmCommunity.I;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: ListenableBuilder(
        listenable: com,
        builder: (c, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Новая команда', style: RT.h2),
            const SizedBox(height: 14),
            const Text('ЗНАЧОК', style: RT.cap),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in _teamEmojis)
                  GestureDetector(
                    onTap: () => setState(() => _emoji = e),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: RC.cardHi,
                        shape: BoxShape.circle,
                        border: Border.all(color: e == _emoji ? RC.brandA : const Color(0x00000000), width: 2),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('НАЗВАНИЕ', style: RT.cap),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              maxLength: 40,
              style: RT.title,
              cursorColor: RC.brandA,
              decoration: _input('Например, «Утренний бег»'),
              onChanged: (_) => setState(() {}),
            ),
            if (com.error != null) Text(com.error!, style: RT.small.copyWith(color: RC.yellow)),
            const SizedBox(height: 8),
            Opacity(
              opacity: _name.text.trim().isEmpty || com.busy ? .4 : 1,
              child: RButton(
                LucideIcons.plus,
                'Создать',
                kind: RButtonKind.primary,
                onTap: _name.text.trim().isEmpty || com.busy
                    ? null
                    : () async {
                        final t = await com.createTeam(_name.text, _emoji);
                        if (t != null && c.mounted) Navigator.of(c).pop(t);
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinSheet extends StatefulWidget {
  final String? demoCode;
  const _JoinSheet({this.demoCode});
  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  late final _code = TextEditingController(text: widget.demoCode ?? '');
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _ok => _code.text.replaceAll(RegExp(r'[\s-]'), '').length == 6;

  @override
  Widget build(BuildContext c) {
    final com = RitmCommunity.I;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: ListenableBuilder(
        listenable: com,
        builder: (c, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Войти по коду', style: RT.h2),
            const SizedBox(height: 6),
            const Text('Код из приглашения — 6 букв и цифр.', style: RT.body),
            const SizedBox(height: 14),
            TextField(
              controller: _code,
              autofocus: widget.demoCode == null,
              textCapitalization: TextCapitalization.characters,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: RT.num.copyWith(letterSpacing: 6),
              cursorColor: RC.brandA,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
              ],
              decoration: _input('КОД'),
              onChanged: (_) => setState(() {}),
            ),
            if (com.error != null) Text(com.error!, style: RT.small.copyWith(color: RC.yellow)),
            const SizedBox(height: 8),
            Opacity(
              opacity: _ok && !com.busy ? 1 : .4,
              child: RButton(
                LucideIcons.logIn,
                'Войти в команду',
                kind: RButtonKind.primary,
                onTap: !_ok || com.busy
                    ? null
                    : () async {
                        final t = await com.join(_code.text);
                        if (t != null && c.mounted) Navigator.of(c).pop(t);
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── экран команды ─────────────────────────

class RitmTeamScreen extends StatefulWidget {
  final RTeam team;
  final bool justCreated;
  final RPeriod? demoPeriod;
  final bool demoScrollFeed;

  /// Открыть сразу вкладку «Чат» (тап по пушу, демо).
  final bool chat;
  final String? demoDraft;
  final bool demoMenu;
  const RitmTeamScreen({
    super.key,
    required this.team,
    this.justCreated = false,
    this.demoPeriod,
    this.demoScrollFeed = false,
    this.chat = false,
    this.demoDraft,
    this.demoMenu = false,
  });
  @override
  State<RitmTeamScreen> createState() => _RitmTeamScreenState();
}

class _RitmTeamScreenState extends State<RitmTeamScreen> {
  RitmCommunity get _c => RitmCommunity.I;
  late RTeam _team = widget.team;
  late RPeriod _period = widget.demoPeriod ?? RPeriod.day;
  late int _tab = widget.chat ? 1 : 0;
  late RMetric _metric = _c.metric;
  List<RBoardRow>? _rows;
  List<RFeedItem>? _feed;
  String? _err;
  final _scroll = ScrollController();
  final _feedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    if (widget.demoMenu) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _menu(context);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await _c.api.leaderboard(_team.id, _period, _metric, _c.today);
      final f = await _c.api.feed(_team.id, _c.today);
      if (!mounted) return;
      setState(() {
        _team = b.team;
        _rows = b.rows;
        _feed = f;
        _err = null;
      });
      if (widget.demoScrollFeed) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          final ctx = _feedKey.currentContext;
          // ignore: use_build_context_synchronously
          if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .02);
        });
      }
    } on RApiError catch (e) {
      if (mounted) setState(() => _err = e.message);
    }
  }

  void _set({RPeriod? p, RMetric? m}) {
    setState(() {
      _period = p ?? _period;
      _metric = m ?? _metric;
      _rows = null;
    });
    unawaited(_load());
  }

  Future<void> _react(RFeedItem x, String e) async {
    final i = _feed!.indexOf(x);
    setState(() => _feed![i] = x.toggled(e));
    try {
      await _c.api.react(_team.id, x.summaryId, x.item, e);
    } catch (_) {
      if (mounted) setState(() => _feed![i] = x);
    }
  }

  Widget _tabs() => _Segment(values: const ['Рейтинг', 'Чат'], index: _tab, onChanged: (i) => setState(() => _tab = i));

  @override
  Widget build(BuildContext c) {
    final now = _now();
    if (_tab == 1) {
      return RPage(
        title: '${_team.emoji}  ${_team.name}',
        action: _IconBtn(LucideIcons.ellipsis, 'Действия с командой', () => _menu(c)),
        body: _ChatView(team: _team, header: _tabs(), demoDraft: widget.demoDraft),
      );
    }
    return RPage(
      title: '${_team.emoji}  ${_team.name}',
      controller: _scroll,
      action: _IconBtn(LucideIcons.ellipsis, 'Действия с командой', () => _menu(c)),
      children: [
        Text('${_members(_team.members)} · код ${_team.code}', style: RT.small),
        const SizedBox(height: 10),
        _tabs(),
        if (widget.justCreated) ...[
          const SizedBox(height: 12),
          RCard(
            color: RC.cardHi,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Команда создана', style: RT.title),
                const SizedBox(height: 6),
                Text('Отправьте друзьям код ${_team.code} — с ним они войдут в команду.', style: RT.body),
                const SizedBox(height: 12),
                Builder(builder: (bc) => RButton(LucideIcons.share, 'Пригласить', kind: RButtonKind.primary, onTap: () => ritmShareInvite(bc, _team))),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        _Segment(
          values: const ['Сегодня', 'Неделя'],
          index: _period == RPeriod.day ? 0 : 1,
          onChanged: (i) => _set(p: i == 0 ? RPeriod.day : RPeriod.week),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 34,
          // Чипы листаются вбок — правый край гаснет, чтобы это было видно.
          child: ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
              stops: [0, .86, 1],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: ListView(
            padding: const EdgeInsets.only(right: 28),
            scrollDirection: Axis.horizontal,
            children: [
              for (final m in RMetric.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Chip(m.title, m == _metric, () => _set(m: m)),
                ),
            ],
          ),
          ),
        ),
        const SizedBox(height: 12),
        RCard(
          pad: const EdgeInsets.symmetric(vertical: 4),
          child: _rows == null
              ? SizedBox(
                  height: 120,
                  child: Center(
                    child: _err != null
                        ? Text(_err!, style: RT.small.copyWith(color: RC.yellow))
                        : const CircularProgressIndicator(color: RC.ink3, strokeWidth: 2),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < _rows!.length; i++) ...[
                      if (i > 0) const Divider(height: 1, thickness: 1, indent: 92, color: RC.line),
                      _BoardRow(row: _rows![i], metric: _metric, photo: _photoOf(_rows![i])),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Text(_boardNote(), style: RT.small),
        const SizedBox(height: RS.sectionGap),
        Text('ЛЕНТА', key: _feedKey, style: RT.cap),
        const SizedBox(height: 10),
        if (_feed != null && _feed!.isEmpty)
          const RCard(child: Text('Пока тихо. Здесь появятся итоги ночи и тренировки участников.', style: RT.body)),
        for (final x in _feed ?? const <RFeedItem>[]) ...[
          _FeedCard(item: x, now: now, onReact: (e) => _react(x, e), photo: _photoOfId(x.userId, x.me)),
          const SizedBox(height: RS.cardGap),
        ],
        const SizedBox(height: 60),
      ],
    );
  }

  String _boardNote() {
    final what = switch ((_period, _metric)) {
      (RPeriod.day, RMetric.strainWeek) => 'Сумма нагрузки за 7 дней; стрелка — к прошлой неделе.',
      (RPeriod.week, RMetric.strainWeek) => 'Сумма нагрузки за 7 дней; стрелка — к прошлой неделе.',
      (RPeriod.day, _) => 'За сегодня; стрелка — к вчерашнему дню.',
      (RPeriod.week, _) => 'Среднее за 7 дней; стрелка — к прошлой неделе.',
    };
    return '$what Итоги приходят раз в час и после ночи. «Скрыто» — участник не публикует эту метрику.';
  }

  ImageProvider? _photoOf(RBoardRow r) => _photoOfId(r.userId, r.me, has: r.hasPhoto);

  ImageProvider? _photoOfId(int uid, bool me, {bool? has}) {
    if (me) {
      final p = RitmAvatar.path.value;
      if (p != null && !kIsWeb) return ResizeImage(FileImage(File(p)), width: 108);
      return null;
    }
    if (has != true && !(_rows?.any((r) => r.userId == uid && r.hasPhoto) ?? false)) return null;
    final url = _c.api.photoUrl(uid);
    return url == null ? null : NetworkImage(url, headers: _c.api.authHeaders);
  }

  Future<void> _toggleMute(BuildContext sc) async {
    final next = !(_ChatView.muted[_team.id] ?? false);
    Navigator.of(sc).pop();
    try {
      await _c.api.setMute(_team.id, next);
      _ChatView.muted[_team.id] = next;
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(next ? 'Уведомления этой команды выключены' : 'Уведомления включены')),
        );
      }
    } on RApiError catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _menu(BuildContext c) {
    showRSheet<void>(
      c,
      (sc) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_team.name, style: RT.h2),
          const SizedBox(height: 12),
          RGroup(rows: [
            RRow(
              icon: LucideIcons.share,
              title: 'Пригласить друга',
              onTap: () {
                Navigator.of(sc).pop();
                ritmShareInvite(c, _team);
              },
            ),
            RRow(
              icon: LucideIcons.copy,
              title: 'Скопировать код',
              sub: _team.code,
              onTap: () {
                Clipboard.setData(ClipboardData(text: _team.code));
                Navigator.of(sc).pop();
                ScaffoldMessenger.maybeOf(c)?.showSnackBar(const SnackBar(content: Text('Код скопирован')));
              },
            ),
            RRow(
              icon: (_ChatView.muted[_team.id] ?? false) ? LucideIcons.bellOff : LucideIcons.bell,
              title: 'Уведомления о сообщениях',
              sub: (_ChatView.muted[_team.id] ?? false) ? 'выключены для этой команды' : 'приходят, когда чат закрыт',
              chevron: false,
              trailing: RSwitch(value: !(_ChatView.muted[_team.id] ?? false), onChanged: (_) => _toggleMute(sc)),
              onTap: () => _toggleMute(sc),
            ),
            RRow(
              icon: LucideIcons.logOut,
              iconColor: RC.red,
              title: 'Выйти из команды',
              onTap: () async {
                Navigator.of(sc).pop();
                final ok = await ritmConfirm(
                  c,
                  title: 'Выйти из команды?',
                  text: 'Вы пропадёте из рейтинга «${_team.name}». Вернуться можно по коду.',
                  yes: 'Выйти',
                );
                if (ok && await _c.leave(_team.id) && c.mounted) Navigator.of(c).pop();
              },
            ),
          ]),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final List<String> values;
  final int index;
  final ValueChanged<int> onChanged;
  const _Segment({required this.values, required this.index, required this.onChanged});
  @override
  Widget build(BuildContext c) => Container(
    height: 36,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: RC.card, borderRadius: BorderRadius.circular(18)),
    child: Row(
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: Semantics(
              button: true,
              selected: i == index,
              label: values[i],
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == index ? RC.cardHi : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Text(
                    values[i].toUpperCase(),
                    style: RT.cap.copyWith(fontSize: 11, color: i == index ? RC.ink : RC.ink3),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  final String text;
  final bool on;
  final VoidCallback onTap;
  const _Chip(this.text, this.on, this.onTap);
  @override
  Widget build(BuildContext c) => Semantics(
    button: true,
    selected: on,
    label: text,
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? RC.ink : RC.card,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Text(text, style: RT.label.copyWith(color: on ? RC.bg : RC.ink2)),
      ),
    ),
  );
}

class _PersonAvatar extends StatelessWidget {
  final String name;
  final String? emoji;
  final ImageProvider? photo;
  final double size;
  const _PersonAvatar({required this.name, this.emoji, this.photo, this.size = 36});
  @override
  Widget build(BuildContext c) {
    final p = photo;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: RC.cardHi, shape: BoxShape.circle),
      child: p != null
          ? Image(image: p, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => _fb())
          : _fb(),
    );
  }

  Widget _fb() => emoji != null && emoji!.isNotEmpty
      ? Text(emoji!, style: TextStyle(fontSize: size * .5))
      : Text(
          name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase(),
          style: RT.title.copyWith(fontSize: size * .42),
        );
}

class _BoardRow extends StatelessWidget {
  final RBoardRow row;
  final RMetric metric;
  final ImageProvider? photo;
  const _BoardRow({required this.row, required this.metric, this.photo});

  @override
  Widget build(BuildContext c) {
    final v = row.value, p = row.prev;
    final up = v != null && p != null && v > p + (metric.isStrain ? .05 : .5);
    final down = v != null && p != null && v < p - (metric.isStrain ? .05 : .5);
    final valueText = row.hidden ? 'скрыто' : (v == null ? 'нет данных' : ritmMetricText(metric, v));
    return Semantics(
      label: '${row.place ?? 'без места'}, ${row.name}${row.me ? ', вы' : ''}: $valueText',
      excludeSemantics: true,
      child: Container(
        height: 60,
        color: row.me ? const Color(0x0DFFFFFF) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                row.place?.toString() ?? '—',
                style: RT.label.copyWith(color: row.place != null && row.place! <= 3 ? RC.ink : RC.ink3, fontSize: 15),
              ),
            ),
            const SizedBox(width: 8),
            _PersonAvatar(name: row.name, emoji: row.emoji, photo: photo),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: row.name, style: RT.title.copyWith(fontSize: 15)),
                  if (row.me) TextSpan(text: '  вы', style: RT.small.copyWith(color: RC.brandA)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              valueText,
              style: row.hidden || v == null
                  ? RT.label.copyWith(color: RC.ink3)
                  : RT.num.copyWith(fontSize: 18, color: ritmMetricColor(metric, v)),
            ),
            SizedBox(
              width: 22,
              child: up
                  ? const Icon(LucideIcons.arrowUp, size: 14, color: RC.ink2)
                  : down
                      ? const Icon(LucideIcons.arrowDown, size: 14, color: RC.ink3)
                      : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedCard extends StatelessWidget {
  final RFeedItem item;
  final DateTime now;
  final ValueChanged<String> onReact;
  final ImageProvider? photo;
  const _FeedCard({required this.item, required this.now, required this.onReact, this.photo});

  @override
  Widget build(BuildContext c) {
    final x = item;
    final icon = x.kind == 'workout' ? LucideIcons.activity : LucideIcons.moon;
    return RCard(
      pad: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PersonAvatar(name: x.name, emoji: x.emoji, photo: photo, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ritmFeedText(x), style: RT.label.copyWith(fontSize: 14, height: 1.3)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(icon, size: 12, color: RC.ink3),
                        const SizedBox(width: 4),
                        Text(
                          '${x.kind == 'workout' ? 'тренировка' : 'итоги ночи'} · ${ritmAgo(x.at, now)}',
                          style: RT.small,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final e in kRitmReactions) ...[
                _ReactChip(e, x.reactions[e] ?? const RReact(0, false), () => onReact(e)),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ReactChip extends StatelessWidget {
  final String emoji;
  final RReact r;
  final VoidCallback onTap;
  const _ReactChip(this.emoji, this.r, this.onTap);
  @override
  Widget build(BuildContext c) => Semantics(
    button: true,
    selected: r.mine,
    label: 'Реакция $emoji, ${r.n}',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: r.mine ? RC.brandA.withValues(alpha: .18) : RC.cardHi,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: r.mine ? RC.brandA : const Color(0x00000000)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 14)),
            if (r.n > 0) ...[
              const SizedBox(width: 5),
              Text('${r.n}', style: RT.label.copyWith(color: r.mine ? RC.ink : RC.ink2)),
            ],
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────── настройки ─────────────────────────

/// Фото профиля для сервера: квадрат 256×256 PNG (≤ 300 КБ) или null.
Future<List<int>?> ritmAvatarBytes() async {
  final p = RitmAvatar.path.value;
  if (p == null) return null;
  try {
    final png = await RitmAvatar.squareCrop(await File(p).readAsBytes(), 256);
    return png != null && png.length <= 300 * 1024 ? png : null;
  } catch (_) {
    return null;
  }
}

/// Подтверждение (тёмный диалог). true — нажали [yes].
Future<bool> ritmConfirm(
  BuildContext c, {
  required String title,
  required String text,
  required String yes,
  bool danger = true,
}) async =>
    await showDialog<bool>(
      context: c,
      builder: (dc) => AlertDialog(
        backgroundColor: RC.cardHi,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(RS.rCard)),
        title: Text(title, style: RT.title),
        content: Text(text, style: RT.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(false),
            child: Text('Отмена', style: RT.label.copyWith(fontSize: 15, color: RC.ink2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dc).pop(true),
            child: Text(yes, style: RT.label.copyWith(fontSize: 15, color: danger ? RC.red : RC.ink)),
          ),
        ],
      ),
    ) ??
    false;

class RitmCommunitySettings extends StatefulWidget {
  final bool demoDelete;
  const RitmCommunitySettings({super.key, this.demoDelete = false});
  @override
  State<RitmCommunitySettings> createState() => _RitmCommunitySettingsState();
}

class _RitmCommunitySettingsState extends State<RitmCommunitySettings> {
  RitmCommunity get _c => RitmCommunity.I;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.demoDelete) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        unawaited(_delete(context));
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _set(RSharing s) async {
    List<int>? photo;
    if (s.photo && !(_c.me?.sharing.photo ?? false)) {
      photo = await ritmAvatarBytes();
    }
    await _c.setSharing(s, photo: photo);
  }

  Future<void> _delete(BuildContext c) async {
    final ok = await ritmConfirm(
      c,
      title: 'Удалить аккаунт?',
      text: 'С сервера сразу удалятся ваш профиль, итоги дней, реакции, согласие и участие во всех командах. '
          'Данные браслета на этом телефоне останутся. Отменить нельзя.',
      yes: 'Удалить',
    );
    if (!ok || widget.demoDelete) return;
    if (await _c.deleteAccount() && c.mounted) {
      Navigator.of(c).pop();
      ScaffoldMessenger.maybeOf(c)?.showSnackBar(const SnackBar(content: Text('Аккаунт удалён')));
    }
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(
    listenable: _c,
    builder: (c, _) {
      final me = _c.me;
      final s = me?.sharing ?? const RSharing();
      Widget sw(IconData i, String t, String sub, bool v, RSharing Function(bool) f) => RRow(
        icon: i,
        title: t,
        sub: sub,
        trailing: RSwitch(value: v, onChanged: _c.busy ? null : (x) => _set(f(x))),
      );
      return RPage(
        title: 'Настройки сообщества',
        controller: _scroll,
        children: [
          RGroup(
            title: 'Что видят команды',
            rows: [
              sw(LucideIcons.moon, 'Сон', 'процент от потребности', s.sleep, (x) => s.copyWith(sleep: x)),
              sw(LucideIcons.heartPulse, 'Восстановление', 'процент за утро', s.recovery, (x) => s.copyWith(recovery: x)),
              sw(LucideIcons.flame, 'Нагрузка', 'за день и за неделю', s.strain, (x) => s.copyWith(strain: x)),
              sw(LucideIcons.activity, 'Тренировки', 'тип, минуты и нагрузка — в ленту', s.workouts, (x) => s.copyWith(workouts: x)),
              sw(LucideIcons.image, 'Фото профиля', 'иначе — первая буква имени', s.photo, (x) => s.copyWith(photo: x)),
            ],
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Выключенное не уходит на сервер, а уже отправленное стирается. Пульс, ВСР, ЭКГ, стресс и биовозраст не отправляются никогда.',
              style: RT.small,
            ),
          ),
          const SizedBox(height: RS.sectionGap),
          RGroup(
            title: 'Профиль',
            rows: [
              RRow(
                icon: LucideIcons.user,
                title: me?.name.isNotEmpty == true ? me!.name : 'Без имени',
                sub: 'имя из профиля «Ритма» (Ещё → Профиль)',
                chevron: false,
              ),
            ],
          ),
          const SizedBox(height: RS.sectionGap),
          RGroup(
            title: 'Данные',
            rows: [
              RRow(
                icon: LucideIcons.shieldCheck,
                title: 'Согласие на обработку',
                sub: me?.consentVersion == null ? 'не дано' : 'дано · версия ${ritmConsentDate(me!.consentVersion!)}',
                onTap: () => Navigator.of(c).push(ritmRoute(const RitmConsentScreen(readOnly: true))),
              ),
              RRow(
                icon: LucideIcons.fileText,
                title: 'Политика конфиденциальности',
                onTap: () => Navigator.of(c).push(ritmRoute(const RitmPrivacyScreen())),
              ),
            ],
          ),
          const SizedBox(height: RS.sectionGap),
          RGroup(
            rows: [
              RRow(
                icon: LucideIcons.logOut,
                title: 'Выйти',
                sub: 'аккаунт и команды сохранятся',
                onTap: () async {
                  await _c.signOut();
                  if (c.mounted) Navigator.of(c).pop();
                },
              ),
              RRow(
                icon: LucideIcons.trash2,
                iconColor: RC.red,
                title: 'Удалить аккаунт',
                sub: 'всё с сервера — сразу',
                onTap: () => _delete(c),
              ),
            ],
          ),
          if (_c.error != null) ...[
            const SizedBox(height: 12),
            Text(_c.error!, style: RT.small.copyWith(color: RC.yellow)),
          ],
        ],
      );
    },
  );
}

// ───────────────────────── чат команды (B6) ─────────────────────────

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _ChatView extends StatefulWidget {
  final RTeam team;
  final Widget header;
  final String? demoDraft;
  const _ChatView({required this.team, required this.header, this.demoDraft});

  /// «Без звука» по командам (с сервера, при открытии чата).
  static final Map<int, bool> muted = {};

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  RitmCommunity get _c => RitmCommunity.I;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<RMessage>? _items;
  String? _err;
  bool _sending = false;
  StreamSubscription<RChatEvent>? _live;

  @override
  void initState() {
    super.initState();
    _load();
    _live = _c.api.chat(widget.team.id, myId: _c.me?.id).listen(_onEvent);
    if (widget.demoDraft != null) {
      _text.text = widget.demoDraft!;
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) _send();
      });
    }
  }

  @override
  void dispose() {
    _live?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (xs, m) = await _c.api.messages(widget.team.id);
      _ChatView.muted[widget.team.id] = m;
      if (!mounted) return;
      setState(() {
        _items = xs;
        _err = null;
      });
      _toEnd();
    } on RApiError catch (e) {
      if (mounted) setState(() => _err = e.message);
    }
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  void _onEvent(RChatEvent e) {
    final xs = [...?_items];
    if (e.message case final m?) {
      if (xs.any((x) => x.id == m.id)) return;
      xs.add(m);
    } else if (e.deletedId case final id?) {
      final i = xs.indexWhere((x) => x.id == id);
      if (i < 0) return;
      xs[i] = xs[i].gone();
    }
    setState(() => _items = xs);
    _toEnd();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await _c.api.sendMessage(widget.team.id, t);
      _text.clear();
      _onEvent((message: m, deletedId: null));
    } on RApiError catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(RMessage m) async {
    final ok = await ritmConfirm(context, title: 'Удалить сообщение?', text: 'Текст исчезнет у всех участников команды.', yes: 'Удалить');
    if (!ok) return;
    try {
      await _c.api.deleteMessage(widget.team.id, m.id);
      _onEvent((message: null, deletedId: m.id));
    } on RApiError catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext c) {
    final xs = _items;
    final bottom = MediaQuery.paddingOf(c).bottom;
    return Column(
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: widget.header),
        Expanded(
          child: xs == null
              ? Center(
                  child: _err != null
                      ? Text(_err!, style: RT.small.copyWith(color: RC.yellow))
                      : const CircularProgressIndicator(color: RC.ink3, strokeWidth: 2),
                )
              : xs.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Сообщений пока нет. Напишите первым — увидят все участники команды.',
                      textAlign: TextAlign.center,
                      style: RT.body,
                    ),
                  ),
                )
              : ListView.builder(
                  key: const Key('chat.list'),
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: xs.length,
                  itemBuilder: (_, i) => _Bubble(
                    m: xs[i],
                    first: i == 0 || xs[i - 1].userId != xs[i].userId,
                    onDelete: xs[i].me && !xs[i].deleted ? () => _delete(xs[i]) : null,
                  ),
                ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + bottom),
          decoration: const BoxDecoration(
            color: RC.bgTop,
            border: Border(top: BorderSide(color: RC.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('chat.input'),
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 500,
                  buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
                      currentLength > 400 ? Text('$currentLength/500', style: RT.micro) : null,
                  style: RT.body.copyWith(color: RC.ink),
                  cursorColor: RC.brandA,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: _input('Сообщение'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 6),
              Semantics(
                button: true,
                label: 'Отправить',
                excludeSemantics: true,
                child: InkResponse(
                  key: const Key('chat.send'),
                  onTap: _text.text.trim().isEmpty || _sending ? null : _send,
                  radius: 24,
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _text.text.trim().isEmpty ? RC.cardHi : RC.brandA,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(LucideIcons.arrowUp, size: 22, color: _text.text.trim().isEmpty ? RC.ink3 : RC.bg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final RMessage m;
  final bool first;
  final VoidCallback? onDelete;
  const _Bubble({required this.m, required this.first, this.onDelete});

  @override
  Widget build(BuildContext c) {
    final mine = m.me;
    final bubble = GestureDetector(
      onLongPress: onDelete,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(c).width * .72),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF1F3A35) : RC.card,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (first && !mine) Text(m.name, style: RT.label.copyWith(color: RC.brandA)),
            Text(
              m.deleted ? 'Сообщение удалено' : (m.text ?? ''),
              style: m.deleted
                  ? RT.body.copyWith(color: RC.ink3, fontStyle: FontStyle.italic)
                  : RT.body.copyWith(color: RC.ink),
            ),
            const SizedBox(height: 2),
            Text(_hm(m.at), style: RT.micro),
          ],
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: first ? 10 : 3),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            first ? _PersonAvatar(name: m.name, emoji: m.emoji, size: 28) : const SizedBox(width: 28),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubble),
          if (onDelete != null) ...[
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: 'Удалить сообщение',
              excludeSemantics: true,
              child: InkResponse(
                onTap: onDelete,
                radius: 18,
                child: const SizedBox(
                  width: 28,
                  height: 36,
                  child: Icon(LucideIcons.trash2, size: 15, color: RC.ink3),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
