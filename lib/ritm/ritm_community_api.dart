// «Ритм» — Сообщество (ТЗ v2 §7, сборка B5): модели, клиент сервера,
// сессия и синхронизация итогов дня.
//
// На сервер уходят ТОЛЬКО агрегаты дня: Сон %, Восстановление %, Нагрузка дня
// и недели, тренировки (тип, минуты, нагрузка). Ни пульса, ни ВСР, ни ЭКГ, ни
// стресса, ни биовозраста — см. [RDaySummary.toJson] и тест на ключи.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket;
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Сервер сообщества (VDS в РФ, nginx → FastAPI).
const String kRitmServer = String.fromEnvironment(
  'RITM_SERVER',
  defaultValue: 'https://app.oporagroup.com/ritm',
);

/// Версия текста согласия (152-ФЗ). Меняется — пользователь подтверждает заново.
const String kRitmConsentVersion = '2026-10-16';

/// Тестовый вход для e2e в симуляторе: только DEBUG + define. В Release
/// `kDebugMode == false` — кнопки нет, ветка вырезается компилятором.
bool get kRitmTestLogin =>
    kDebugMode && const bool.fromEnvironment('RITM_TEST_LOGIN');

// ───────────────────────── модели ─────────────────────────

class RSharing {
  final bool sleep, recovery, strain, workouts, photo;
  const RSharing({
    this.sleep = true,
    this.recovery = true,
    this.strain = true,
    this.workouts = false,
    this.photo = false,
  });

  factory RSharing.fromJson(Map<String, dynamic> j) => RSharing(
    sleep: j['sleep'] == true,
    recovery: j['recovery'] == true,
    strain: j['strain'] == true,
    workouts: j['workouts'] == true,
    photo: j['photo'] == true,
  );

  Map<String, dynamic> toJson() => {
    'sleep': sleep,
    'recovery': recovery,
    'strain': strain,
    'workouts': workouts,
    'photo': photo,
  };

  RSharing copyWith({
    bool? sleep,
    bool? recovery,
    bool? strain,
    bool? workouts,
    bool? photo,
  }) => RSharing(
    sleep: sleep ?? this.sleep,
    recovery: recovery ?? this.recovery,
    strain: strain ?? this.strain,
    workouts: workouts ?? this.workouts,
    photo: photo ?? this.photo,
  );

  @override
  bool operator ==(Object other) =>
      other is RSharing &&
      other.sleep == sleep &&
      other.recovery == recovery &&
      other.strain == strain &&
      other.workouts == workouts &&
      other.photo == photo;

  @override
  int get hashCode => Object.hash(sleep, recovery, strain, workouts, photo);
}

class RMe {
  final int id;
  final String name;
  final String? emoji;
  final bool hasPhoto;
  final RSharing sharing;
  final String? consentVersion;
  final bool needsConsent;
  const RMe({
    required this.id,
    required this.name,
    this.emoji,
    this.hasPhoto = false,
    this.sharing = const RSharing(),
    this.consentVersion,
    this.needsConsent = true,
  });

  factory RMe.fromJson(Map<String, dynamic> j) => RMe(
    id: (j['id'] as num).toInt(),
    name: (j['display_name'] ?? '').toString(),
    emoji: j['avatar_emoji'] as String?,
    hasPhoto: j['has_photo'] == true,
    sharing: RSharing.fromJson(
      (j['sharing'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    consentVersion: j['consent_version'] as String?,
    needsConsent: j['needs_consent'] != false,
  );

  RMe copyWith({RSharing? sharing, String? name, String? consentVersion, bool? needsConsent}) => RMe(
    id: id,
    name: name ?? this.name,
    emoji: emoji,
    hasPhoto: hasPhoto,
    sharing: sharing ?? this.sharing,
    consentVersion: consentVersion ?? this.consentVersion,
    needsConsent: needsConsent ?? this.needsConsent,
  );
}

/// Метрика рейтинга (§7 п. 3).
enum RMetric {
  strainDay('strain_day', 'Нагрузка дня'),
  sleep('sleep', 'Сон'),
  recovery('recovery', 'Восстановление'),
  strainWeek('strain_week', 'Нагрузка недели');

  const RMetric(this.key, this.title);
  final String key;
  final String title;

  bool get isStrain => this == strainDay || this == strainWeek;

  static RMetric of(String? k) =>
      values.firstWhere((m) => m.key == k, orElse: () => strainDay);
}

enum RPeriod { day, week }

class RTeam {
  final int id;
  final String name;
  final String emoji;
  final String code;
  final int members;
  final String? role;
  final int? myPlace;
  const RTeam({
    required this.id,
    required this.name,
    required this.emoji,
    required this.code,
    required this.members,
    this.role,
    this.myPlace,
  });

  factory RTeam.fromJson(Map<String, dynamic> j) => RTeam(
    id: (j['id'] as num).toInt(),
    name: (j['name'] ?? '').toString(),
    emoji: (j['emoji'] ?? '🏃').toString(),
    code: (j['invite_code'] ?? '').toString(),
    members: (j['members'] as num?)?.toInt() ?? 1,
    role: j['role'] as String?,
    myPlace: (j['my_place'] as num?)?.toInt(),
  );

  bool get owner => role == 'owner';
}

class RBoardRow {
  final int userId;
  final String name;
  final String? emoji;
  final bool hasPhoto;
  final double? value;
  final double? prev;
  final bool hidden;
  final bool me;
  final int? place;
  const RBoardRow({
    required this.userId,
    required this.name,
    this.emoji,
    this.hasPhoto = false,
    this.value,
    this.prev,
    this.hidden = false,
    this.me = false,
    this.place,
  });

  factory RBoardRow.fromJson(Map<String, dynamic> j) => RBoardRow(
    userId: (j['user_id'] as num).toInt(),
    name: (j['name'] ?? '').toString(),
    emoji: j['emoji'] as String?,
    hasPhoto: j['has_photo'] == true,
    value: (j['value'] as num?)?.toDouble(),
    prev: (j['prev'] as num?)?.toDouble(),
    hidden: j['hidden'] == true,
    me: j['me'] == true,
    place: (j['place'] as num?)?.toInt(),
  );
}

class RBoard {
  final RTeam team;
  final List<RBoardRow> rows;
  const RBoard(this.team, this.rows);
}

/// Сообщение чата команды (B6). Удалённое — без текста.
class RMessage {
  final int id;
  final int teamId;
  final int userId;
  final String name;
  final String? emoji;
  final String? text;
  final bool deleted;
  final bool me;
  final DateTime at;
  const RMessage({
    required this.id,
    required this.teamId,
    required this.userId,
    required this.name,
    this.emoji,
    this.text,
    this.deleted = false,
    this.me = false,
    required this.at,
  });

  factory RMessage.fromJson(Map<String, dynamic> j, {int? myId}) => RMessage(
    id: (j['id'] as num).toInt(),
    teamId: (j['team_id'] as num?)?.toInt() ?? 0,
    userId: (j['user_id'] as num).toInt(),
    name: (j['name'] ?? 'Участник').toString(),
    emoji: j['emoji'] as String?,
    text: j['text'] as String?,
    deleted: j['deleted'] == true,
    me: myId != null ? (j['user_id'] as num).toInt() == myId : j['me'] == true,
    at: DateTime.tryParse((j['at'] ?? '').toString())?.toLocal() ?? DateTime.now(),
  );

  RMessage gone() =>
      RMessage(id: id, teamId: teamId, userId: userId, name: name, emoji: emoji, deleted: true, me: me, at: at);
}

/// Событие живого чата: новое сообщение или удаление.
typedef RChatEvent = ({RMessage? message, int? deletedId});

class RReact {
  final int n;
  final bool mine;
  const RReact(this.n, this.mine);
}

const kRitmReactions = ['👍', '🔥', '💪'];

class RFeedItem {
  final int summaryId;
  final int item;
  final int userId;
  final String name;
  final String? emoji;
  final bool me;
  final String kind; // night | workout
  final String? type;
  final int? minutes;
  final double? strain;
  final int? sleepPct;
  final int? recovery;
  final DateTime at;
  final Map<String, RReact> reactions;
  const RFeedItem({
    required this.summaryId,
    required this.item,
    required this.userId,
    required this.name,
    this.emoji,
    this.me = false,
    required this.kind,
    this.type,
    this.minutes,
    this.strain,
    this.sleepPct,
    this.recovery,
    required this.at,
    this.reactions = const {},
  });

  factory RFeedItem.fromJson(Map<String, dynamic> j) {
    final rx = <String, RReact>{};
    final r = j['reactions'];
    if (r is Map) {
      for (final e in r.entries) {
        final v = e.value;
        if (v is Map) {
          rx[e.key.toString()] = RReact(
            (v['n'] as num?)?.toInt() ?? 0,
            v['mine'] == true,
          );
        }
      }
    }
    return RFeedItem(
      summaryId: (j['summary_id'] as num).toInt(),
      item: (j['item'] as num).toInt(),
      userId: (j['user_id'] as num).toInt(),
      name: (j['name'] ?? '').toString(),
      emoji: j['emoji'] as String?,
      me: j['me'] == true,
      kind: (j['kind'] ?? 'night').toString(),
      type: j['type'] as String?,
      minutes: (j['minutes'] as num?)?.toInt(),
      strain: (j['strain'] as num?)?.toDouble(),
      sleepPct: (j['sleep_pct'] as num?)?.toInt(),
      recovery: (j['recovery'] as num?)?.toInt(),
      at: DateTime.tryParse((j['at'] ?? '').toString())?.toLocal() ??
          DateTime.now(),
      reactions: rx,
    );
  }

  RFeedItem toggled(String emoji) {
    final m = Map<String, RReact>.of(reactions);
    final cur = m[emoji] ?? const RReact(0, false);
    m[emoji] = cur.mine
        ? RReact(math.max(0, cur.n - 1), false)
        : RReact(cur.n + 1, true);
    return RFeedItem(
      summaryId: summaryId,
      item: item,
      userId: userId,
      name: name,
      emoji: this.emoji,
      me: me,
      kind: kind,
      type: type,
      minutes: minutes,
      strain: strain,
      sleepPct: sleepPct,
      recovery: recovery,
      at: at,
      reactions: m,
    );
  }
}

class RWorkout {
  final String type; // run, walk, cycling, strength, …
  final int minutes;
  final double? strain;
  final int? endTs;
  const RWorkout(this.type, this.minutes, {this.strain, this.endTs});

  Map<String, dynamic> toJson() => {
    'type': type,
    'minutes': minutes,
    if (strain != null) 'strain': (strain! * 10).round() / 10,
    if (endTs != null) 'end_ts': endTs,
  };
}

/// Типы тренировок Edge → короткие ключи сервера.
String ritmWorkoutKey(String? edgeType) {
  final t = (edgeType ?? '').toLowerCase();
  if (t.contains('run') || t.contains('бег')) return 'run';
  if (t.contains('walk') || t.contains('ходьб')) return 'walk';
  if (t.contains('hik')) return 'hike';
  if (t.contains('cycl') || t.contains('bike') || t.contains('вело')) {
    return 'cycling';
  }
  if (t.contains('strength') || t.contains('weight') || t.contains('сил') ||
      t.contains('functional') || t.contains('crossfit')) {
    return 'strength';
  }
  if (t.contains('swim') || t.contains('плав')) return 'swim';
  if (t.contains('yoga') || t.contains('йог') || t.contains('pilates')) {
    return 'yoga';
  }
  if (t.contains('hiit') || t.contains('interval')) return 'hiit';
  if (t.contains('row')) return 'row';
  if (t.contains('ski')) return 'ski';
  if (t.contains('danc')) return 'dance';
  if (t.contains('stretch')) return 'stretch';
  if (t.contains('cardio') || t.contains('elliptical')) return 'cardio';
  if (t.contains('tennis') || t.contains('ball') || t.contains('hockey') ||
      t.contains('sport')) {
    return 'sport';
  }
  return 'other';
}

/// Подпись тренировки в ленте.
String ritmWorkoutWord(String? key) => switch (key) {
  'run' => 'бег',
  'walk' => 'ходьба',
  'hike' => 'поход',
  'cycling' => 'велосипед',
  'strength' => 'силовая',
  'swim' => 'плавание',
  'yoga' => 'йога',
  'hiit' => 'интервалы',
  'row' => 'гребля',
  'ski' => 'лыжи',
  'dance' => 'танцы',
  'stretch' => 'растяжка',
  'cardio' => 'кардио',
  'sport' => 'игра',
  _ => 'тренировка',
};

/// Итоги одного дня для сервера.
class RDaySummary {
  final String date; // ГГГГ-ММ-ДД, локальный день
  final int? sleepPct;
  final int? recovery;
  final double? strainDay;
  final double? strainWeek;
  final List<RWorkout> workouts;
  const RDaySummary({
    required this.date,
    this.sleepPct,
    this.recovery,
    this.strainDay,
    this.strainWeek,
    this.workouts = const [],
  });

  bool get isEmpty =>
      sleepPct == null &&
      recovery == null &&
      strainDay == null &&
      strainWeek == null &&
      workouts.isEmpty;

  /// Ровно то, что уходит на сервер, с учётом переключателей публикации.
  Map<String, dynamic> toJson(RSharing s) => {
    if (s.sleep && sleepPct != null) 'sleep_pct': sleepPct,
    if (s.recovery && recovery != null) 'recovery': recovery,
    if (s.strain && strainDay != null)
      'strain_day': (strainDay! * 10).round() / 10,
    if (s.strain && strainWeek != null)
      'strain_week': (strainWeek! * 10).round() / 10,
    if (s.workouts) 'workouts': [for (final w in workouts) w.toJson()],
  };

  /// Подпись для «изменилось ли».
  String signature(RSharing s) => jsonEncode(toJson(s));

  String get nightKey => '${sleepPct ?? '-'}/${recovery ?? '-'}';
}

/// Ключи, которые клиент вправе отправить (тест сверяет с [RDaySummary.toJson]).
const kRitmSummaryKeys = {
  'sleep_pct',
  'recovery',
  'strain_day',
  'strain_week',
  'workouts',
};
const kRitmWorkoutKeys = {'type', 'minutes', 'strain', 'end_ts'};

String ritmDayId(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ───────────────────────── ошибки ─────────────────────────

class RApiError implements Exception {
  final int status;
  final String code;
  const RApiError(this.status, this.code);

  /// Понятная фраза для пользователя.
  String get message => switch (code) {
    'team_full' => 'В команде уже 50 человек — это максимум',
    'too_many_teams' => 'Можно состоять не больше чем в 10 командах',
    'bad_code' => 'Такого кода нет — проверьте буквы и цифры',
    'rate_limited' => 'Слишком часто — подождите минуту',
    'consent_required' => 'Нужно подтвердить согласие на обработку данных',
    'network' => 'Нет связи с сервером — проверьте интернет',
    'token_expired' || 'bad_signature' || 'bad_nonce' || 'bad_audience' =>
      'Apple не подтвердил вход — попробуйте ещё раз',
    _ when status == 401 => 'Сессия истекла — войдите снова',
    _ when status >= 500 => 'Сервер временно недоступен',
    _ => 'Не получилось — попробуйте ещё раз',
  };

  @override
  String toString() => 'RApiError($status, $code)';
}

// ───────────────────────── клиент ─────────────────────────

class RAuth {
  final String access;
  final String refresh;
  final RMe me;
  const RAuth(this.access, this.refresh, this.me);
}

/// Всё, что экран «Сообщество» умеет спросить у сервера.
abstract class RitmCommunityApi {
  Future<RAuth> signInApple(String identityToken, String rawNonce, String? name);
  Future<RAuth> signInTest(String name);
  Future<RMe> me();
  Future<RMe> putMe({String? name});
  Future<RMe> consent(String version);
  Future<RMe> sharing(RSharing s);
  Future<void> deleteMe();
  Future<void> uploadPhoto(List<int> bytes);
  Future<List<RTeam>> teams(RMetric metric, String date);
  Future<RTeam> createTeam(String name, String emoji);
  Future<RTeam> join(String code);
  Future<void> leave(int teamId);
  Future<RBoard> leaderboard(int teamId, RPeriod p, RMetric m, String date);
  Future<List<RFeedItem>> feed(int teamId, String date);
  Future<bool> react(int teamId, int summaryId, int item, String emoji);
  Future<void> putSummary(RDaySummary s, RSharing sharing);

  // ── B6: чат команды и пуши (по умолчанию — пусто, чтобы старые реализации работали) ──

  /// История (старые → новые) и «без звука» для этой команды.
  Future<(List<RMessage>, bool)> messages(int teamId, {int? before}) async => (const <RMessage>[], false);
  Future<RMessage> sendMessage(int teamId, String text) => throw const RApiError(0, 'network');
  Future<void> deleteMessage(int teamId, int id) async {}
  Future<void> setMute(int teamId, bool muted) async {}
  Future<void> putDevice(String token, {bool sandbox = false}) async {}

  /// Живой чат (WebSocket). Закрывается, когда отписались.
  Stream<RChatEvent> chat(int teamId, {int? myId}) => const Stream.empty();

  /// Адрес фото участника и заголовки (null — фото нет).
  String? photoUrl(int userId) => null;
  Map<String, String> get authHeaders => const {};

  /// Сессия: подставить токены после входа / сбросить при выходе.
  void setTokens(String? access, String? refresh) {}
}

/// Хранилище токенов (в приложении — Keychain).
abstract class RitmTokenStore {
  Future<(String?, String?)> read();
  Future<void> write(String? access, String? refresh);
}

class RitmSecureTokenStore implements RitmTokenStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<(String?, String?)> read() async {
    try {
      return (
        await _s.read(key: 'ritm.community.access'),
        await _s.read(key: 'ritm.community.refresh'),
      );
    } catch (_) {
      return (null, null);
    }
  }

  @override
  Future<void> write(String? access, String? refresh) async {
    try {
      if (access == null) {
        await _s.delete(key: 'ritm.community.access');
        await _s.delete(key: 'ritm.community.refresh');
      } else {
        await _s.write(key: 'ritm.community.access', value: access);
        await _s.write(key: 'ritm.community.refresh', value: refresh);
      }
    } catch (_) {}
  }
}

class RitmMemoryTokenStore implements RitmTokenStore {
  String? a, r;
  @override
  Future<(String?, String?)> read() async => (a, r);
  @override
  Future<void> write(String? access, String? refresh) async {
    a = access;
    r = refresh;
  }
}

class RitmHttpApi extends RitmCommunityApi {
  final String base;
  final http.Client _http;
  final RitmTokenStore store;
  String? _access, _refresh;

  RitmHttpApi({String? base, http.Client? client, required this.store})
    : base = base ?? kRitmServer,
      _http = client ?? http.Client();

  @override
  void setTokens(String? access, String? refresh) {
    _access = access;
    _refresh = refresh;
  }

  @override
  Map<String, String> get authHeaders =>
      _access == null ? const {} : {'Authorization': 'Bearer $_access'};

  @override
  String? photoUrl(int userId) => '$base/users/$userId/photo';

  Future<dynamic> _call(
    String method,
    String path, {
    Object? body,
    List<int>? raw,
    Map<String, String>? query,
    bool auth = true,
    bool retried = false,
  }) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final h = <String, String>{
      if (body != null) 'Content-Type': 'application/json',
      if (raw != null) 'Content-Type': 'application/octet-stream',
      if (auth) ...authHeaders,
    };
    http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(h);
      if (body != null) req.bodyBytes = utf8.encode(jsonEncode(body));
      if (raw != null) req.bodyBytes = raw;
      r = await http.Response.fromStream(
        await _http.send(req).timeout(const Duration(seconds: 20)),
      );
    } catch (_) {
      throw const RApiError(0, 'network');
    }
    if (r.statusCode == 401 && auth && !retried && _refresh != null) {
      if (await _refreshTokens()) {
        return _call(method, path,
            body: body, raw: raw, query: query, auth: auth, retried: true);
      }
    }
    final text = utf8.decode(r.bodyBytes);
    dynamic j;
    try {
      j = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 400) {
      final d = j is Map ? j['detail'] : null;
      throw RApiError(r.statusCode, d is String ? d : 'http_${r.statusCode}');
    }
    return j;
  }

  Future<bool> _refreshTokens() async {
    try {
      final j = await _call('POST', '/auth/refresh',
          body: {'refresh_token': _refresh}, auth: false, retried: true);
      _access = j['access_token'] as String?;
      _refresh = j['refresh_token'] as String?;
      await store.write(_access, _refresh);
      return _access != null;
    } catch (_) {
      return false;
    }
  }

  RAuth _auth(dynamic j) {
    final a = RAuth(
      j['access_token'] as String,
      j['refresh_token'] as String,
      RMe.fromJson((j['user'] as Map).cast<String, dynamic>()),
    );
    _access = a.access;
    _refresh = a.refresh;
    return a;
  }

  Map<String, dynamic> _m(dynamic j) => (j as Map).cast<String, dynamic>();

  @override
  Future<RAuth> signInApple(String token, String rawNonce, String? name) async =>
      _auth(await _call('POST', '/auth/apple', auth: false, body: {
        'identity_token': token,
        'nonce': rawNonce,
        if (name != null && name.trim().isNotEmpty)
          'display_name': name.trim(),
      }));

  @override
  Future<RAuth> signInTest(String name) async {
    if (!kRitmTestLogin) throw const RApiError(404, 'test_login_off');
    return _auth(
      await _call('POST', '/auth/test', auth: false, body: {'name': name}),
    );
  }

  @override
  Future<RMe> me() async => RMe.fromJson(_m(await _call('GET', '/me')));

  @override
  Future<RMe> putMe({String? name}) async => RMe.fromJson(_m(await _call(
      'PUT', '/me',
      body: {if (name != null && name.trim().isNotEmpty) 'display_name': name.trim()})));

  @override
  Future<RMe> consent(String version) async =>
      RMe.fromJson(_m(await _call('POST', '/me/consent', body: {
        'version': version,
        'processing': true,
        'share_team': true,
      })));

  @override
  Future<RMe> sharing(RSharing s) async =>
      RMe.fromJson(_m(await _call('PUT', '/me/sharing', body: s.toJson())));

  @override
  Future<void> deleteMe() async => _call('DELETE', '/me');

  @override
  Future<void> uploadPhoto(List<int> bytes) async =>
      _call('PUT', '/me/photo', raw: bytes);

  @override
  Future<List<RTeam>> teams(RMetric metric, String date) async {
    final j = _m(await _call('GET', '/teams',
        query: {'metric': metric.key, 'date': date}));
    return [
      for (final t in (j['teams'] as List? ?? const []))
        RTeam.fromJson((t as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<RTeam> createTeam(String name, String emoji) async => RTeam.fromJson(
      _m(await _call('POST', '/teams', body: {'name': name, 'emoji': emoji})));

  @override
  Future<RTeam> join(String code) async => RTeam.fromJson(
      _m(await _call('POST', '/teams/join', body: {'code': code})));

  @override
  Future<void> leave(int teamId) async =>
      _call('DELETE', '/teams/$teamId/members/me');

  @override
  Future<RBoard> leaderboard(int teamId, RPeriod p, RMetric m, String date) async {
    final j = _m(await _call('GET', '/teams/$teamId/leaderboard', query: {
      'period': p.name,
      'metric': m.key,
      'date': date,
    }));
    return RBoard(
      RTeam.fromJson(_m(j['team'])),
      [for (final r in j['rows'] as List) RBoardRow.fromJson(_m(r))],
    );
  }

  @override
  Future<List<RFeedItem>> feed(int teamId, String date) async {
    final j = _m(await _call('GET', '/teams/$teamId/feed', query: {'date': date}));
    return [for (final x in j['items'] as List) RFeedItem.fromJson(_m(x))];
  }

  @override
  Future<bool> react(int teamId, int summaryId, int item, String emoji) async {
    final j = _m(await _call('POST', '/teams/$teamId/react',
        body: {'summary_id': summaryId, 'item': item, 'emoji': emoji}));
    return j['on'] == true;
  }

  @override
  Future<void> putSummary(RDaySummary s, RSharing sharing) async =>
      _call('PUT', '/summary/${s.date}', body: s.toJson(sharing));

  @override
  Future<(List<RMessage>, bool)> messages(int teamId, {int? before}) async {
    final j = _m(await _call('GET', '/teams/$teamId/messages', query: {'before': ?before?.toString()}));
    return ([for (final x in j['items'] as List) RMessage.fromJson(_m(x))], j['muted'] == true);
  }

  @override
  Future<RMessage> sendMessage(int teamId, String text) async =>
      RMessage.fromJson(_m(await _call('POST', '/teams/$teamId/messages', body: {'text': text})));

  @override
  Future<void> deleteMessage(int teamId, int id) async => _call('DELETE', '/teams/$teamId/messages/$id');

  @override
  Future<void> setMute(int teamId, bool muted) async =>
      _call('PUT', '/teams/$teamId/mute', body: {'muted': muted});

  @override
  Future<void> putDevice(String token, {bool sandbox = false}) async =>
      _call('PUT', '/me/devices', body: {'token': token, 'sandbox': sandbox});

  @override
  Stream<RChatEvent> chat(int teamId, {int? myId}) {
    late StreamController<RChatEvent> out;
    WebSocket? ws;
    Timer? ping;
    var closed = false;
    Future<void> open() async {
      final a = _access;
      if (a == null || closed) return;
      final u = Uri.parse(base).replace(
        scheme: base.startsWith('https') ? 'wss' : 'ws',
        path: '${Uri.parse(base).path}/teams/$teamId/chat',
        queryParameters: {'token': a},
      );
      try {
        ws = await WebSocket.connect(u.toString()).timeout(const Duration(seconds: 10));
      } catch (_) {
        if (!closed) Timer(const Duration(seconds: 3), open);
        return;
      }
      ping = Timer.periodic(const Duration(seconds: 25), (_) => ws?.add('ping'));
      ws!.listen(
        (m) {
          if (m is! String || m == 'pong') return;
          final j = (jsonDecode(m) as Map).cast<String, dynamic>();
          if (j['type'] == 'message') {
            out.add((message: RMessage.fromJson(j, myId: myId), deletedId: null));
          } else if (j['type'] == 'deleted') {
            out.add((message: null, deletedId: (j['id'] as num).toInt()));
          }
        },
        onDone: () {
          ping?.cancel();
          // Сеть пропала или сервер перезапустился — переподключаемся.
          if (!closed) Timer(const Duration(seconds: 2), open);
        },
        cancelOnError: true,
      );
    }

    out = StreamController<RChatEvent>(
      onListen: open,
      onCancel: () async {
        closed = true;
        ping?.cancel();
        await ws?.close();
      },
    );
    return out.stream;
  }
}

// ───────────────────────── синхронизация итогов ─────────────────────────

/// Когда отправлять итоги: при изменении — не чаще раза в час; новая ночь
/// (сон/восстановление поменялись) — сразу. Неизменённое не шлём.
class RitmSummarySync {
  final Duration every;
  RitmSummarySync({this.every = const Duration(hours: 1)});

  final Map<String, String> _sentSig = {};
  final Map<String, String> _sentNight = {};
  DateTime? _lastAt;
  RDaySummary? pending;

  DateTime? get lastAt => _lastAt;

  bool due(RDaySummary s, RSharing sh, DateTime now) {
    if (s.isEmpty) return false;
    final sig = s.signature(sh);
    if (_sentSig[s.date] == sig) return false;
    final night = s.nightKey;
    final nightChanged = (s.sleepPct != null || s.recovery != null) &&
        _sentNight[s.date] != night;
    if (nightChanged) return true;
    final last = _lastAt;
    return last == null || now.difference(last) >= every;
  }

  bool isSent(RDaySummary s, RSharing sh) => _sentSig[s.date] == s.signature(sh);

  void markSent(RDaySummary s, RSharing sh, DateTime now) {
    _sentSig[s.date] = s.signature(sh);
    _sentNight[s.date] = s.nightKey;
    _lastAt = now;
    // pending не сбрасываем: после смены переключателей тот же итог уходит
    // заново (с новым набором полей); повтор без изменений отсекает [isSent].
  }

  /// Сброс (выход / смена переключателей — отправить заново).
  void reset() {
    _sentSig.clear();
    _sentNight.clear();
    _lastAt = null;
  }

  Map<String, dynamic> toJson() => {
    'sig': _sentSig,
    'night': _sentNight,
    'at': _lastAt?.toIso8601String(),
  };

  void load(Map<String, dynamic> j) {
    _sentSig
      ..clear()
      ..addAll(((j['sig'] as Map?) ?? const {}).cast<String, String>());
    _sentNight
      ..clear()
      ..addAll(((j['night'] as Map?) ?? const {}).cast<String, String>());
    _lastAt = DateTime.tryParse((j['at'] ?? '').toString());
  }
}

// ───────────────────────── состояние ─────────────────────────

enum RStage { loading, signedOut, needsConsent, ready }

/// Сессия «Сообщества»: вход, согласие, команды, отправка итогов.
class RitmCommunity extends ChangeNotifier {
  RitmCommunity({
    required this.api,
    RitmTokenStore? store,
    this.clock = DateTime.now,
    this.persist = true,
  }) : store = store ?? RitmSecureTokenStore();

  static RitmCommunity? _i;

  /// Общий экземпляр приложения (в DEBUG-демо — с демо-сервером).
  static RitmCommunity get I => _i ??= _factory();
  static set I(RitmCommunity v) => _i = v;
  static RitmCommunity Function() _factory = () {
    final st = RitmSecureTokenStore();
    return RitmCommunity(api: RitmHttpApi(store: st), store: st);
  };
  static void useFactory(RitmCommunity Function() f) {
    _factory = f;
    _i = null;
  }

  final RitmCommunityApi api;
  final RitmTokenStore store;
  final DateTime Function() clock;
  final bool persist;
  final sync = RitmSummarySync();

  RStage stage = RStage.loading;
  RMe? me;
  List<RTeam> teams = const [];
  RMetric metric = RMetric.strainDay;
  String? error;
  bool busy = false;
  bool _started = false;
  Timer? _timer;

  String get today => ritmDayId(clock());

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (persist) {
      try {
        final p = await SharedPreferences.getInstance();
        final j = p.getString('ritm.community.sync');
        if (j != null) sync.load((jsonDecode(j) as Map).cast<String, dynamic>());
      } catch (_) {}
    }
    final (a, r) = await store.read();
    if (a == null) {
      stage = RStage.signedOut;
      notifyListeners();
      return;
    }
    api.setTokens(a, r);
    try {
      me = await api.me();
      stage = me!.needsConsent ? RStage.needsConsent : RStage.ready;
    } on RApiError catch (e) {
      if (e.status == 401) {
        await _clear();
      } else {
        // Нет сети: остаёмся «вошёл», данные подтянутся позже.
        stage = RStage.ready;
        error = e.message;
      }
    }
    notifyListeners();
    if (stage == RStage.ready) unawaited(refreshTeams());
    _timer ??= Timer.periodic(const Duration(minutes: 15), (_) => flush());
  }

  Future<void> _clear() async {
    api.setTokens(null, null);
    await store.write(null, null);
    me = null;
    teams = const [];
    sync.reset();
    await _saveSync();
    stage = RStage.signedOut;
  }

  Future<void> _saveSync() async {
    if (!persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('ritm.community.sync', jsonEncode(sync.toJson()));
    } catch (_) {}
  }

  Future<void> _afterAuth(RAuth a, String? localName) async {
    await store.write(a.access, a.refresh);
    me = a.me;
    // Имя — из профиля «Ритма» (не из Apple), если оно есть.
    if (localName != null &&
        localName.trim().isNotEmpty &&
        localName.trim() != me!.name) {
      try {
        me = await api.putMe(name: localName);
      } catch (_) {}
    }
    stage = me!.needsConsent ? RStage.needsConsent : RStage.ready;
    error = null;
    notifyListeners();
    if (stage == RStage.ready) unawaited(refreshTeams());
  }

  /// Вход через Apple: [identityToken] и одноразовая строка [rawNonce]
  /// (Apple получил её SHA-256).
  Future<bool> signInApple(String identityToken, String rawNonce,
      {String? appleName, String? localName}) async {
    return _guard(() async {
      final a = await api.signInApple(
          identityToken, rawNonce, localName ?? appleName);
      await _afterAuth(a, localName);
    });
  }

  Future<bool> signInTest(String name) =>
      _guard(() async => _afterAuth(await api.signInTest(name), name));

  /// Обе галочки отмечены → версия согласия на сервер.
  Future<bool> acceptConsent({required bool processing, required bool team}) {
    if (!processing || !team) return Future.value(false);
    return _guard(() async {
      me = await api.consent(kRitmConsentVersion);
      stage = me!.needsConsent ? RStage.needsConsent : RStage.ready;
      notifyListeners();
      unawaited(refreshTeams());
      unawaited(flush(force: true));
    });
  }

  Future<void> refreshTeams() async {
    if (stage != RStage.ready) return;
    try {
      teams = await api.teams(metric, today);
      error = null;
    } on RApiError catch (e) {
      error = e.message;
      if (e.code == 'consent_required') stage = RStage.needsConsent;
      if (e.status == 401) await _clear();
    }
    notifyListeners();
  }

  void setMetric(RMetric m) {
    if (m == metric) return;
    metric = m;
    notifyListeners();
    unawaited(refreshTeams());
  }

  Future<RTeam?> createTeam(String name, String emoji) async {
    RTeam? t;
    await _guard(() async {
      t = await api.createTeam(name.trim(), emoji);
      await refreshTeams();
    });
    return t;
  }

  Future<RTeam?> join(String code) async {
    RTeam? t;
    await _guard(() async {
      t = await api.join(code.trim().toUpperCase());
      await refreshTeams();
    });
    return t;
  }

  Future<bool> leave(int teamId) =>
      _guard(() async {
        await api.leave(teamId);
        await refreshTeams();
      });

  /// Переключатели публикации. Выключенное сервер стирает; включённое —
  /// отправляем заново ближайшей синхронизацией.
  Future<bool> setSharing(RSharing s, {List<int>? photo}) => _guard(() async {
    me = await api.sharing(s);
    if (s.photo && photo != null) {
      try {
        await api.uploadPhoto(photo);
      } catch (_) {}
    }
    sync.reset();
    await _saveSync();
    notifyListeners();
    unawaited(flush(force: true));
  });

  /// Полное удаление аккаунта на сервере (после подтверждения на экране).
  Future<bool> deleteAccount() => _guard(() async {
    await api.deleteMe();
    await _clear();
  });

  Future<void> signOut() async {
    await _clear();
    notifyListeners();
  }

  /// Главная предлагает свежие итоги дня; отправка — по правилам [sync].
  Future<bool> offerSummary(RDaySummary s) async {
    sync.pending = s;
    return flush();
  }

  Future<bool> flush({bool force = false}) async {
    final s = sync.pending;
    final m = me;
    if (s == null || m == null || stage != RStage.ready) return false;
    final now = clock();
    if (force ? (s.isEmpty || sync.isSent(s, m.sharing)) : !sync.due(s, m.sharing, now)) {
      return false;
    }
    try {
      await api.putSummary(s, m.sharing);
      sync.markSent(s, m.sharing, now);
      await _saveSync();
      return true;
    } on RApiError catch (e) {
      if (e.code == 'consent_required') {
        stage = RStage.needsConsent;
        notifyListeners();
      }
      return false;
    }
  }

  Future<bool> _guard(Future<void> Function() f) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await f();
      return true;
    } on RApiError catch (e) {
      error = e.message;
      if (e.status == 401 && stage != RStage.signedOut) await _clear();
      return false;
    } catch (_) {
      error = const RApiError(0, 'x').message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Одноразовая строка для Sign in with Apple и её SHA-256 (уходит в Apple).
({String raw, String hashed}) ritmNonce() {
  final r = math.Random.secure();
  const cs = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz';
  final raw = List.generate(32, (_) => cs[r.nextInt(cs.length)]).join();
  return (raw: raw, hashed: sha256.convert(utf8.encode(raw)).toString());
}
