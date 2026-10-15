// «Ритм» — вход в «Сообщество» (Sign in with Apple), экран согласия
// (152-ФЗ: данные о здоровье — специальная категория) и политика.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'ritm_community_api.dart';
import 'ritm_ui.dart';
import '../ui2/screens/home_screen.dart' show repoOf;

/// «2026-10-15» → «15.10.2026».
String ritmConsentDate(String v) {
  final p = v.split('-');
  return p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : v;
}

/// Имя из профиля «Ритма» (локальная база), если есть.
Future<String?> ritmLocalName(BuildContext c) async {
  try {
    final repo = repoOf(c);
    if (repo == null) return null;
    final p = await repo.getProfile();
    final n = (p['name'] ?? '').toString().trim();
    return n.isEmpty ? null : n;
  } catch (_) {
    return null;
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();
  @override
  Widget build(BuildContext c) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const RitmMark(size: 30),
      const SizedBox(width: 10),
      Text('Ритм', style: RT.h1.copyWith(fontSize: 30, letterSpacing: -.6)),
    ],
  );
}

// ───────────────────────── вход ─────────────────────────

class RitmSignInScreen extends StatefulWidget {
  const RitmSignInScreen({super.key});
  @override
  State<RitmSignInScreen> createState() => _RitmSignInScreenState();
}

class _RitmSignInScreenState extends State<RitmSignInScreen> {
  RitmCommunity get _c => RitmCommunity.I;
  String? _err;

  Future<void> _apple() async {
    setState(() => _err = null);
    final n = ritmNonce();
    AuthorizationCredentialAppleID cred;
    try {
      cred = await SignInWithApple.getAppleIDCredential(
        scopes: const [AppleIDAuthorizationScopes.fullName],
        nonce: n.hashed,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled && mounted) {
        setState(() => _err = 'Apple не выполнил вход — попробуйте ещё раз');
      }
      return;
    } catch (_) {
      if (mounted) setState(() => _err = 'Вход через Apple недоступен на этом устройстве');
      return;
    }
    final token = cred.identityToken;
    if (token == null) {
      setState(() => _err = 'Apple не прислал подтверждение — попробуйте ещё раз');
      return;
    }
    if (!mounted) return;
    final local = await ritmLocalName(context);
    final ok = await _c.signInApple(token, n.raw, appleName: cred.givenName, localName: local);
    _after(ok);
  }

  Future<void> _test() async {
    final local = mounted ? await ritmLocalName(context) : null;
    _after(await _c.signInTest(local ?? 'Тест'));
  }

  void _after(bool ok) {
    if (!mounted) return;
    if (!ok) {
      setState(() => _err = _c.error);
      return;
    }
    final nav = Navigator.of(context);
    if (_c.stage == RStage.needsConsent) {
      nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => const RitmConsentScreen()));
    } else {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(
    listenable: _c,
    builder: (c, _) => RPage(
      title: 'Вход',
      children: [
        const SizedBox(height: 12),
        const Align(alignment: Alignment.centerLeft, child: _Wordmark()),
        const SizedBox(height: 20),
        const Text('Сообщество', style: RT.h1),
        const SizedBox(height: 8),
        const Text(
          'Соревнуйтесь с друзьями и семьёй: общий рейтинг и лента тренировок.',
          style: RT.body,
        ),
        const SizedBox(height: 20),
        const _Bullet(LucideIcons.trophy, 'Рейтинг команды', 'по сну, восстановлению и нагрузке — за день и за неделю'),
        const _Bullet(LucideIcons.shieldCheck, 'Только итоги дня', 'пульс, ВСР, ЭКГ, стресс и биовозраст остаются на телефоне'),
        const _Bullet(LucideIcons.server, 'Сервер в России', 'удалить аккаунт и всё с сервера — одной кнопкой'),
        const SizedBox(height: 28),
        SizedBox(
          height: 50,
          child: SignInWithAppleButton(
            text: 'Вход с Apple',
            style: SignInWithAppleButtonStyle.white,
            borderRadius: const BorderRadius.all(Radius.circular(RS.rTile)),
            onPressed: _c.busy ? () {} : _apple,
          ),
        ),
        if (kRitmTestLogin) ...[
          const SizedBox(height: 12),
          RButton(LucideIcons.bug, 'Тестовый вход (отладка)', kind: RButtonKind.ghost, onTap: _c.busy ? null : _test),
        ],
        const SizedBox(height: 14),
        const Text(
          'Apple сообщит «Ритму» только скрытый идентификатор. Имя в командах — из вашего профиля «Ритма», почта не нужна.',
          style: RT.small,
        ),
        if (_err != null) ...[
          const SizedBox(height: 12),
          Text(_err!, style: RT.small.copyWith(color: RC.yellow)),
        ],
      ],
    ),
  );
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  const _Bullet(this.icon, this.title, this.text);
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: RC.card, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: RC.brandA),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: RT.title.copyWith(fontSize: 15)),
              const SizedBox(height: 2),
              Text(text, style: RT.small.copyWith(color: RC.ink2, fontSize: 13)),
            ],
          ),
        ),
      ],
    ),
  );
}

// ───────────────────────── согласие ─────────────────────────

/// Текст согласия: что, где, кому, как удалить (ТЗ §7).
const kRitmConsentBlocks = <(String, String)>[
  (
    'ЧТО ОТПРАВЛЯЕТСЯ',
    'Итоги дня: оценка сна (%), восстановление (%), нагрузка за день и за неделю. '
        'Если включите — тренировки: тип, минуты, нагрузка. Имя из профиля «Ритма» и, по отдельному переключателю, фото. '
        'Сообщения, которые вы пишете в чат команды, и токен телефона для уведомлений. '
        'Для подтверждения согласия — его версия, время и IP-адрес.\n'
        'Пульс, ВСР, ЭКГ, стресс, биовозраст, посекундные записи браслета и данные «Здоровья» не отправляются никогда.',
  ),
  (
    'ГДЕ ХРАНИТСЯ',
    'На сервере «Ритма» в дата-центре в России. Ночная резервная копия — там же, хранится 14 дней.',
  ),
  (
    'КОМУ ВИДНО',
    'Только участникам ваших команд. Что публиковать, вы выбираете в настройках сообщества; выключенное не уходит на сервер.',
  ),
  (
    'КАК УДАЛИТЬ',
    'Сообщество → Настройки → «Удалить аккаунт»: профиль, итоги, реакции и согласие удаляются с сервера сразу. '
        'Это же — отзыв согласия.',
  ),
];

class RitmConsentScreen extends StatefulWidget {
  final bool readOnly;
  final bool demoChecked;
  const RitmConsentScreen({super.key, this.readOnly = false, this.demoChecked = false});
  @override
  State<RitmConsentScreen> createState() => _RitmConsentScreenState();
}

class _RitmConsentScreenState extends State<RitmConsentScreen> {
  RitmCommunity get _c => RitmCommunity.I;
  late bool _processing = widget.demoChecked;
  late bool _team = widget.demoChecked;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.demoChecked) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _ok => _processing && _team && !_c.busy;

  Future<void> _go() async {
    final ok = await _c.acceptConsent(processing: _processing, team: _team);
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(
    listenable: _c,
    builder: (c, _) => RPage(
      title: 'Согласие на обработку данных',
      controller: _scroll,
      children: [
        const Align(alignment: Alignment.centerLeft, child: _Wordmark()),
        const SizedBox(height: 12),
        const Text(
          'Сон, восстановление и нагрузка — это сведения о здоровье. Чтобы показывать их вашим командам, нужно ваше согласие.',
          style: RT.body,
        ),
        const SizedBox(height: 16),
        for (final b in kRitmConsentBlocks) ...[
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.$1, style: RT.cap),
                const SizedBox(height: 8),
                Text(b.$2, style: RT.body.copyWith(color: RC.ink)),
              ],
            ),
          ),
          const SizedBox(height: RS.cardGap),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const RitmPrivacyScreen())),
            icon: const Icon(LucideIcons.fileText, size: 16, color: RC.brandA),
            label: Text('Политика конфиденциальности', style: RT.label.copyWith(fontSize: 15, color: RC.brandA)),
          ),
        ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 8),
          _Check(
            key: const Key('consent.processing'),
            value: _processing,
            text: 'Согласен на обработку моих данных о здоровье (сон, восстановление, нагрузка, тренировки) для работы сообщества',
            onChanged: (v) => setState(() => _processing = v),
          ),
          const SizedBox(height: 10),
          _Check(
            key: const Key('consent.team'),
            value: _team,
            text: 'Согласен показывать эти итоги участникам моих команд',
            onChanged: (v) => setState(() => _team = v),
          ),
          const SizedBox(height: 18),
          Opacity(
            opacity: _ok ? 1 : .4,
            child: RButton(
              null,
              'Продолжить',
              key: const Key('consent.go'),
              kind: RButtonKind.primary,
              onTap: _ok ? _go : null,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _processing && _team ? 'Версия согласия ${ritmConsentDate(kRitmConsentVersion)}' : 'Отметьте обе галочки, чтобы продолжить',
            style: RT.small,
          ),
          if (_c.error != null) ...[
            const SizedBox(height: 8),
            Text(_c.error!, style: RT.small.copyWith(color: RC.yellow)),
          ],
        ] else
          Text(
            _c.me?.consentVersion == null
                ? 'Согласие не дано'
                : 'Вы дали согласие (версия ${ritmConsentDate(_c.me!.consentVersion!)}). Отозвать — «Удалить аккаунт».',
            style: RT.small,
          ),
      ],
    ),
  );
}

class _Check extends StatelessWidget {
  final bool value;
  final String text;
  final ValueChanged<bool> onChanged;
  const _Check({super.key, required this.value, required this.text, required this.onChanged});
  @override
  Widget build(BuildContext c) => Semantics(
    checked: value,
    label: text,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: RC.card,
          borderRadius: BorderRadius.circular(RS.rTile),
          border: Border.all(color: value ? RC.brandA : RC.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: value ? RC.brandA : const Color(0x00000000),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: value ? RC.brandA : RC.ink3, width: 2),
              ),
              child: value ? const Icon(LucideIcons.check, size: 16, color: RC.bg) : null,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: RT.body.copyWith(color: RC.ink))),
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────── политика ─────────────────────────

const kRitmPrivacy = <(String, String)>[
  (
    'Кто обрабатывает',
    'Организатор закрытого сообщества друзей «Ритм». Вопросы и отзыв согласия — «Ещё → О приложении → Сообщить о проблеме» или удалением аккаунта.',
  ),
  (
    'Какие данные',
    'Идентификатор Apple (без почты), имя из профиля «Ритма», по желанию — фото; итоги дня: сон %, восстановление %, нагрузка за день и неделю, тренировки (тип, минуты, нагрузка) — только включённые вами; ваши реакции и сообщения чата команды; токен телефона для уведомлений; версия, время и IP-адрес согласия.',
  ),
  (
    'Зачем',
    'Чтобы показывать рейтинг, ленту и чат участникам ваших команд и присылать уведомления о новых сообщениях (через сервис уведомлений Apple — только имя автора и текст). Реклама, продажа и передача третьим лицам — нет.',
  ),
  (
    'Где и сколько',
    'Сервер и резервные копии — в России. Данные хранятся, пока есть аккаунт. После удаления аккаунта — стираются сразу, из резервных копий — в течение 14 дней.',
  ),
  (
    'Что остаётся на телефоне',
    'Всё остальное: пульс, ВСР, ЭКГ, стресс, биовозраст, сон по стадиям, данные «Здоровья» — сервер их не получает.',
  ),
  (
    'Ваши права',
    'Узнать, исправить, скрыть (переключатели публикации), удалить (кнопка «Удалить аккаунт»), отозвать согласие.',
  ),
];

class RitmPrivacyScreen extends StatelessWidget {
  const RitmPrivacyScreen({super.key});
  @override
  Widget build(BuildContext c) => RPage(
    title: 'Политика конфиденциальности',
    children: [
      for (final b in kRitmPrivacy) ...[
        Text(b.$1, style: RT.title),
        const SizedBox(height: 6),
        Text(b.$2, style: RT.body),
        const SizedBox(height: 18),
      ],
      Text('Редакция от ${ritmConsentDate(kRitmConsentVersion)}', style: RT.small),
    ],
  );
}

/// Для тестов: короткий доступ к таймеру отправки итогов.
@visibleForTesting
void ritmCommunityAuthTouch() => unawaited(Future<void>.value());
