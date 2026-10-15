// «Ритм» B4½ — экран «Сверка с WHOOP» (ТЗ v3 §8, U8/D11).
//
// Экспорт WHOOP (4 CSV или zip из письма WHOOP) → таблица по дням: WHOOP /
// Ритм / Δ, зелёный/красный по допускам §8.2, сводка MAE / r / зона на всех
// днях и на проверочной трети; вкладки «Кольца» / «Сон». Расчёт — один
// (`compareWhoop` в ritm_compare.dart = tool/ritm_compare.py).
//
// Отдельной карточкой — калибровка формул по экспорту WHOOP «вход → выход»
// (kRingTheta, build/CALIBRATION.md): что проверено и чего это НЕ доказывает.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'ritm_compare.dart';
import 'ritm_demo.dart' show kRitmDemo;
import 'ritm_rings.dart' show kRingTheta;
import 'ritm_rings_store.dart';
import 'ritm_scores.dart' show shortDayRu;
import 'ritm_ui.dart';
import 'ritm_whoop_csv.dart';

// ── хранение импортированного экспорта ──────────────────────────────────────

/// Последний импортированный экспорт WHOOP (CSV по видам) в документах.
class RitmWhoopFiles {
  static Future<Directory> _dir() async {
    final d = await getApplicationDocumentsDirectory();
    final x = Directory('${d.path}/whoop_csv');
    if (!x.existsSync()) x.createSync(recursive: true);
    return x;
  }

  /// Тексты CSV из выбранных файлов (csv и/или zip из письма WHOOP).
  static Map<String, String> textsOf(List<({String name, Uint8List bytes})> files) {
    final out = <String, String>{};
    for (final f in files) {
      final n = f.name.toLowerCase();
      if (n.endsWith('.zip')) {
        final a = ZipDecoder().decodeBytes(f.bytes);
        for (final e in a.files) {
          if (!e.isFile || !e.name.toLowerCase().endsWith('.csv')) continue;
          out[e.name.split('/').last] = utf8.decode(e.readBytes() ?? const [], allowMalformed: true);
        }
      } else if (n.endsWith('.csv')) {
        out[f.name] = utf8.decode(f.bytes, allowMalformed: true);
      }
    }
    return out;
  }

  /// Сохранить узнанные файлы (по виду; неизвестные — пропускаются).
  static Future<Set<String>> save(Map<String, String> texts) async {
    final dir = await _dir();
    final kinds = <String>{};
    for (final t in texts.values) {
      final k = whoopFileKind(t);
      if (k == null) continue;
      File('${dir.path}/$k.csv').writeAsStringSync(t);
      kinds.add(k);
    }
    if (kinds.isNotEmpty) {
      File('${dir.path}/imported_at').writeAsStringSync(DateTime.now().toIso8601String());
    }
    return kinds;
  }

  static Future<({WhoopExport w, DateTime? at})?> load() async {
    try {
      final dir = await _dir();
      final texts = <String, String>{};
      for (final k in const ['cycles', 'sleeps', 'workouts', 'journal']) {
        final f = File('${dir.path}/$k.csv');
        if (f.existsSync()) texts[k] = f.readAsStringSync();
      }
      if (texts.isEmpty) return null;
      final at = File('${dir.path}/imported_at');
      return (
        w: parseWhoopExport(texts),
        at: at.existsSync() ? DateTime.tryParse(at.readAsStringSync()) : null,
      );
    } catch (_) {
      return null;
    }
  }
}

// ── формат ───────────────────────────────────────────────────────────────────

String _num(double? x, {int dp = 0}) {
  if (x == null || x.isNaN) return '—';
  final s = x.toStringAsFixed(dp).replaceAll('.', ',');
  return s.startsWith('-') ? '−${s.substring(1)}' : s;
}

String _signed(double x, {int dp = 0}) {
  final r = double.parse(x.toStringAsFixed(dp));
  if (r == 0) return dp == 0 ? '0' : '0,${'0' * dp}';
  return '${r > 0 ? '+' : '−'}${r.abs().toStringAsFixed(dp).replaceAll('.', ',')}';
}

String _pct(double? x) => x == null ? '—' : '${(x * 100).round()}\u00a0%';

String _dm(String day) {
  final d = DateTime.tryParse(day);
  if (d == null) return day;
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
}

String _dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _tolText(CmpMetric m, double mult) {
  final t = m.tol;
  final u = m.unit.isEmpty ? '' : ' ${m.unit}';
  if (t.mae != null) return 'допуск ≤ ${_num(t.mae! * mult, dp: m.dp)}$u';
  if (t.share != null) return 'знак совпадает ≥ ${(t.share! * 100).round()} %';
  return '';
}

/// Подпись «грязного» дня.
String dirtyWord(CmpRow r) {
  if (r.alignFail) return 'дни не совпали (подъём ±2 ч)';
  final w = [
    for (final d in r.dirty)
      switch (d) {
        'observed' => 'браслет снят часть ночи',
        'hr_valid' => 'мало чистого пульса',
        'gap' => 'перерыв в записи > 2 ч',
        _ => d,
      },
  ];
  return w.join(', ');
}

// ── экран ────────────────────────────────────────────────────────────────────

/// Ключевые колонки таблицы по дням.
const Map<String, List<String>> kCmpDayCols = {
  'rings': ['recovery', 'strain', 'hrv', 'rhr'],
  'sleep': ['tst', 'onset', 'wake', 'deep'],
};

const Map<String, String> kCmpShort = {
  'recovery': 'Восст.',
  'strain': 'Нагр.',
  'hrv': 'ВСР',
  'rhr': 'Пульс',
  'tst': 'Сон',
  'onset': 'Отбой',
  'wake': 'Подъём',
  'deep': 'Глуб.',
};

class RitmWhoopCompareScreen extends StatefulWidget {
  /// Готовые данные (демо и тесты): экспорт WHOOP и наши дни.
  final WhoopExport? whoop;
  final List<RitmDayExport>? ours;
  final DateTime? importedAt;
  final String initialTab;

  /// Только демо-скриншоты: доля прокрутки (0…1).
  final double? demoScrollTo;
  const RitmWhoopCompareScreen({
    super.key,
    this.whoop,
    this.ours,
    this.importedAt,
    this.initialTab = 'rings',
    this.demoScrollTo,
    this.sample = false,
  });

  /// Пример на синтетических днях (демо): шапка честно говорит, что это не сверка.
  final bool sample;

  @override
  State<RitmWhoopCompareScreen> createState() => _RitmWhoopCompareScreenState();
}

class _RitmWhoopCompareScreenState extends State<RitmWhoopCompareScreen> {
  WhoopExport? _w;
  List<RitmDayExport> _ours = const [];
  DateTime? _at;
  CmpReport? _rep;
  bool _loading = true;
  String? _msg;
  late String _tab = widget.initialTab;
  final _scroll = ScrollController();

  bool get _fixed => widget.whoop != null;

  @override
  void initState() {
    super.initState();
    if (_fixed) {
      _apply(widget.whoop, widget.ours ?? const [], widget.importedAt);
      if (widget.demoScrollTo != null) {
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent * widget.demoScrollTo!);
          }
        });
      }
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _apply(WhoopExport? w, List<RitmDayExport> ours, DateTime? at) {
    _w = w;
    _ours = ours;
    _at = at;
    _rep = w == null ? null : compareWhoop(w, ours);
    _loading = false;
  }

  Future<void> _load() async {
    final x = await RitmWhoopFiles.load();
    final ours = RitmRingsStore.export();
    if (!mounted) return;
    setState(() => _apply(x?.w, ours, x?.at));
  }

  Future<void> _import() async {
    if (_fixed) return;
    try {
      final r = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['csv', 'zip'],
        withData: true,
      );
      if (r == null) return;
      final texts = RitmWhoopFiles.textsOf([
        for (final f in r.files)
          if (f.bytes != null) (name: f.name, bytes: f.bytes!),
      ]);
      final kinds = await RitmWhoopFiles.save(texts);
      setState(() => _msg = kinds.isEmpty
          ? 'Файлы не похожи на экспорт WHOOP — нужны physiological_cycles.csv, sleeps.csv, workouts.csv.'
          : 'Загружено: ${kinds.map((k) => switch (k) {
              'cycles' => 'циклы',
              'sleeps' => 'сны',
              'workouts' => 'тренировки',
              _ => 'дневник',
            }).join(', ')}.');
      await _load();
    } catch (e) {
      setState(() => _msg = 'Не удалось прочитать файлы: $e');
    }
  }

  Future<void> _export() async {
    if (_fixed) return;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/ritm_export.csv')..writeAsStringSync(ritmExportCsv(RitmRingsStore.export()));
    await Share.shareXFiles([XFile(f.path)], subject: 'Ритм — экспорт для сверки');
  }

  @override
  Widget build(BuildContext c) {
    return RPage(
      controller: _scroll,
      title: 'Сверка с WHOOP',
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          _status(c),
          const SizedBox(height: RS.cardGap),
          if (_rep != null && _rep!.rows.isNotEmpty) ...[
            _tabs(),
            const SizedBox(height: RS.cardGap),
            _summary(),
            const SizedBox(height: RS.cardGap),
            _days(),
            const SizedBox(height: RS.cardGap),
          ],
          _calibration(),
          const SizedBox(height: RS.cardGap),
          _actions(),
        ],
      ],
    );
  }

  // Итог одной строкой.
  Widget _status(BuildContext c) {
    final w = _w;
    final rep = _rep;
    String head;
    String body;
    Color dot;
    if (w == null || w.isEmpty) {
      head = 'Экспорт WHOOP не загружен';
      body = 'В приложении WHOOP: Профиль → Настройки приложения → Данные → Экспорт. '
          'Письмо с архивом придёт в течение суток — загрузите zip или CSV кнопкой ниже.';
      dot = RC.ink3;
    } else if (rep == null || rep.rows.isEmpty) {
      final ws = [for (final c in w.cycles) c.day]..sort();
      final os = [for (final d in _ours) d.day]..sort();
      head = 'Общих дней пока нет';
      body = 'Экспорт WHOOP: ${ws.isEmpty ? '—' : '${_dmy(DateTime.parse(ws.first))} – ${_dmy(DateTime.parse(ws.last))}'}'
          ' (${ws.length} ${_days1(ws.length)}). '
          '${os.isEmpty ? '«Ритм» ещё не посчитал ни одного дня.' : '«Ритм» считает с ${_dmy(DateTime.parse(os.first))}.'} '
          'Сверка по дням начнётся с экспорта, в котором есть дни «Ритма». '
          'Формулы уже откалиброваны по этому экспорту — ниже.';
      dot = RC.yellow;
    } else {
      final tab = _tab;
      final rs = [for (final r in rep.results.values) if (r.m.tab == tab && r.hasData) r];
      final ok = rs.where((r) => r.pass).length;
      final pass = rep.passTab(tab);
      head = pass
          ? '${tab == 'rings' ? 'Кольца' : 'Сон'}: в допуске'
          : '${tab == 'rings' ? 'Кольца' : 'Сон'}: $ok из ${rs.length} в допуске';
      body = '${rep.cleanDays} ${_days1(rep.cleanDays)} без помех из ${rep.rows.length}'
          '${rep.validFrom != null ? ' · проверочная треть с ${_dm(rep.validFrom!)}' : ''}'
          '${_at != null ? ' · экспорт от ${_dmy(_at!)}' : ''}.'
          '${rep.preliminary ? ' Меньше 30 дней — предварительно, допуски ×1,5.' : ''}';
      dot = pass ? RC.green : RC.red;
      if (widget.sample) {
        head = 'Пример на синтетических днях';
        body = 'Так сверка будет выглядеть, когда в экспорте WHOOP появятся дни «Ритма»: '
            '${rep.rows.length} ${_days1(rep.rows.length)}, ${tab == 'rings' ? 'кольца' : 'сон'} — $ok из ${rs.length} в допуске. '
            'Сейчас общих дней нет, поэтому «считается как WHOOP» не утверждаем.';
        dot = RC.ink3;
      }
    }
    return RCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 7), child: RDot(dot, size: 10)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(head, style: RT.title),
                const SizedBox(height: 4),
                Text(body, style: RT.body),
                if (_msg != null) ...[
                  const SizedBox(height: 8),
                  Text(_msg!, style: RT.small),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _days1(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'день';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'дня';
    return 'дней';
  }

  Widget _tabs() {
    Widget chip(String key, String text) {
      final on = _tab == key;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('cmp-tab-$key'),
          onTap: () => setState(() => _tab = key),
          child: Container(
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? RC.cardHi : const Color(0x00000000),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(text, style: RT.label.copyWith(color: on ? RC.ink : RC.ink3)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: RC.card, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [chip('rings', 'Кольца'), chip('sleep', 'Сон')]),
    );
  }

  // Сводка по показателям вкладки.
  Widget _summary() {
    final rep = _rep!;
    final rows = <Widget>[];
    for (final r in rep.results.values) {
      if (r.m.tab != _tab) continue;
      final s = r.all;
      final has = r.hasData;
      final sign = r.m.key == 'temp';
      final parts = <String>[
        if (!has) 'нет общих дней',
        if (has && sign) 'знак совпал ${_pct(s.share)}',
        if (has && !sign) 'ошибка ${_num(s.mae, dp: r.m.dp)}${r.m.unit.isEmpty ? '' : ' ${r.m.unit}'}',
        if (has && !sign && s.bias != null) 'смещ. ${_signed(s.bias!, dp: r.m.dp)}',
        if (has && s.r != null) 'r ${_num(s.r, dp: 2)}',
        if (has) '${s.n} ${_days1(s.n)}',
      ];
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: RDot(!has ? RC.ink3 : (r.pass ? RC.green : RC.red)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(r.m.title, style: RT.body.copyWith(color: RC.ink))),
                        Text(_tolText(r.m, rep.mult), style: RT.small),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(parts.join(' · '), style: RT.small),
                    if (has && !r.pass)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Не прошло: ${r.why(rep.mult).join('; ')}',
                          style: RT.small.copyWith(color: RC.red),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final extra = <String>[
      if (_tab == 'rings' && rep.recZoneAgree != null)
        'Зона Восстановления совпала ${_pct(rep.recZoneAgree)} дней (нужно ≥\u00a080\u00a0%)',
      if (_tab == 'rings' && rep.recDist != null)
        () {
          final p = pct100(rep.recDist!);
          return 'Наши зоны: зелёная ${p[0]}\u00a0% · жёлтая ${p[1]}\u00a0% · красная ${p[2]}\u00a0%';
        }(),
      if (_tab == 'sleep' && rep.sleepZoneAgree != null)
        'Зона Сна совпала ${_pct(rep.sleepZoneAgree)} дней',
    ];
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Показатели', trailing: null),
          ...rows,
          if (extra.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final e in extra) Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(e, style: RT.small),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'Ошибка — среднее |Δ| по дням, r — насколько дни идут в такт (1 — идеально). Δ = Ритм − WHOOP. Дни со снятым браслетом, перерывами записи и не совпавшим подъёмом в итог не входят; '
            'Нагрузка в дни силовых не сверяется — у WHOOP там есть мышечная нагрузка, которой нет в пульсе.',
            style: RT.small,
          ),
        ],
      ),
    );
  }

  // Таблица по дням (новые сверху).
  Widget _days() {
    final rep = _rep!;
    final cols = kCmpDayCols[_tab]!;
    final rows = [...rep.rows]..sort((a, b) => b.day.compareTo(a.day));
    Widget cell(CmpRow r, String key) {
      final x = r.cells[key];
      final m = cmpMetric(key);
      if (x == null) {
        return const Expanded(child: Text('—', textAlign: TextAlign.center, style: RT.small));
      }
      // Силовая: Нагрузка не сверяется — Δ не показываем, только обе цифры.
      if (key == 'strain' && r.strength) {
        String v(double y) => _num(y, dp: m.dp);
        return Expanded(
          child: Column(
            children: [
              const Text('—', style: RT.label),
              const SizedBox(height: 1),
              Text('${v(x.whoop)} · ${v(x.ritm)}', style: RT.micro, maxLines: 1),
            ],
          ),
        );
      }
      final clean = r.cleanFor(key);
      final ok = rep.cellOk(key, x.delta);
      final color = !clean ? RC.ink3 : (ok ? RC.green : RC.red);
      final clockish = key == 'onset' || key == 'wake';
      String v(double y) => clockish ? _clockOf(y) : _num(y, dp: m.dp);
      return Expanded(
        child: Column(
          children: [
            Text(_signed(x.delta, dp: m.dp), style: RT.label.copyWith(color: color)),
            const SizedBox(height: 1),
            Text('${v(x.whoop)} · ${v(x.ritm)}', style: RT.micro, maxLines: 1),
          ],
        ),
      );
    }

    final list = <Widget>[
      Row(
        children: [
          const SizedBox(width: 52, child: Text('ДЕНЬ', style: RT.micro)),
          for (final k in cols)
            Expanded(child: Text(kCmpShort[k]!.toUpperCase(), textAlign: TextAlign.center, style: RT.micro)),
        ],
      ),
      const SizedBox(height: 6),
    ];
    for (final r in rows.take(60)) {
      list.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: RC.line))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(_dm(r.day), style: RT.label.copyWith(color: r.clean ? RC.ink : RC.ink3)),
                  ),
                  for (final k in cols) cell(r, k),
                ],
              ),
              if (!r.clean || (r.strength && _tab == 'rings'))
                Padding(
                  padding: const EdgeInsets.only(left: 52, top: 3),
                  child: Text(
                    !r.clean ? 'не в итоге: ${dirtyWord(r)}' : 'силовая — Нагрузка не сверяется',
                    style: RT.micro,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('По дням', trailing: null),
          const SizedBox(height: 4),
          const Text('Крупно — Δ, мелко — WHOOP · Ритм. Зелёный — в допуске дня, красный — вне.', style: RT.small),
          const SizedBox(height: 10),
          ...list,
        ],
      ),
    );
  }

  static String _clockOf(double minutes) {
    final m = ((minutes % 1440) + 1440) % 1440;
    final h = m ~/ 60, mm = (m % 60).round();
    return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
  }

  // Калибровка формул по экспорту «вход → выход».
  Widget _calibration() {
    final th = kRingTheta;
    // Итоги build/B4h_calibration.md на ПРОВЕРОЧНОЙ трети, цвет — по допускам
    // §8.2 (зелёный — все критерии строки, жёлтый — часть, красный — главный).
    final lines = <(String, String, Color)>[
      (
        'Восстановление',
        'ошибка ${_num(th.recMae, dp: 1)} п.п. (≤\u00a08) · смещение +3,5 (±4) · r 0,86 (≥\u00a00,85) · зона совпала 80\u00a0% (≥\u00a080). '
            'Не прошло: доли зон 52/47/2\u00a0% при ожидаемых ≈\u00a040/45/15 ±10 п.п. (у самого WHOOP на этих днях 46/47/7)',
        RC.yellow,
      ),
      (
        'Нагрузка дня',
        'ошибка 1,1 · смещение +0,5 · r 0,95 по всем дням проверки; без силовых — ошибка 1,3 (≤\u00a01,5), '
            'смещение +0,9 (±0,8), r 0,77 (≥\u00a00,90) — не в допуске. Поминутного пульса в экспорте нет — оценка по средним',
        RC.red,
      ),
      (
        'Нагрузка тренировки',
        'ошибка ${_num(th.strainMae, dp: 1)} (≤\u00a01,0) · r 0,91 (≥\u00a00,90), без силовых — не в допуске',
        RC.red,
      ),
      ('Потребность сна', 'ошибка 16 мин (≤\u00a020) · смещение −3 (±10) · r 0,92 (≥\u00a00,80)', RC.green),
      ('Долг сна', 'ошибка 13 мин (≤\u00a020) · смещение −3 (±10)', RC.green),
      ('Оценка сна', 'ошибка 3,5 п.п. (≤\u00a05) · смещение 0 (±3) · r 0,90 (≥\u00a00,90)', RC.green),
      ('Регулярность', 'ошибка 6 п.п. (≤\u00a08) · r 0,76 (≥\u00a00,70)', RC.green),
    ];
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Калибровка формул', trailing: null),
          const SizedBox(height: 6),
          Text(
            th.calibrated
                ? 'Экспорт для калибровки: ${th.windowDays} ${_days1(th.windowDays)}, 09.08.2025–09.08.2026 '
                    '(получен ${_dmy(DateTime.parse(th.calibratedAt))})'
                : 'Ещё не калибровано — стартовые значения.',
            style: RT.body.copyWith(color: RC.ink),
          ),
          if (th.calibrated) ...[
            const SizedBox(height: 4),
            const Text(
              'Это другой файл, не тот, что сверяется выше. ⅔ дней — подбор формул, последняя ⅓ — проверка.',
              style: RT.body,
            ),
          ],
          for (final (a, b, col) in lines)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 6), child: RDot(col)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '$a: ', style: RT.body.copyWith(color: RC.ink)),
                      TextSpan(text: b, style: RT.body),
                    ])),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            'На вход формулам подавались цифры самого WHOOP (ВСР, пульс покоя, дыхание, сон) — это проверяет формулы, '
            'но не датчики «Ритма». Сверка датчиков — после экспорта WHOOP с общими днями; до неё «считается как WHOOP» '
            'не утверждаем.',
            style: RT.small,
          ),
        ],
      ),
    );
  }

  Widget _actions() => Column(
    children: [
      RButton(
        LucideIcons.upload,
        'Загрузить экспорт WHOOP',
        kind: RButtonKind.primary,
        onTap: _fixed ? () {} : _import,
      ),
      const SizedBox(height: 8),
      RButton(
        LucideIcons.share,
        'Экспорт для сверки (CSV)',
        onTap: _fixed ? () {} : _export,
      ),
      const SizedBox(height: 8),
      const Text(
        'Всё считается на телефоне, файлы никуда не отправляются.',
        style: RT.small,
        textAlign: TextAlign.center,
      ),
    ],
  );
}

// ── демо ─────────────────────────────────────────────────────────────────────

/// Демо-сверка: 45 дней WHOOP и «Ритма» с правдоподобным шумом, двумя
/// «грязными» днями, силовой и одним днём вне допуска (DEBUG + RITM_DEMO).
({WhoopExport w, List<RitmDayExport> ours})? ritmDemoWhoopCompare() {
  if (!kRitmDemo) return null;
  return demoWhoopCompareData(DateTime.now());
}

@visibleForTesting
({WhoopExport w, List<RitmDayExport> ours}) demoWhoopCompareData(DateTime now) {
  final rnd = math.Random(15);
  double g() => (rnd.nextDouble() + rnd.nextDouble() + rnd.nextDouble() - 1.5) * 2; // ≈ N(0,1)
  final cycles = <WhoopCycle>[];
  final ours = <RitmDayExport>[];
  final workouts = <WhoopWorkout>[];
  for (var i = 44; i >= 1; i--) {
    final d = DateTime(now.year, now.month, now.day - i);
    final onset = d.subtract(Duration(minutes: 60 + (g() * 25).round()));
    final wake = d.add(Duration(hours: 7, minutes: 10 + (g() * 20).round()));
    final hrv = 46 + g() * 7, rhr = 50 + g() * 2;
    final rec = (62 + (hrv - 46) * 2.6 - (rhr - 50) * 3 + g() * 4).clamp(8, 99).toDouble();
    final strength = i % 9 == 4;
    final strain = (9 + g() * 3 + (strength ? 3 : 0)).clamp(2, 19).toDouble();
    final asleep = (wake.difference(onset).inMinutes - 30 + g() * 10).toDouble();
    final deep = 95 + g() * 15;
    final day = dayId(d);
    cycles.add(
      WhoopCycle(
        day: day,
        start: onset,
        recovery: rec.roundToDouble(),
        rhr: rhr.roundToDouble(),
        hrv: hrv.roundToDouble(),
        skinTemp: 33.6 + g() * 0.2,
        strain: double.parse(strain.toStringAsFixed(1)),
        sleep: WhoopSleepFields(
          onset: onset,
          wake: wake,
          perf: (asleep / 480 * 100).clamp(40, 100).roundToDouble(),
          resp: 16.4 + g() * 0.3,
          asleep: asleep.roundToDouble(),
          inBed: (asleep + 22).roundToDouble(),
          deep: deep.roundToDouble(),
          light: (asleep * .5).roundToDouble(),
          rem: (asleep * .25).roundToDouble(),
          awake: 22,
          need: 480,
          debt: 30,
          eff: 95,
          consistency: 78,
        ),
      ),
    );
    if (strength) {
      workouts.add(
        WhoopWorkout(
          start: d.add(const Duration(hours: 18)),
          end: d.add(const Duration(hours: 19)),
          name: 'Weightlifting',
          strain: 9,
        ),
      );
    }
    final dirtyObs = i == 11 ? 0.7 : 0.97;
    final off = i == 6; // один день вне допуска
    ours.add(
      RitmDayExport(
        day: day,
        onset: onset.add(Duration(minutes: (g() * 6).round())),
        wake: wake.add(Duration(minutes: (g() * 5).round())),
        strength: strength,
        swsFound: true,
        v: {
          'rhr_sleep_mean': rhr + g() * 0.9,
          'rmssd_sws_last': hrv + g() * 4 + (off ? 14 : 0),
          'resp': 16.4 + g() * 0.3 + 0.1,
          'temp_dev': g() * 0.2,
          'tst_min': asleep + g() * 7,
          'in_bed_min': asleep + 22 + g() * 7,
          'eff': 95 + g(),
          'deep_min': deep + g() * 14 + 6,
          'light_min': asleep * .5 + g() * 15,
          'rem_min': asleep * .25 + g() * 12,
          'awake_min': 22 + g() * 6,
          'need_min': 480 + g() * 8,
          'debt_min': 30 + g() * 8,
          'consistency': 78 + g() * 3,
          'sleep_pct': (asleep / 480 * 100).clamp(40, 100) + g() * 2,
          'recovery': (rec + g() * 4 + (off ? 15 : 0)).clamp(1, 99).toDouble(),
          'strain': strain + g() * 0.6 - (strength ? 2.5 : 0),
          'observed_frac': dirtyObs,
          'hr_valid_frac': 0.95,
          'max_gap_min': 0,
        },
      ),
    );
  }
  return (
    w: WhoopExport(cycles: cycles, workouts: workouts, files: const {'cycles', 'workouts'}),
    ours: ours,
  );
}

/// Для подписи в «Источниках»: короткий итог последней сверки.
Future<String> whoopCompareLine() async {
  final demo = ritmDemoWhoopCompare();
  if (demo != null) {
    final r = compareWhoop(demo.w, demo.ours);
    return 'Пример на синтетических днях · ${r.rows.length} ${_RitmWhoopCompareScreenState._days1(r.rows.length)}';
  }
  final x = await RitmWhoopFiles.load();
  if (x == null) return 'Экспорт не загружен · формулы откалиброваны';
  final r = compareWhoop(x.w, RitmRingsStore.export());
  if (r.rows.isEmpty) return 'Общих дней пока нет · формулы откалиброваны';
  return _line(r);
}

String _line(CmpReport r) =>
    '${r.passTab('rings') ? 'Кольца в допуске' : 'Есть расхождения'} · ${r.cleanDays} ${_RitmWhoopCompareScreenState._days1(r.cleanDays)}';

// shortDayRu нужен в подписях «Источников» — реэкспорт удобства.
String whoopDayLabel(String day) => shortDayRu(day);

/// Доли → целые проценты с суммой ровно 100 (метод наибольшего остатка).
List<int> pct100(List<double> xs) {
  final tot = xs.fold<double>(0, (a, b) => a + b);
  if (tot <= 0) return [for (final _ in xs) 0];
  final raw = [for (final x in xs) x / tot * 100];
  final out = [for (final r in raw) r.floor()];
  var left = 100 - out.fold<int>(0, (a, b) => a + b);
  final order = List<int>.generate(xs.length, (i) => i)
    ..sort((a, b) => (raw[b] - out[b]).compareTo(raw[a] - out[a]));
  for (final i in order) {
    if (left <= 0) break;
    out[i]++;
    left--;
  }
  return out;
}
