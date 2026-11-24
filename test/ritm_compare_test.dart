// «Ритм» B4½: импорт CSV WHOOP и сверка (ТЗ v3 §8). Фикстура 90 дней
// (test/fixtures/ritm_compare) создана `tool/ritm_compare.py synth`, ожидаемая
// сводка expected.json — тем же скриптом `compare --json`: Dart и Python
// обязаны совпасть до округления (§8.3 п. 1).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ritm/ritm_compare.dart';
import 'package:openstrap_edge/ritm/ritm_whoop_csv.dart';

const _dir = 'test/fixtures/ritm_compare';

Map<String, String> _files() => {
  for (final f in const [
    'physiological_cycles.csv',
    'sleeps.csv',
    'workouts.csv',
    'journal_entries.csv',
  ])
    f: File('$_dir/$f').readAsStringSync(),
};

void main() {
  group('импорт CSV WHOOP (официальный формат)', () {
    test('вид файла — по заголовку, не по имени', () {
      final f = _files();
      expect(whoopFileKind(f['physiological_cycles.csv']!), 'cycles');
      expect(whoopFileKind(f['sleeps.csv']!), 'sleeps');
      expect(whoopFileKind(f['workouts.csv']!), 'workouts');
      expect(whoopFileKind(f['journal_entries.csv']!), 'journal');
      expect(whoopFileKind('a,b\n1,2\n'), isNull);
    });

    test('все четыре файла: дни по пробуждению, поля сна, тренировки, дневник', () {
      final w = parseWhoopExport({
        // имена перепутаны нарочно
        'x.csv': _files()['workouts.csv']!,
        'y.csv': _files()['physiological_cycles.csv']!,
        'z.csv': _files()['sleeps.csv']!,
        'j.csv': _files()['journal_entries.csv']!,
      });
      expect(w.files, {'cycles', 'sleeps', 'workouts', 'journal'});
      expect(w.cycles.length, 90);
      expect(w.cycles.first.day, '2026-07-01'); // файл WHOOP — новые сверху
      final c = w.cycles.first;
      expect(c.recovery, isNotNull);
      expect(c.hrv, isNotNull);
      expect(c.sleep.deep, isNotNull);
      expect(c.sleep.need, isNotNull);
      expect(c.sleep.consistency, isNotNull);
      expect(w.sleeps.length, 90);
      expect(w.sleeps.every((s) => !s.nap), isTrue);
      expect(w.workouts.where((x) => x.strength).length, greaterThan(0));
      expect(w.workouts.first.zones.length, 5);
      expect(w.journal.first.yes, isFalse);
      expect(w.journal.first.question, contains('alcoholic'));
    });

    test('кавычки, BOM, «%» и вечерний старт цикла без Wake onset', () {
      const csv = '\uFEFFCycle start time,Cycle end time,Recovery score %,'
          'Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Sleep onset,Wake onset\n'
          '2026-10-14 23:40:00,,"71%",51,"62",8.4,2026-10-14 23:40:00,\n';
      final c = parseCycles(csv).single;
      expect(c.day, '2026-10-15');
      expect(c.recovery, 71);
      expect(c.hrv, 62);
      expect(c.strain, 8.4);
    });
  });

  group('сверка: Dart = Python на фикстуре 90 дней', () {
    final w = parseWhoopExport(_files());
    final ours = parseRitmExport(File('$_dir/ritm_export.csv').readAsStringSync());
    final rep = compareWhoop(w, ours);
    final exp = jsonDecode(File('$_dir/expected.json').readAsStringSync()) as Map;

    test('наш экспорт читается, колонки фиксированы', () {
      expect(ours.length, 90);
      expect(ours.first.vHist.split(';').length, 24);
      final again = parseRitmExport(ritmExportCsv(ours));
      expect(again.length, 90);
      expect(again[5]['rmssd_sws_last'], ours[5]['rmssd_sws_last']);
      expect(again[5].wake, ours[5].wake);
    });

    test('выравнивание, чистые дни, трети', () {
      expect(rep.cleanDays, exp['clean_days']);
      expect(rep.alignFail, exp['align_fail']);
      expect(rep.alignFail, 1); // день 40: подъём разошёлся на 3 ч
      expect(rep.validFrom, exp['valid_from']);
      expect(rep.preliminary, exp['preliminary']);
      expect(rep.rows.where((r) => r.dirty.contains('observed')).length, 2);
    });

    test('каждый показатель: n, MAE, смещение, медиана, r, доля, итог', () {
      final m = exp['metrics'] as Map;
      for (final key in m.keys) {
        final e = m[key] as Map, r = rep.results[key]!;
        for (final part in const ['all', 'calib', 'valid']) {
          final es = e[part] as Map;
          final s = switch (part) {
            'all' => r.all,
            'calib' => r.calib,
            _ => r.valid,
          };
          expect(s.n, es['n'], reason: '$key/$part n');
          void near(double? got, Object? want, String what) {
            if (want == null) {
              expect(got, isNull, reason: '$key/$part $what');
            } else {
              expect(got, closeTo((want as num).toDouble(), 0.0015), reason: '$key/$part $what');
            }
          }

          near(s.mae, es['mae'], 'mae');
          near(s.bias, es['bias'], 'bias');
          near(s.median, es['median'], 'median');
          near(s.r, es['r'], 'r');
          near(s.share, es['share'], 'share');
        }
        expect(r.pass, e['pass_'], reason: '$key pass');
      }
      expect(rep.recZoneAgree, closeTo((exp['rec_zone_agree'] as num).toDouble(), 0.0015));
      expect(rep.sleepZoneAgree, closeTo((exp['sleep_zone_agree'] as num).toDouble(), 0.0015));
    });

    test('красный показатель роняет вкладку; силовые не сверяются по Нагрузке', () {
      expect(rep.results['rhr']!.pass, isFalse); // в синтетике r пульса < 0,90
      expect(rep.passTab('rings'), isFalse);
      final strainN = rep.results['strain']!.all.n;
      final cleanN = rep.rows.where((r) => r.clean).length;
      expect(strainN, lessThan(cleanN));
      expect(rep.cellOk('hrv', 9.9), isTrue);
      expect(rep.cellOk('hrv', 10.5), isFalse);
    });
  });

  test('допуски §8.2 в коде совпадают с ТЗ', () {
    expect(cmpMetric('rhr').tol.mae, 2);
    expect(cmpMetric('hrv').tol.mae, 8);
    expect(cmpMetric('tst').tol.mae, 15);
    expect(cmpMetric('recovery').tol.mae, 8);
    expect(cmpMetric('strain').tol.mae, 1.5);
    expect(cmpMetric('rhr').tol.share, 0.85);
    expect(cmpMetric('hrv').tol.within, 10);
    expect(kCmpMetrics.where((m) => m.required && m.tab == 'rings').map((m) => m.key).toSet(),
        {'recovery', 'strain', 'hrv', 'rhr', 'resp', 'sleep_pct'});
  });

  test('< 30 чистых дней → предварительно, допуски ×1,5', () {
    final w = parseWhoopExport(_files());
    final ours = parseRitmExport(File('$_dir/ritm_export.csv').readAsStringSync()).take(20).toList();
    final r = compareWhoop(w, ours);
    expect(r.preliminary, isTrue);
    expect(r.mult, 1.5);
    expect(r.cellOk('rhr', 4.4), isTrue); // 3 × 1,5
  });
}
