// «Ритм» B5 — «Сообщество»: согласие, отправка итогов (только агрегаты),
// переключатели публикации, удаление аккаунта, четыре вкладки.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_community.dart';
import 'package:openstrap_edge/ritm/ritm_community_api.dart';
import 'package:openstrap_edge/ritm/ritm_community_auth.dart';
import 'package:openstrap_edge/ritm/ritm_community_feed.dart';
import 'package:openstrap_edge/ui2/app_shell.dart' show ShellDomain;

/// Сервер в памяти: записывает, что пришло.
class _FakeApi extends RitmCommunityApi {
  RMe meNow = const RMe(id: 7, name: 'Тест', needsConsent: true);
  final consents = <String>[];
  final sums = <Map<String, dynamic>>[];
  var deleted = false;

  @override
  Future<RAuth> signInApple(String t, String n, String? name) => signInTest(name ?? '');
  @override
  Future<RAuth> signInTest(String name) async => RAuth('a', 'r', meNow);
  @override
  Future<RMe> me() async => meNow;
  @override
  Future<RMe> putMe({String? name}) async => meNow;
  @override
  Future<RMe> consent(String version) async {
    consents.add(version);
    return meNow = RMe(id: meNow.id, name: meNow.name, sharing: meNow.sharing, consentVersion: version, needsConsent: false);
  }

  @override
  Future<RMe> sharing(RSharing s) async =>
      meNow = RMe(
        id: meNow.id,
        name: meNow.name,
        sharing: s,
        consentVersion: meNow.consentVersion,
        needsConsent: meNow.needsConsent,
      );
  @override
  Future<void> deleteMe() async => deleted = true;
  @override
  Future<void> uploadPhoto(List<int> bytes) async {}
  @override
  Future<List<RTeam>> teams(RMetric metric, String date) async => const [];
  @override
  Future<RTeam> createTeam(String name, String emoji) async =>
      RTeam(id: 1, name: name, emoji: emoji, code: 'ABC123', members: 1);
  @override
  Future<RTeam> join(String code) async => RTeam(id: 2, name: 'Бег', emoji: '🏃', code: code, members: 2);
  @override
  Future<void> leave(int teamId) async {}
  @override
  Future<RBoard> leaderboard(int teamId, RPeriod p, RMetric m, String date) async =>
      RBoard(const RTeam(id: 1, name: 'Б', emoji: '🏃', code: 'ABC123', members: 1), const []);
  @override
  Future<List<RFeedItem>> feed(int teamId, String date) async => const [];
  @override
  Future<bool> react(int teamId, int summaryId, int item, String emoji) async => true;
  @override
  Future<void> putSummary(RDaySummary s, RSharing sharing) async => sums.add(s.toJson(sharing));
}

const _day = RDaySummary(
  date: '2026-10-16',
  sleepPct: 89,
  recovery: 78,
  strainDay: 10.84,
  strainWeek: 63.2,
  workouts: [RWorkout('run', 46, strain: 9.6, endTs: 1792130000)],
);

RitmCommunity _com(_FakeApi api, DateTime Function() clock) =>
    RitmCommunity(api: api, store: RitmMemoryTokenStore(), clock: clock, persist: false);

void main() {
  group('итог дня — только агрегаты', () {
    test('ключи ⊆ разрешённых; пульса, ВСР, стресса, ЭКГ, биовозраста нет', () {
      final j = _day.toJson(const RSharing(workouts: true));
      expect(kRitmSummaryKeys.containsAll(j.keys), isTrue);
      final txt = jsonEncode(j);
      for (final bad in ['hr', 'hrv', 'rmssd', 'stress', 'ecg', 'bio', 'age', 'spo2', 'temp']) {
        expect(RegExp('"$bad"').hasMatch(txt), isFalse, reason: bad);
      }
      expect(j['strain_day'], 10.8);
      expect((j['workouts'] as List).single, {'type': 'run', 'minutes': 46, 'strain': 9.6, 'end_ts': 1792130000});
    });

    test('выключенная метрика не уходит; тренировки по умолчанию выкл.', () {
      final j = _day.toJson(const RSharing(recovery: false));
      expect(j.containsKey('recovery'), isFalse);
      expect(j.containsKey('workouts'), isFalse);
      expect(j['sleep_pct'], 89);
      final k = _day.toJson(const RSharing(sleep: false, strain: false));
      expect(k.keys, ['recovery']);
    });

    test('сессии Edge → тренировки ленты (тип, минуты, нагрузка, конец)', () {
      final w = ritmFeedWorkouts([
        {'type': 'running', 'duration_min': 46.4, 'start_ts': 1000, 'strain': 9.61},
        {'type': 'traditional_strength_training', 'duration_min': 30, 'start_ts': 5000},
        {'type': 'walk', 'duration_min': 0},
      ]);
      expect(w.map((x) => x.type), ['run', 'strength']);
      expect(w.first.minutes, 46);
      expect(w.first.endTs, 1000 + 46 * 60);
      expect(w.last.strain, isNull);
    });
  });

  group('синхронизация (раз в час при изменении, после ночи — сразу)', () {
    test('то же самое не шлём; изменение — не раньше часа; новая ночь — сразу', () {
      final sync = RitmSummarySync();
      const sh = RSharing();
      final t0 = DateTime(2026, 10, 16, 9);
      expect(sync.due(_day, sh, t0), isTrue);
      sync.markSent(_day, sh, t0);
      expect(sync.due(_day, sh, t0.add(const Duration(hours: 3))), isFalse, reason: 'не изменилось');
      const more = RDaySummary(date: '2026-10-16', sleepPct: 89, recovery: 78, strainDay: 12.1, strainWeek: 64.5);
      expect(sync.due(more, sh, t0.add(const Duration(minutes: 20))), isFalse, reason: 'меньше часа');
      expect(sync.due(more, sh, t0.add(const Duration(minutes: 61))), isTrue);
      const night = RDaySummary(date: '2026-10-16', sleepPct: 91, recovery: 80, strainDay: 10.8, strainWeek: 63.2);
      expect(sync.due(night, sh, t0.add(const Duration(minutes: 5))), isTrue, reason: 'новая ночь');
      expect(sync.due(const RDaySummary(date: '2026-10-16'), sh, t0.add(const Duration(hours: 2))), isFalse);
    });

    test('до согласия не отправляется; после согласия — сразу (версия согласия на сервер)', () async {
      final api = _FakeApi();
      var now = DateTime(2026, 10, 16, 9);
      final c = _com(api, () => now);
      expect(await c.signInTest('Тест'), isTrue);
      expect(c.stage, RStage.needsConsent);
      expect(await c.offerSummary(_day), isFalse);
      expect(api.sums, isEmpty);
      expect(await c.acceptConsent(processing: true, team: false), isFalse);
      expect(api.consents, isEmpty);
      expect(await c.acceptConsent(processing: true, team: true), isTrue);
      expect(api.consents, [kRitmConsentVersion]);
      expect(c.stage, RStage.ready);
      await Future<void>.delayed(Duration.zero);
      expect(api.sums.length, 1);
      now = now.add(const Duration(minutes: 10));
      expect(await c.offerSummary(_day), isFalse);
      expect(api.sums.length, 1);
    });

    test('переключатель публикации сразу меняет то, что уходит', () async {
      final api = _FakeApi();
      final c = _com(api, () => DateTime(2026, 10, 16, 9));
      await c.signInTest('Тест');
      await c.acceptConsent(processing: true, team: true);
      expect(await c.offerSummary(_day), isTrue);
      expect(api.sums.last.containsKey('recovery'), isTrue);
      expect(await c.setSharing(const RSharing(recovery: false)), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(api.meNow.sharing.recovery, isFalse);
      await c.flush(force: true);
      expect(api.sums.last.containsKey('recovery'), isFalse);
    });

    test('удаление аккаунта: сервер получил DELETE /me, токены стёрты', () async {
      final api = _FakeApi();
      final c = _com(api, () => DateTime(2026, 10, 16, 9));
      await c.signInTest('Тест');
      await c.acceptConsent(processing: true, team: true);
      expect(await c.deleteAccount(), isTrue);
      expect(api.deleted, isTrue);
      expect(c.stage, RStage.signedOut);
      expect(await c.store.read(), (null, null));
    });
  });

  group('экраны', () {
    testWidgets('согласие: без двух галочек «Продолжить» не работает', (t) async {
      final api = _FakeApi();
      final c = _com(api, () => DateTime(2026, 10, 16, 9));
      await c.signInTest('Тест');
      RitmCommunity.I = c;
      await t.binding.setSurfaceSize(const Size(393, 852));
      await t.pumpWidget(const MaterialApp(home: RitmConsentScreen()));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byKey(const Key('consent.go')), 200, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      expect(find.text('Отметьте обе галочки, чтобы продолжить'), findsOneWidget);
      await t.tap(find.byKey(const Key('consent.go')));
      await t.pumpAndSettle();
      expect(api.consents, isEmpty);
      await t.tap(find.byKey(const Key('consent.processing')));
      await t.pump();
      await t.tap(find.byKey(const Key('consent.go')));
      await t.pumpAndSettle();
      expect(api.consents, isEmpty, reason: 'одной галочки мало');
      await t.tap(find.byKey(const Key('consent.team')));
      await t.pump();
      expect(find.textContaining('Версия согласия 16.10.2026'), findsOneWidget);
      await t.tap(find.byKey(const Key('consent.go')));
      await t.pumpAndSettle();
      expect(api.consents, [kRitmConsentVersion]);
      expect(t.takeException(), isNull);
      await t.binding.setSurfaceSize(null);
    });

    testWidgets('«Удалить аккаунт»: сначала подтверждение, «Отмена» ничего не удаляет', (t) async {
      final api = _FakeApi();
      final c = _com(api, () => DateTime(2026, 10, 16, 9));
      await c.signInTest('Тест');
      await c.acceptConsent(processing: true, team: true);
      RitmCommunity.I = c;
      await t.binding.setSurfaceSize(const Size(393, 852));
      await t.pumpWidget(const MaterialApp(home: RitmCommunitySettings()));
      await t.pumpAndSettle();
      final del = find.text('Удалить аккаунт');
      await t.scrollUntilVisible(del, 120, scrollable: find.byType(Scrollable).first);
      await t.tap(del);
      await t.pumpAndSettle();
      expect(find.text('Удалить аккаунт?'), findsOneWidget);
      await t.tap(find.text('Отмена'));
      await t.pumpAndSettle();
      expect(api.deleted, isFalse);
      await t.tap(del);
      await t.pumpAndSettle();
      await t.tap(find.text('Удалить'));
      await t.pumpAndSettle();
      expect(api.deleted, isTrue);
      expect(t.takeException(), isNull);
      await t.binding.setSurfaceSize(null);
    });

    test('таб-бар: четыре вкладки, «Сообщество» третья', () {
      expect(ShellDomain.values.map((d) => d.name), ['today', 'health', 'community', 'more']);
    });
  });
}
