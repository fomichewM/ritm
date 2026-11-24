// «Ритм» B5 — e2e против НАСТОЯЩЕГО сервера сообщества (локальная копия
// FastAPI + PostgreSQL на Mac, RITM_TEST_LOGIN=1). Без переменной RITM_E2E
// тест пропускается. Прогон: tool/ritm_b5_e2e.sh.
//
// Приёмка v2 §14 B5: два аккаунта → одна команда → оба видят друг друга в
// рейтинге с числами сразу после PUT /summary; удаление одного убирает строку.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_community_api.dart';

void main() {
  final base = Platform.environment['RITM_E2E'];
  test('два аккаунта в рейтинге, удаление убирает строку', () async {
    final day = ritmDayId(DateTime.now());
    final a = RitmCommunity(api: RitmHttpApi(base: base, store: RitmMemoryTokenStore()), store: RitmMemoryTokenStore(), persist: false);
    final b = RitmCommunity(api: RitmHttpApi(base: base, store: RitmMemoryTokenStore()), store: RitmMemoryTokenStore(), persist: false);
    expect(await a.signInTest('Михаил'), isTrue, reason: a.error);
    expect(await b.signInTest('Друг'), isTrue, reason: b.error);
    expect(await a.acceptConsent(processing: true, team: true), isTrue, reason: a.error);
    expect(await b.acceptConsent(processing: true, team: true), isTrue, reason: b.error);

    final t0 = DateTime.now();
    expect(await a.offerSummary(RDaySummary(date: day, sleepPct: 89, recovery: 78, strainDay: 10.8, strainWeek: 63.2)), isTrue);
    expect(await b.offerSummary(RDaySummary(date: day, sleepPct: 74, recovery: 55, strainDay: 13.4, strainWeek: 70.1)), isTrue);

    final team = await a.createTeam('Бегуны', '🏃');
    expect(team, isNotNull, reason: a.error);
    expect(await b.join(team!.code), isNotNull, reason: b.error);

    final board = await b.api.leaderboard(team.id, RPeriod.day, RMetric.strainDay, day);
    final rows = {for (final r in board.rows) r.name: r};
    expect(rows.keys.toSet(), {'Михаил', 'Друг'});
    expect(rows['Михаил']!.value, 10.8);
    expect(rows['Друг']!.value, 13.4);
    expect(rows['Друг']!.place, 1);
    final rec = await a.api.leaderboard(team.id, RPeriod.day, RMetric.recovery, day);
    expect({for (final r in rec.rows) r.name: r.value}, {'Михаил': 78, 'Друг': 55});
    final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
    // ignore: avoid_print
    print('E2E: оба в рейтинге через ${secs.toStringAsFixed(2)} с после PUT /summary (допуск 300 с)');
    expect(secs, lessThan(300));

    expect(await b.deleteAccount(), isTrue, reason: b.error);
    final after = await a.api.leaderboard(team.id, RPeriod.day, RMetric.strainDay, day);
    expect(after.rows.map((r) => r.name), ['Михаил']);
    expect(await a.deleteAccount(), isTrue, reason: a.error);
    // ignore: avoid_print
    print('E2E: после удаления «Друг» строк в рейтинге: ${after.rows.length}; оба тестовых аккаунта удалены');
  }, skip: base == null ? 'нужен RITM_E2E=<адрес локального сервера>' : false);

  test('B6: чат — сообщение приходит второму по WebSocket ≤ 3 с, удаление тоже', () async {
    final a = RitmCommunity(api: RitmHttpApi(base: base, store: RitmMemoryTokenStore()), store: RitmMemoryTokenStore(), persist: false);
    final b = RitmCommunity(api: RitmHttpApi(base: base, store: RitmMemoryTokenStore()), store: RitmMemoryTokenStore(), persist: false);
    await a.signInTest('Михаил');
    await b.signInTest('Друг');
    await a.acceptConsent(processing: true, team: true);
    await b.acceptConsent(processing: true, team: true);
    final team = (await a.createTeam('Чат', '💬'))!;
    await b.join(team.code);
    final got = <RChatEvent>[];
    final sub = b.api.chat(team.id, myId: b.me!.id).listen(got.add);
    await Future<void>.delayed(const Duration(milliseconds: 500)); // соединение открылось
    final t0 = DateTime.now();
    final m = await a.api.sendMessage(team.id, 'Привет из e2e');
    while (got.isEmpty && DateTime.now().difference(t0).inSeconds < 5) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final ms = DateTime.now().difference(t0).inMilliseconds;
    expect(got.single.message?.text, 'Привет из e2e');
    expect(got.single.message?.me, isFalse);
    expect(ms, lessThan(3000));
    await a.api.deleteMessage(team.id, m.id);
    while (got.length < 2 && DateTime.now().difference(t0).inSeconds < 5) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got.last.deletedId, m.id);
    final (hist, muted) = await b.api.messages(team.id);
    expect((hist.single.deleted, hist.single.text, muted), (true, null, false));
    await sub.cancel();
    await a.deleteAccount();
    await b.deleteAccount();
    // ignore: avoid_print
    print('E2E чат: доставка по WebSocket за $ms мс (допуск 3000), удаление пришло, история «удалено»');
  }, skip: base == null ? 'нужен RITM_E2E=<адрес локального сервера>' : false);
}
