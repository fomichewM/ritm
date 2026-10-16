// «Ритм» — DEBUG-экран «Проверка канала Здоровья» (сборка B3).
//
// Только для тестовой сборки (DEBUG + RITM_DEMO): показывает, что пришло по
// Swift-каналу `ritm/health` — сколько записей каждого типа, последнее
// значение и чьё оно (Apple Watch / тестовая запись засева / синтетика Swift).
// Это доказательство для скриншотов, что SpO₂, VO₂max, ЭКГ и тренировка Watch
// идут ПО КАНАЛУ, а не из демо-заглушки Dart.

import 'package:flutter/material.dart';

import 'ritm_hk.dart';
import 'ritm_scores.dart' show clock, dec1, thousands;
import 'ritm_ui.dart';
import 'ritm_watch_store.dart';

class RitmHkCheckScreen extends StatelessWidget {
  const RitmHkCheckScreen({super.key});

  @override
  Widget build(BuildContext c) => ValueListenableBuilder<WatchData?>(
    valueListenable: RitmWatchStore.data,
    builder: (c, w, _) {
      final raw = RitmWatchStore.lastRaw;
      final seed = RitmWatchStore.seedResult;
      String who(HkSource s) => s.seed
          ? 'Apple Watch · тестовая запись засева'
          : (s.product.startsWith('Watch') ? 'Apple Watch' : 'другой источник');
      String hm(DateTime t) => clock(t.hour * 60 + t.minute);
      Widget row(String name, int n, String value, String src) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: RDot(n > 0 ? RC.green : RC.ink3),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$name · записей: $n', style: RT.title.copyWith(fontSize: 15)),
                  if (value.isNotEmpty) Text(value, style: RT.body.copyWith(color: RC.ink)),
                  if (src.isNotEmpty) Text(src, style: RT.small),
                ],
              ),
            ),
          ],
        ),
      );
      final rows = <Widget>[];
      if (raw != null) {
        final vo2 = raw.vo2.isEmpty ? null : raw.vo2.last;
        rows.add(row(
          'VO₂max',
          raw.vo2.length,
          vo2 == null ? '' : '${dec1(vo2.v)} мл/кг/мин · последний замер',
          vo2 == null ? '' : who(vo2.src),
        ));
        final sp = raw.spo2;
        rows.add(row(
          'SpO₂ ночью',
          sp.length,
          w?.spo2 == null
              ? ''
              : 'медиана ${w!.spo2!.round()} % за ночь (замеров Watch: ${w.spo2N})',
          sp.isEmpty ? '' : who(sp.first.src),
        ));
        final e = raw.ecg;
        rows.add(row(
          'ЭКГ Watch',
          e.length,
          e.isEmpty
              ? ''
              : '${watchEcgText(e.first.cls, e.first.hr).text} · ${hm(e.first.at)}',
          e.isEmpty
              ? ''
              : e.first.synthetic
              ? 'синтетическая запись: ЭКГ в «Здоровье» приложение записать не может'
              : who(e.first.src),
        ));
        final wk = raw.workouts;
        final w0 = wk.isEmpty ? null : wk.last;
        rows.add(row(
          'Тренировки',
          wk.length,
          w0 == null
              ? ''
              : '${hkTypeName(w0.type)} ${hm(w0.s)}–${hm(w0.e)} · ${w0.distM == null ? '' : distRu(w0.distM!)} · пульс ${w0.hrAvg?.round() ?? '—'} · замеров ${w0.hrN}',
          w0 == null ? '' : who(w0.src),
        ));
        rows.add(row(
          'Пульс покоя',
          raw.rhr.length,
          raw.rhr.isEmpty ? '' : '${raw.rhr.last.v.round()} уд/мин',
          raw.rhr.isEmpty ? '' : who(raw.rhr.last.src),
        ));
        rows.add(row(
          'Сон (стадии)',
          raw.sleep.length,
          w?.sleepMin == null ? '' : 'сон ${hmm(w!.sleepMin!)}',
          raw.sleep.isEmpty ? '' : who(raw.sleep.first.src),
        ));
        rows.add(row(
          'Шаги за сегодня',
          raw.steps.watch == null ? 0 : 1,
          raw.steps.watch == null
              ? ''
              : 'Watch ${thousands(raw.steps.watch!.round())} · все источники ${thousands((raw.steps.all ?? 0).round())} · часы ношения ${raw.steps.watchHours}',
          '',
        ));
        rows.add(row(
          'Температура запястья',
          raw.wristTemp.length,
          raw.wristTemp.isEmpty ? 'в симуляторе записать нельзя (тип только для Apple)' : '',
          '',
        ));
      }
      return RPage(
        title: 'Проверка канала Здоровья',
        children: [
          RCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const RCardHead('Только тестовая сборка', trailing: null),
                const SizedBox(height: 8),
                Text(
                  raw == null
                      ? 'Канал ещё не ответил.'
                      : 'Канал ответил: «Здоровье» ${raw.available ? 'доступно' : 'недоступно'}. Засев симулятора: ${seed == null ? 'нет' : (seed['ok'] == true ? 'да' : 'ошибка «${seed['error'] ?? ''}»')}${seed?['objects'] == null ? '' : ', записей ${seed!['objects']}'}.',
                  style: RT.body,
                ),
                ...rows,
              ],
            ),
          ),
        ],
      );
    },
  );
}

String hmm(int m) => '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
