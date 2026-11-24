// «Ритм» B6½ — Помощник v2: проверка цифр, снимок, «Что видела модель»,
// расход, ошибки/офлайн, русская надстройка и переключатели доступа.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_responses.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/tap_router.dart';
import 'package:openstrap_edge/ritm/ritm_ai.dart';
import 'package:openstrap_edge/ritm/ritm_ai_demo.dart';
import 'package:openstrap_edge/ritm/ritm_ai_ui.dart';
import 'package:openstrap_edge/ritm/ritm_demo.dart' show ritmDemoRings;
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _snap() {
  final r = ritmDemoRings(DateTime(2026, 10, 16));
  return ritmAiSnapshot(r, strainYesterday: 12.8);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    kRitmAiMemoryOnly = true;
    RitmAiLog.debugReset();
    RitmAiCache.debugReset();
    RitmAi.debugTransport = null;
    RitmAiPrefs.blockUntilMs = 0;
  });

  group('механическая проверка (A5)', () {
    test('чужая цифра → пункт скрыт, свои — видны', () {
      final s = _snap();
      final hrv = s['night']['hrv_ms'], hrvN = s['norms_30d']['hrv_ms'];
      final a = ritmAiVerify({
        'headline': 'Восстановление ${s['recovery']['pct']} %',
        'reasons': [
          {'claim': 'ВСР $hrv мс выше нормы $hrvN', 'metric': 'night.hrv_ms', 'value': hrv, 'baseline': hrvN},
          // value не совпадает со снимком
          {'claim': 'ВСР 77 мс', 'metric': 'night.hrv_ms', 'value': 77, 'baseline': null},
          // метрика и value верны, но в тексте чужое число
          {'claim': 'ВСР $hrv мс, лучшая за 93 дня', 'metric': 'night.hrv_ms', 'value': hrv, 'baseline': null},
          // нет такого поля
          {'claim': 'SpO₂ 97 %', 'metric': 'night.spo2', 'value': 97, 'baseline': null},
          // чужая норма
          {'claim': 'ВСР $hrv против 61', 'metric': 'night.hrv_ms', 'value': hrv, 'baseline': 61},
          // без числа
          {'claim': 'Вы молодец', 'metric': 'night.hrv_ms', 'value': hrv, 'baseline': null},
        ],
        'action': 'Нагрузка ${s['strain']['target_lo']}–${s['strain']['target_hi']}',
        'confidence': 'high',
      }, s);
      expect(a.shown.length, 1);
      expect(a.hidden, 5);
      expect(a.reasons[1].why, startsWith('value'));
      expect(a.reasons[2].why, 'чужая цифра 93');
      expect(a.reasons[3].why, startsWith('нет поля'));
      expect(a.reasons[4].why, startsWith('чужая норма'));
      expect(a.reasons[5].why, 'нет числа');
      expect(a.headlineOk, isTrue);
      expect(a.actionOk, isTrue);
    });

    test('разница value−baseline, Ч:ММ и время суток проходят; чужой заголовок заменяется пунктом', () {
      final s = _snap();
      final hrv = s['night']['hrv_ms'] as num, hrvN = s['norms_30d']['hrv_ms'] as num;
      final a = ritmAiVerify({
        'headline': 'Восстановление 99 % — лучшее за год',
        'reasons': [
          {'claim': 'ВСР $hrv — на ${hrv - hrvN} мс выше нормы $hrvN', 'metric': 'night.hrv_ms', 'value': hrv, 'baseline': hrvN},
          {'claim': 'Спали ${s['sleep']['asleep_hm']} из ${s['sleep']['need_hm']}, отбой в ${s['sleep']['bedtime']}', 'metric': 'sleep.asleep_hm', 'value': s['sleep']['asleep_hm'], 'baseline': null},
          // модель опустила раздел: «hrv_ms» однозначно → night.hrv_ms? нет: есть и norms_30d.hrv_ms
          {'claim': 'ВСР $hrv', 'metric': 'hrv_ms', 'value': hrv, 'baseline': null},
          {'claim': 'Дыхание ${s['night']['resp_rpm'].toString().replaceAll('.', ',')}', 'metric': 'resp_rpm', 'value': s['night']['resp_rpm'], 'baseline': null},
        ],
        'action': 'Без чисел',
        'confidence': 'medium',
      }, s);
      expect(a.reasons[0].ok, isTrue, reason: '${a.reasons[0].why}');
      expect(a.reasons[1].ok, isTrue, reason: '${a.reasons[1].why}');
      expect(a.reasons[2].ok, isFalse, reason: 'неоднозначное поле');
      expect(a.reasons[3].ok, isFalse, reason: 'resp_rpm есть и в night, и в norms_30d');
      expect(a.headlineOk, isFalse);
      expect(a.line, a.reasons[0].claim);
    });

    test('стадии при низкой уверенности — без выводов', () {
      final s = _snap();
      s['sleep']['stages_confidence'] = 'low';
      final deep = s['sleep']['stages_estimate']['deep_min'];
      final a = ritmAiVerify({
        'headline': 'Ок',
        'reasons': [
          {'claim': 'Глубокий сон $deep мин', 'metric': 'sleep.stages_estimate.deep_min', 'value': deep, 'baseline': null},
          {'claim': 'Пульс ${s['night']['resting_hr_bpm']}', 'metric': 'night.resting_hr_bpm', 'value': s['night']['resting_hr_bpm'], 'baseline': null},
        ],
        'action': '',
        'confidence': 'low',
      }, s);
      expect(a.reasons[0].ok, isFalse);
      expect(a.reasons[0].why, contains('стадии'));
      expect(a.reasons[1].ok, isTrue);
    });

    test('медицинские ярлыки скрываются', () {
      final s = _snap();
      final a = ritmAiVerify({
        'headline': '',
        'reasons': [
          {'claim': 'Похоже на апноэ: дыхание ${s['night']['resp_rpm']}', 'metric': 'night.resp_rpm', 'value': s['night']['resp_rpm'], 'baseline': null},
        ],
      }, s);
      expect(a.shown, isEmpty);
    });

    test('демо-«Утро»: 4 пункта видны, нарочно чужой — скрыт', () {
      final s = _snap();
      final a = ritmAiVerify(ritmAiDemoAnswer(RitmAiKind.morning, s), s);
      expect(a.shown.length, 4, reason: a.reasons.map((r) => '${r.claim}: ${r.why}').join('\n'));
      expect(a.hidden, 1);
      expect(a.headlineOk, isTrue);
      expect(a.actionOk, isTrue);
    });

    test('демо «Спросить» / «Отбой» / «Итоги недели» проходят проверку целиком', () {
      final r = ritmDemoRings(DateTime(2026, 10, 16));
      final now = DateTime(2026, 10, 16, 9, 41);
      for (final q in ['Почему такой сон?', 'Во сколько лечь сегодня?', 'Как эта ночь против обычных?', 'Сколько ещё нагрузки сегодня?', 'Почему я просыпался?']) {
        final screen = q.contains('нагрузки') ? 'strain' : (q.contains('просып') ? 'night' : 'sleep');
        final s = ritmAiSnapshot(r, kind: RitmAiKind.ask, plan: ritmTonightPlan(r, now), strainYesterday: 12.8, screen: screen, question: q);
        if (screen == 'night') s['screen_facts'] = {'awakenings_long': 2, 'awakenings_short': 7};
        final a = ritmAiVerify(ritmAiDemoAnswer(RitmAiKind.ask, s), s);
        expect(a.hidden, 0, reason: '$q: ${a.reasons.map((r) => r.why).toList()}');
        expect(a.shown, isNotEmpty);
        expect(a.headlineOk && a.actionOk, isTrue, reason: q);
      }
      final b = ritmAiSnapshot(r, kind: RitmAiKind.bedtime, plan: ritmTonightPlan(r, now), strainYesterday: 12.8);
      final ab = ritmAiVerify(ritmAiDemoAnswer(RitmAiKind.bedtime, b), b);
      expect(ab.hidden, 0, reason: '${ab.reasons.map((r) => r.why).toList()}');
      expect(ab.headline, startsWith('Отбой в ${b['tonight']['bedtime']}, чтобы закрыть ${b['tonight']['need_hm']}'));
    });
  });

  group('снимок и приватность (A6)', () {
    test('только агрегаты, без личного, ≤ 900 токенов', () {
      final s = _snap();
      final text = jsonEncode(s);
      for (final bad in ['name', 'birth', 'lat', 'lon', 'email', 'rr', 'ecg', 'series', 'hypnogram']) {
        expect(ritmAiFlatten(s).keys.any((k) => k.split('.').contains(bad)), isFalse, reason: bad);
      }
      expect(s['recovery']['zone'], isNotNull);
      expect(s['sleep']['stages_confidence'], isNotNull);
      expect(s['curves'], 'выключены пользователем');
      // ≈ 3,2 символа на токен для смеси JSON/кириллицы — с запасом.
      expect(text.length / 3.2, lessThan(900));
    });

    test('«Что видела модель» = ровно отправленный JSON; журнал хранит тот же', () async {
      String? seen;
      RitmAi.debugTransport = ({required String system, required String user, required RitmAiKind kind}) async {
        seen = user;
        expect(system, contains('по-русски'));
        return (text: jsonEncode(ritmAiDemoAnswer(kind, _snap())), usage: {'prompt_tokens': 2000, 'completion_tokens': 300}, model: 'gpt-5.4-mini');
      };
      final snap = _snap();
      final res = await RitmAi.run(RitmAiKind.morning, '2026-10-16', snap);
      final sentInPrompt = jsonDecode(seen!.substring(seen!.indexOf('{')));
      expect(sentInPrompt, equals(res.sent));
      expect(jsonDecode(res.sentPretty), equals(res.sent));
      expect(RitmAiLog.entries.value.single.sent, jsonEncode(snap));
      expect(RitmAiCache.get(RitmAiKind.morning, '2026-10-16'), isNotNull);
    });

    test('недельный снимок: 7 дней и медианы 4 недель', () {
      final w = ritmAiWeekDays(DateTime(2026, 10, 16));
      expect(w.week, isEmpty, reason: 'вне демо и без кэша колец — пусто');
      final days = <RitmWeekDay>[
        for (var i = 0; i < 7; i++)
          (day: '2026-10-${10 + i}', sleepPct: 80 + i, asleepMin: 420 + i, consistencyPct: 75, recoveryPct: i.isEven ? 60 + i : null, strain: 10.0 + i, rhr: 52, hrv: 45 + i),
      ];
      final prev = <RitmWeekDay>[
        for (var i = 0; i < 28; i++)
          (day: 'p$i', sleepPct: 86, asleepMin: 450, consistencyPct: 80, recoveryPct: 65, strain: 9.0, rhr: 53, hrv: 44),
      ];
      final s = ritmAiWeekSnapshot(days, prev);
      expect((s['days'] as List).length, 7);
      expect(s['this_week_median']['sleep_pct'], 83);
      expect(s['this_week_median']['asleep_hm'], '7:03');
      expect(s['prev_4_weeks_median']['sleep_pct'], 86);
      expect(s['missing'], contains('recovery_pct: есть за 4 из 7 дней'));
      final a = ritmAiVerify(ritmAiDemoAnswer(RitmAiKind.week, s), s);
      expect(a.hidden, 0, reason: '${a.reasons.map((r) => '${r.claim}: ${r.why}').toList()}');
      expect(a.shown.length, inInclusiveRange(6, 8));
    });
  });

  group('модель и расход (A1)', () {
    test('три кнопки и цены', () {
      expect(kRitmAiPresets.map((p) => p.title), ['Экономно', 'Умно', 'Свой']);
      expect(ritmAiPresetOf('gpt-5.4-mini'), 'economy');
      expect(ritmAiPresetOf('gpt-5.2'), 'smart');
      expect(ritmAiPresetOf('llama3'), 'custom');
      expect(ritmAiPriceOf('gpt-5.4-mini-2026-03-01')!.$1, 0.75);
      expect(ritmAiPriceOf('gpt-5.4')!.$1, 2.5);
      expect(ritmAiPriceOf('llama3'), isNull);
    });

    test('usage обоих API и стоимость', () {
      final r = ritmAiParseUsage({'input_tokens': 2500, 'input_tokens_details': {'cached_tokens': 1000}, 'output_tokens': 300})!;
      expect((r.input, r.cached, r.output), (2500, 1000, 300));
      final c = ritmAiParseUsage({'prompt_tokens': 10, 'completion_tokens': 5})!;
      expect((c.input, c.cached, c.output), (10, 0, 5));
      // 1500 × 0,75 + 1000 × 0,075 + 300 × 4,5 = 2550 → 0,00255 $
      expect(ritmAiCost('gpt-5.4-mini', r), closeTo(0.00255, 1e-9));
      expect(ritmUsd(0.004), '< 0,01 \$');
      expect(ritmUsd(0.19), '0,19 \$');
    });

    test('неделя обычного использования на mini — ≤ 0,4 \$ (приёмка B6½)', () {
      final now = DateTime(2026, 10, 16, 9, 41);
      RitmAiLog.debugReset(ritmAiDemoLog(now));
      final w = RitmAiLog.spent(DateTime(2026, 10, 10));
      expect(w.calls, greaterThan(20));
      expect(w.usd, lessThan(0.4));
      expect(w.partial, isFalse);
    });

    test('журнал хранит 30 дней', () async {
      final old = DateTime.now().subtract(const Duration(days: 31)).millisecondsSinceEpoch;
      RitmAiLog.debugReset([RitmAiLogEntry(ts: old, kind: RitmAiKind.chat, model: 'm', ok: true)]);
      await RitmAiLog.add(RitmAiLogEntry(ts: DateTime.now().millisecondsSinceEpoch, kind: RitmAiKind.chat, model: 'm', ok: true));
      expect(RitmAiLog.entries.value.length, 1);
    });
  });

  group('ошибки и офлайн (§5.7)', () {
    test('401 → «ключ», пауза час для автозапуска', () async {
      var calls = 0;
      RitmAi.debugTransport = ({required String system, required String user, required RitmAiKind kind}) async {
        calls++;
        throw CoachException('Provider error (401): bad key', status: 401);
      };
      final now = DateTime(2026, 10, 16, 8);
      await expectLater(RitmAi.run(RitmAiKind.morning, 'd', _snap(), auto: true, now: now), throwsA(isA<RitmAiError>().having((e) => e.code, 'code', 'key')));
      expect(calls, 1, reason: 'на 4xx не повторяем');
      expect(RitmAiPrefs.blocked(now.add(const Duration(minutes: 59))), isTrue);
      await expectLater(RitmAi.run(RitmAiKind.morning, 'd', _snap(), auto: true, now: now.add(const Duration(minutes: 30))), throwsA(isA<RitmAiError>()));
      expect(calls, 1, reason: 'автоматически — не чаще раза в час');
      expect(RitmAiPrefs.blocked(now.add(const Duration(minutes: 61))), isFalse);
      expect(RitmAiLog.entries.value.first.error, 'key');
    });

    test('429 → «лимит»', () async {
      RitmAi.debugTransport = ({required String system, required String user, required RitmAiKind kind}) async =>
          throw CoachException('Provider error (429): rate', status: 429);
      await expectLater(RitmAi.run(RitmAiKind.ask, 'q', _snap()), throwsA(isA<RitmAiError>().having((e) => e.code, 'code', 'limit')));
      expect(const RitmAiError('limit', '').ru, contains('Лимит'));
    });

    test('таймаут → одна повторная попытка, потом «нет сети»', () async {
      var calls = 0;
      RitmAi.debugTransport = ({required String system, required String user, required RitmAiKind kind}) async {
        calls++;
        throw TimeoutException('60 s');
      };
      await expectLater(RitmAi.run(RitmAiKind.morning, 'd', _snap()), throwsA(isA<RitmAiError>().having((e) => e.code, 'code', 'offline')));
      expect(calls, 2);
    });

    test('таймаут, затем ответ → успех со второй попытки', () async {
      var calls = 0;
      RitmAi.debugTransport = ({required String system, required String user, required RitmAiKind kind}) async {
        if (calls++ == 0) throw TimeoutException('60 s');
        return (text: jsonEncode(ritmAiDemoAnswer(kind, _snap())), usage: null, model: 'gpt-5.4-mini');
      };
      final r = await RitmAi.run(RitmAiKind.morning, 'd2', _snap());
      expect(r.answer.shown, isNotEmpty);
    });

    test('два одновременных «Утра» — один запрос', () async {
      var calls = 0;
      RitmAi.debugTransport = ({required String system, required String user, required RitmAiKind kind}) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return (text: jsonEncode(ritmAiDemoAnswer(kind, _snap())), usage: null, model: 'gpt-5.4-mini');
      };
      final a = RitmAi.run(RitmAiKind.morning, 'same', _snap());
      final b = RitmAi.run(RitmAiKind.morning, 'same', _snap());
      final r = await Future.wait([a, b]);
      expect(calls, 1);
      expect(identical(r[0], r[1]), isTrue);
    });

    test('без ключа — «nokey», ничего не уходит', () async {
      await expectLater(RitmAi.run(RitmAiKind.morning, 'd', _snap(), config: CoachConfig()), throwsA(isA<RitmAiError>().having((e) => e.code, 'code', 'nokey')));
      expect(RitmAiLog.entries.value, isEmpty);
    });

    test('офлайн: последний кэш с датой', () async {
      RitmAi.debugTransport = ritmAiDemoTransport();
      await RitmAi.run(RitmAiKind.morning, '2026-10-15', _snap(), now: DateTime(2026, 10, 15, 7));
      final last = RitmAiCache.latest(RitmAiKind.morning)!;
      expect(last.key, '2026-10-15');
      expect(ritmShortDate(DateTime.fromMillisecondsSinceEpoch(last.at)), '15 окт');
    });
  });

  group('чат: русская надстройка и доступ (A1, A6)', () {
    test('по умолчанию: кривые ночи и ЭКГ выключены', () async {
      await RitmAiPrefs.load();
      applyChatPolicy();
      expect(CoachEngine.systemOverlay, contains('ТОЛЬКО по-русски'));
      expect(CoachEngine.statusLines!.first, contains('ночь'));
      expect(CoachEngine.deniedTools, contains('get_ecg_reading'));
      expect(CoachDbPolicy.denied, containsAll(['v_series', 'v_hypnogram', 'v_ecg_readings']));
      expect(() => CoachDb.guardAndPrepare("SELECT v FROM v_series WHERE date='2026-10-16' AND series='hr_curve'"), throwsA(isA<SqlGuardError>()));
      expect(CoachDb.guardAndPrepare('SELECT AVG(resting_hr) FROM v_daily'), contains('v_daily'));
      await RitmAiPrefs.set(RitmAiPrefs.curves, true);
      expect(CoachDbPolicy.denied, isNot(contains('v_series')));
      expect(CoachDb.guardAndPrepare("SELECT v FROM v_series WHERE date='2026-10-16' AND series='hr_curve'"), contains('v_series'));
      await RitmAiPrefs.set(RitmAiPrefs.curves, false);
    });

    test('postChat: метка снимается, usage уходит в счётчик, Responses получает text.format', () async {
      Map<String, dynamic>? body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'status': 'completed',
                'content': [
                  {'type': 'output_text', 'text': '{"headline":"x","reasons":[],"action":"","confidence":"low"}'},
                ],
              },
            ],
            'usage': {'input_tokens': 900, 'output_tokens': 120},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final seen = <String?>[];
      CoachEngine.usageSink = (m, u, tag) => seen.add(tag);
      final msg = await CoachEngine.postChat(CoachConfig(), {
        'model': 'gpt-5.4-mini',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'response_format': {
          'type': 'json_schema',
          'json_schema': {'name': 'ritm_answer', 'strict': true, 'schema': kRitmAiSchema},
        },
        CoachEngine.kTagKey: 'morning',
      }, client: client);
      expect(body!.containsKey(CoachEngine.kTagKey), isFalse);
      expect(body!['text']['format']['type'], 'json_schema');
      expect(body!['text']['format']['name'], 'ritm_answer');
      expect(seen, ['morning']);
      expect((msg[CoachEngine.kUsageKey] as Map)['input_tokens'], 900);
      CoachEngine.usageSink = null;
    });

    test('Responses без response_format — без text', () {
      final r = CoachResponses.request({'model': 'm', 'messages': []}, apiBase: 'https://api.openai.com/v1');
      expect(r.containsKey('text'), isFalse);
    });
  });

  group('уведомления (A4)', () {
    test('«Итоги недели» и «Отбой» разрешены к расписанию, тап ведёт на экраны', () {
      expect(NotificationService.maySchedule(NotificationService.idRitmWeek), isTrue);
      expect(NotificationService.maySchedule(NotificationService.idRitmBedtime), isTrue);
      expect(resolveTapRoute(kRouteRitmWeek).screen, kRouteRitmWeek);
      expect(resolveTapRoute(kRouteRitmBedtime).screen, kRouteRitmBedtime);
    });
  });

  group('экран ответа', () {
    testWidgets('пункты с галочкой, скрытый — плашкой, 320 pt без переполнения', (t) async {
      final s = _snap();
      final res = RitmAiResult(
        kind: RitmAiKind.morning,
        key: '2026-10-16',
        raw: ritmAiDemoAnswer(RitmAiKind.morning, s),
        sent: s,
        model: 'gpt-5.4-mini',
        at: DateTime(2026, 10, 16, 7, 12).millisecondsSinceEpoch,
      );
      t.view.physicalSize = const Size(320, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RitmAiAnswerView(result: res)))));
      await t.pump();
      expect(find.textContaining('Глубокого сна 2:10'), findsNothing);
      expect(find.textContaining('Скрыт 1 пункт'), findsOneWidget);
      expect(find.textContaining('(оценка): у модели 130, в данных'), findsOneWidget);
      expect(find.text('ВСР в глубоком сне 52 мс — на 7 мс выше вашей нормы 45'), findsOneWidget);
      expect(find.text('ВСР в глубоком сне 52 мс · норма 45 мс'), findsOneWidget);
      expect(find.text('Что видела модель'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('без ключа «Утро» и «Спросить» не показываются', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [RitmMorningCard(rings: ritmDemoRings(DateTime(2026, 10, 16))), const RitmAskBar(screen: RitmAskScreenKind.sleep)]),
        ),
      ));
      await t.pump();
      expect(find.text('УТРО'), findsNothing);
      expect(find.text('СПРОСИТЬ ПОМОЩНИКА'), findsNothing);
    });
  });
}
