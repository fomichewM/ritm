// «Ритм» B6 — чат команды, онбординг (U7), «О приложении».

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ritm/ritm_community.dart';
import 'package:openstrap_edge/ritm/ritm_community_api.dart';
import 'package:openstrap_edge/ritm/ritm_onboarding.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/prefs.dart';

class _ChatApi extends RitmCommunityApi {
  final live = StreamController<RChatEvent>.broadcast();
  final sent = <String>[];
  final deleted = <int>[];
  final mutes = <bool>[];
  var _id = 10;
  final _t = DateTime(2026, 10, 16, 9);
  late final items = [
    RMessage(id: 1, teamId: 5, userId: 2, name: 'Женя', text: 'Бежим в 7?', at: _t),
    RMessage(id: 2, teamId: 5, userId: 3, name: 'Оля', deleted: true, at: _t),
    RMessage(id: 3, teamId: 5, userId: 1, name: 'Миша', text: 'Да', me: true, at: _t),
  ];

  @override
  Future<(List<RMessage>, bool)> messages(int teamId, {int? before}) async => (items, false);
  @override
  Future<RMessage> sendMessage(int teamId, String text) async {
    sent.add(text);
    return RMessage(id: ++_id, teamId: teamId, userId: 1, name: 'Миша', text: text, me: true, at: _t);
  }

  @override
  Future<void> deleteMessage(int teamId, int id) async => deleted.add(id);
  @override
  Future<void> setMute(int teamId, bool muted) async => mutes.add(muted);
  @override
  Stream<RChatEvent> chat(int teamId, {int? myId}) => live.stream;

  // B5 — не нужны в этих тестах.
  @override
  Future<RAuth> signInApple(String t, String n, String? name) => throw UnimplementedError();
  @override
  Future<RAuth> signInTest(String name) async => const RAuth('a', 'r', RMe(id: 1, name: 'Миша', needsConsent: false));
  @override
  Future<RMe> me() async => const RMe(id: 1, name: 'Миша', needsConsent: false);
  @override
  Future<RMe> putMe({String? name}) => me();
  @override
  Future<RMe> consent(String version) => me();
  @override
  Future<RMe> sharing(RSharing s) => me();
  @override
  Future<void> deleteMe() async {}
  @override
  Future<void> uploadPhoto(List<int> bytes) async {}
  @override
  Future<List<RTeam>> teams(RMetric metric, String date) async => const [];
  @override
  Future<RTeam> createTeam(String name, String emoji) => throw UnimplementedError();
  @override
  Future<RTeam> join(String code) => throw UnimplementedError();
  @override
  Future<void> leave(int teamId) async {}
  @override
  Future<RBoard> leaderboard(int teamId, RPeriod p, RMetric m, String date) async => RBoard(_team, const []);
  @override
  Future<List<RFeedItem>> feed(int teamId, String date) async => const [];
  @override
  Future<bool> react(int teamId, int summaryId, int item, String emoji) async => true;
  @override
  Future<void> putSummary(RDaySummary s, RSharing sharing) async {}
}

const _team = RTeam(id: 5, name: 'Бег', emoji: '🏃', code: 'ABC234', members: 3);

void main() {
  test('сообщение из JSON сервера: удалённое — без текста, «моё» по id', () {
    final m = RMessage.fromJson({
      'id': 7,
      'team_id': 5,
      'user_id': 2,
      'name': 'Женя',
      'text': null,
      'deleted': true,
      'at': '2026-10-16T06:00:00+00:00',
    }, myId: 2);
    expect((m.deleted, m.text, m.me, m.teamId), (true, null, true, 5));
    expect(m.at.isUtc, isFalse);
  });

  group('чат команды', () {
    late _ChatApi api;
    setUp(() async {
      api = _ChatApi();
      final c = RitmCommunity(api: api, store: RitmMemoryTokenStore(), persist: false);
      await c.signInTest('Миша');
      RitmCommunity.I = c;
    });

    Future<void> open(WidgetTester t, {double w = 393}) async {
      await t.binding.setSurfaceSize(Size(w, 852));
      await t.pumpWidget(const MaterialApp(home: RitmTeamScreen(team: _team, chat: true)));
      await t.pumpAndSettle();
    }

    testWidgets('история, «Сообщение удалено», отправка и живое сообщение', (t) async {
      await open(t);
      expect(find.text('Бежим в 7?'), findsOneWidget);
      expect(find.text('Сообщение удалено'), findsOneWidget);
      expect(find.text('РЕЙТИНГ'), findsOneWidget);
      await t.enterText(find.byKey(const Key('chat.input')), '  Я с вами  ');
      await t.pump();
      await t.tap(find.byKey(const Key('chat.send')));
      await t.pumpAndSettle();
      expect(api.sent, ['Я с вами']);
      expect(find.text('Я с вами'), findsOneWidget);
      api.live.add((
        message: RMessage(id: 50, teamId: 5, userId: 2, name: 'Женя', text: 'Отлично!', at: DateTime(2026, 10, 16, 9, 5)),
        deletedId: null,
      ));
      await t.pumpAndSettle();
      expect(find.text('Отлично!'), findsOneWidget);
      api.live.add((message: null, deletedId: 1));
      await t.pumpAndSettle();
      expect(find.text('Бежим в 7?'), findsNothing);
      expect(find.text('Сообщение удалено'), findsNWidgets(2));
      expect(t.takeException(), isNull);
      await t.binding.setSurfaceSize(null);
    });

    testWidgets('удалить можно только своё и после подтверждения', (t) async {
      await open(t);
      final del = find.byIcon(LucideIcons.trash2);
      expect(del, findsOneWidget, reason: 'кнопка только у своего сообщения');
      await t.tap(del);
      await t.pumpAndSettle();
      expect(find.text('Удалить сообщение?'), findsOneWidget);
      await t.tap(find.text('Отмена'));
      await t.pumpAndSettle();
      expect(api.deleted, isEmpty);
      await t.tap(del);
      await t.pumpAndSettle();
      await t.tap(find.text('Удалить'));
      await t.pumpAndSettle();
      expect(api.deleted, [3]);
      expect(find.text('Да'), findsNothing);
      await t.binding.setSurfaceSize(null);
    });

    testWidgets('пустая строка не отправляется; 320 pt без переполнения', (t) async {
      await open(t, w: 320);
      await t.enterText(find.byKey(const Key('chat.input')), '    ');
      await t.pump();
      await t.tap(find.byKey(const Key('chat.send')));
      await t.pumpAndSettle();
      expect(api.sent, isEmpty);
      expect(t.takeException(), isNull);
      await t.binding.setSurfaceSize(null);
    });

    testWidgets('«Уведомления о сообщениях» в меню команды → сервер', (t) async {
      await open(t);
      await t.tap(find.bySemanticsLabel('Действия с командой'));
      await t.pumpAndSettle();
      expect(find.text('Уведомления о сообщениях'), findsOneWidget);
      await t.tap(find.text('Уведомления о сообщениях'));
      await t.pumpAndSettle();
      expect(api.mutes, [true]);
      expect(find.text('Уведомления этой команды выключены'), findsOneWidget);
      await t.binding.setSurfaceSize(null);
    });
  });

  testWidgets('онбординг: три экрана → «Начать» запоминает', (t) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    expect(ritmNeedsOnboarding, isTrue);
    var done = 0;
    await t.binding.setSurfaceSize(const Size(393, 852));
    await t.pumpWidget(MaterialApp(home: RitmOnboarding(onDone: () => done++)));
    await t.pumpAndSettle();
    expect(find.text('Браслет'), findsOneWidget);
    expect(find.text('Прошивку не обновляйте'), findsOneWidget);
    await t.tap(find.byKey(const Key('onboard.next')));
    await t.pumpAndSettle();
    expect(find.text('Пишет только сон'), findsOneWidget);
    await t.tap(find.byKey(const Key('onboard.next')));
    await t.pumpAndSettle();
    expect(find.text('Свой ключ'), findsOneWidget);
    expect(find.text('Посекундные записи — нет'), findsOneWidget);
    expect(find.text('НАЧАТЬ'), findsOneWidget);
    await t.tap(find.byKey(const Key('onboard.next')));
    await t.pumpAndSettle();
    expect(done, 1);
    expect(ritmNeedsOnboarding, isFalse);
    expect(t.takeException(), isNull);
    await t.binding.setSurfaceSize(null);
  });
}
