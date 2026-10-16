// «Ритм» — демо-сервер «Сообщества» для скриншотов (ТОЛЬКО DEBUG + RITM_DEMO).
// В Release `kRitmDemo == false` — экземпляр не создаётся.

import 'dart:async';

import 'ritm_community_api.dart';
import 'ritm_demo.dart' show demoStrainBack, kRitmDemo, ritmDemoNow;

class _P {
  final int id;
  final String name;
  final String? emoji;
  // Сегодня и 13 дней назад: нагрузка, сон, восстановление; null — нет данных.
  final List<double?> strain;
  final List<int?> sleep;
  final List<int?> rec;
  final bool hideRecovery;
  _P(this.id, this.name, this.emoji, this.strain, this.sleep, this.rec,
      {this.hideRecovery = false});
}

List<double?> _sx(double base, [double? today]) => [
  today ?? base,
  for (var i = 1; i < 14; i++)
    double.parse((base + const [1.9, -1.2, .8, -.5, 1.1, -.9, .3, -1.4, .6, 1.2, -.7, .4, -.2][i - 1])
        .clamp(0, 21)
        .toStringAsFixed(1)),
];

List<int?> _px(int base, [int? today]) => [
  today ?? base,
  for (var i = 1; i < 14; i++)
    (base + const [-4, 6, -3, 5, -7, 2, 4, -5, 3, -2, 6, -6, 1][i - 1]).clamp(0, 100),
];

/// Демо-сервер: 3 команды, 8 участников «Утреннего бега», лента и реакции.
class RitmDemoCommunityApi extends RitmCommunityApi {
  RitmDemoCommunityApi() {
    assert(kRitmDemo);
  }

  // Михаил (вы): сегодня как на демо-главной — нагрузка 10,8, сон 89 % (оценка сна v2),
  // восстановление 78 %; вчера нагрузка 12,8.
  final _people = <_P>[
    // Нагрузка по дням — та же таблица, что у демо-главной (demoStrainBack).
    _P(1, 'Михаил', null, [for (var i = 0; i < 14; i++) demoStrainBack(i)], _px(92, 89),
        _px(78, 78)),
    _P(2, 'Евгения', '🌸', _sx(12.9, 13.6), _px(88), _px(84)),
    _P(3, 'Андрей', '🚴', _sx(14.1, 15.2), _px(74, 71), _px(45, 41)),
    _P(4, 'Ольга', '🧘', _sx(8.0, 8.4), _px(93, 95), _px(88, 90)),
    _P(5, 'Дмитрий', '⚽', _sx(11.4, 11.9), _px(68, 64), _px(55),
        hideRecovery: true),
    _P(6, 'Сергей', '🏋️', _sx(7.1, 6.2), _px(81, 83), _px(60, 63)),
    _P(7, 'Наталья', '🌿', _sx(9.9, 9.7), _px(87, 90), _px(70, 72)),
    _P(8, 'Игорь', '🎿', [null, ..._sx(7.0).skip(1)], [null, ..._px(80).skip(1)],
        [null, ..._px(66).skip(1)]),
  ];

  late final _teams = <RTeam>[
    const RTeam(id: 11, name: 'Утренний бег', emoji: '🏃', code: 'RUN7QK', members: 8, role: 'owner'),
    const RTeam(id: 12, name: 'Семья', emoji: '🏡', code: 'FAM3XZ', members: 4, role: 'member'),
    const RTeam(id: 13, name: 'Офис', emoji: '💼', code: 'OFC9MD', members: 6, role: 'member'),
  ];
  final _members = <int, List<int>>{
    11: [1, 2, 3, 4, 5, 6, 7, 8],
    12: [1, 2, 4, 7],
    13: [1, 3, 5, 6, 8, 2],
  };

  RMe _me = const RMe(id: 1, name: 'Михаил', needsConsent: true);
  final Map<String, RReact> _rx = {};

  DateTime get _now => ritmDemoNow() ?? DateTime.now();

  Future<T> _wait<T>(T v) =>
      Future<T>.delayed(const Duration(milliseconds: 120), () => v);

  @override
  Future<RAuth> signInApple(String t, String n, String? name) =>
      _wait(RAuth('demo', 'demo', _me));

  @override
  Future<RAuth> signInTest(String name) => signInApple('', '', name);

  @override
  Future<RMe> me() => _wait(_me);

  @override
  Future<RMe> putMe({String? name}) => _wait(_me);

  @override
  Future<RMe> consent(String version) {
    _me = _me.copyWith(consentVersion: version, needsConsent: false);
    return _wait(_me);
  }

  @override
  Future<RMe> sharing(RSharing s) {
    _me = _me.copyWith(sharing: s);
    return _wait(_me);
  }

  @override
  Future<void> deleteMe() async {
    _me = const RMe(id: 1, name: 'Михаил', needsConsent: true);
  }

  @override
  Future<void> uploadPhoto(List<int> bytes) async {}

  double? _val(_P p, RMetric m, int back, {bool viewerIsMe = false}) {
    if (!viewerIsMe && p.hideRecovery && m == RMetric.recovery) return null;
    if (p.id == 1 && !viewerIsMe) {
      final s = _me.sharing;
      if ((m == RMetric.sleep && !s.sleep) ||
          (m == RMetric.recovery && !s.recovery) ||
          (m.isStrain && !s.strain)) {
        return null;
      }
    }
    if (back >= 14) return null;
    return switch (m) {
      RMetric.strainDay => p.strain[back],
      RMetric.sleep => p.sleep[back]?.toDouble(),
      RMetric.recovery => p.rec[back]?.toDouble(),
      RMetric.strainWeek => () {
        var s = 0.0;
        var n = 0;
        for (var i = back; i < back + 7 && i < 14; i++) {
          final v = p.strain[i];
          if (v != null) {
            s += v;
            n++;
          }
        }
        return n == 0 ? null : double.parse(s.toStringAsFixed(1));
      }(),
    };
  }

  double? _avg(_P p, RMetric m, int from) {
    if (m == RMetric.strainWeek) return _val(p, m, from);
    final v = [
      for (var i = from; i < from + 7; i++) ?_val(p, m, i),
    ];
    if (v.isEmpty) return null;
    final a = v.reduce((x, y) => x + y) / v.length;
    return m.isStrain ? double.parse(a.toStringAsFixed(1)) : a.roundToDouble();
  }

  List<RBoardRow> _board(int tid, RPeriod per, RMetric m) {
    final rows = <RBoardRow>[];
    for (final id in _members[tid] ?? const <int>[]) {
      final p = _people.firstWhere((x) => x.id == id);
      final hidden = (p.hideRecovery && m == RMetric.recovery) ||
          (p.id == 1 && _val(p, m, 0) == null && _val(p, m, 0, viewerIsMe: true) != null);
      final v = per == RPeriod.day ? _val(p, m, 0) : _avg(p, m, 0);
      final pr = per == RPeriod.day
          ? _val(p, m, m == RMetric.strainWeek ? 7 : 1)
          : _avg(p, m, 7);
      rows.add(RBoardRow(
        userId: p.id,
        name: p.name,
        emoji: p.emoji,
        value: v,
        prev: pr,
        hidden: hidden,
        me: p.id == 1,
      ));
    }
    final vals = {for (final r in rows) ?r.value}.toList()..sort((a, b) => b.compareTo(a));
    final out = [
      for (final r in rows)
        RBoardRow(
          userId: r.userId,
          name: r.name,
          emoji: r.emoji,
          value: r.value,
          prev: r.prev,
          hidden: r.hidden,
          me: r.me,
          place: r.value == null ? null : 1 + vals.where((v) => v > r.value!).length,
        ),
    ]..sort((a, b) {
        if (a.place == null) return b.place == null ? a.name.compareTo(b.name) : 1;
        if (b.place == null) return -1;
        return a.place!.compareTo(b.place!);
      });
    return out;
  }

  @override
  Future<List<RTeam>> teams(RMetric metric, String date) => _wait([
    for (final t in _teams)
      RTeam(
        id: t.id,
        name: t.name,
        emoji: t.emoji,
        code: t.code,
        members: _members[t.id]!.length,
        role: t.role,
        myPlace: _board(t.id, RPeriod.day, metric).firstWhere((r) => r.me).place,
      ),
  ]);

  @override
  Future<RTeam> createTeam(String name, String emoji) => _wait(
      RTeam(id: 99, name: name, emoji: emoji, code: 'NEW4PX', members: 1, role: 'owner'));

  @override
  Future<RTeam> join(String code) => _wait(_teams.first);

  @override
  Future<void> leave(int teamId) async {}

  @override
  Future<RBoard> leaderboard(int teamId, RPeriod p, RMetric m, String date) async {
    final t = (await teams(m, date)).firstWhere((x) => x.id == teamId);
    return _wait(RBoard(t, _board(teamId, p, m)));
  }

  @override
  Future<List<RFeedItem>> feed(int teamId, String date) {
    final now = _now;
    final today = DateTime(now.year, now.month, now.day);
    RFeedItem w(int uid, int sid, String type, int min, double strain, DateTime end,
            Map<String, RReact> rx) =>
        RFeedItem(
          summaryId: sid,
          item: 0,
          userId: uid,
          name: _people.firstWhere((p) => p.id == uid).name,
          emoji: _people.firstWhere((p) => p.id == uid).emoji,
          me: uid == 1,
          kind: 'workout',
          type: type,
          minutes: min,
          strain: strain,
          at: end,
          reactions: _merge(sid, 0, rx),
        );
    RFeedItem n(int uid, int sid, DateTime at, Map<String, RReact> rx) {
      final p = _people.firstWhere((x) => x.id == uid);
      return RFeedItem(
        summaryId: sid,
        item: -1,
        userId: uid,
        name: p.name,
        emoji: p.emoji,
        me: uid == 1,
        kind: 'night',
        sleepPct: p.sleep[0],
        recovery: p.hideRecovery ? null : p.rec[0],
        at: at,
        reactions: _merge(sid, -1, rx),
      );
    }

    final members = _members[teamId] ?? const <int>[];
    final all = <RFeedItem>[
      // Бег 07:40–08:26, нагрузка 10,0 — как на демо-главной.
      w(1, 101, 'run', 46, 10.0, today.add(const Duration(hours: 8, minutes: 26)), {
        '👍': const RReact(3, false),
        '🔥': const RReact(2, false),
      }),
      w(3, 103, 'cycling', 52, 12.8, today.add(const Duration(hours: 7, minutes: 5)), {
        '🔥': const RReact(4, true),
        '💪': const RReact(1, false),
      }),
      n(4, 104, today.add(const Duration(hours: 6, minutes: 50)), {
        '👍': const RReact(2, false),
      }),
      n(2, 102, today.add(const Duration(hours: 6, minutes: 35)), {
        '💪': const RReact(1, true),
      }),
      n(5, 105, today.add(const Duration(hours: 6, minutes: 10)), const {}),
      w(6, 206, 'strength', 45, 8.9, today.subtract(const Duration(hours: 3, minutes: 20)), {
        '💪': const RReact(5, false),
      }),
      w(2, 202, 'yoga', 60, 6.1, today.subtract(const Duration(hours: 5)), const {}),
    ];
    return _wait([
      for (final x in all)
        // Свои тренировки — только если включён переключатель «Тренировки» (как на сервере).
        if (members.contains(x.userId) && !(x.me && x.kind == 'workout' && !_me.sharing.workouts)) x,
    ]);
  }

  Map<String, RReact> _merge(int sid, int item, Map<String, RReact> base) => {
    for (final e in kRitmReactions)
      e: _rx['$sid/$item/$e'] ?? base[e] ?? const RReact(0, false),
  };

  @override
  Future<bool> react(int teamId, int summaryId, int item, String emoji) async {
    final k = '$summaryId/$item/$emoji';
    final cur = _rx[k] ?? const RReact(0, false);
    _rx[k] = cur.mine ? RReact(cur.n - 1, false) : RReact(cur.n + 1, true);
    return _rx[k]!.mine;
  }

  @override
  Future<void> putSummary(RDaySummary s, RSharing sharing) async {}

  // ── B6: демо-чат «Утреннего бега» ──
  final _chat = StreamController<RChatEvent>.broadcast();
  int _msgId = 100;
  late final Map<int, List<RMessage>> _msgs = {
    11: () {
      final n = _now;
      DateTime at(int h, int m) => DateTime(n.year, n.month, n.day, h, m);
      RMessage x(int id, int uid, String text, DateTime t) {
        final p = _people.firstWhere((p) => p.id == uid);
        return RMessage(id: id, teamId: 11, userId: uid, name: p.name, emoji: p.emoji, text: text, me: uid == 1, at: t);
      }

      return [
        x(91, 3, 'Завтра в 7:00 у пруда, кто со мной? Темп спокойный, 8 км.', at(7, 58)),
        x(92, 2, 'Я! Восстановление 84\u00a0%, можно и быстрее 😄', at(8, 3)),
        x(93, 4, 'Пропущу, вчера тяжёлая силовая, сегодня отдыхаю.', at(8, 15)),
        RMessage(id: 94, teamId: 11, userId: 5, name: 'Дмитрий', emoji: '⚽', deleted: true, at: at(8, 21)),
        x(95, 1, 'Буду. Сон 84\u00a0%, нагрузка вчера 12,8 — пойду в зоне 2.', at(9, 2)),
        x(96, 6, 'Отлично, тогда в 6:55 у входа в парк.', at(9, 20)),
      ];
    }(),
  };

  @override
  Future<(List<RMessage>, bool)> messages(int teamId, {int? before}) =>
      _wait(([...?_msgs[teamId]], false));

  @override
  Future<RMessage> sendMessage(int teamId, String text) async {
    final m = RMessage(id: ++_msgId, teamId: teamId, userId: 1, name: 'Михаил', text: text, me: true, at: _now);
    (_msgs[teamId] ??= []).add(m);
    // Ответ «друга» через 1,6 с — как живой WebSocket.
    Timer(const Duration(milliseconds: 1600), () {
      final r = RMessage(
        id: ++_msgId,
        teamId: teamId,
        userId: 2,
        name: 'Евгения',
        emoji: '🌸',
        text: 'Договорились, захвачу воду на всех 💧',
        at: _now,
      );
      _msgs[teamId]!.add(r);
      _chat.add((message: r, deletedId: null));
    });
    return _wait(m);
  }

  @override
  Future<void> deleteMessage(int teamId, int id) async {
    final xs = _msgs[teamId] ?? [];
    final i = xs.indexWhere((x) => x.id == id);
    if (i >= 0) xs[i] = xs[i].gone();
  }

  @override
  Stream<RChatEvent> chat(int teamId, {int? myId}) => _chat.stream.where((e) => (e.message?.teamId ?? teamId) == teamId);

  /// Демо-автопилот: войти сразу (минуя Apple).
  void reset() => _me = const RMe(id: 1, name: 'Михаил', needsConsent: true);
}

/// Подключить демо-сервер (вызывается из shell в DEBUG-демо).
RitmCommunity ritmDemoCommunity() {
  final api = RitmDemoCommunityApi();
  final c = RitmCommunity(
    api: api,
    store: RitmMemoryTokenStore(),
    clock: () => ritmDemoNow() ?? DateTime.now(),
    persist: false,
  );
  return c;
}
