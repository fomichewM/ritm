// «Ритм» B7 — экраны: «Датчик пульса» (трансляция Garmin / нагрудный датчик),
// ручной VO₂max (D9), «Дыхание ночью» (K17). Сверка браслет / Garmin — в
// «Источниках» (_reconcile), строки сна и «Garmin не передаёт» — там же.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ble/adapters/_registry.dart' show kBleHrs;
import '../ble/hrs_link.dart';
import '../ui2/profile/pair_sensor.dart' show PairSensorScreen;
import '../ui2/screens/home_screen.dart' show repoOf;
import 'ritm_b7.dart';
import 'ritm_demo.dart' show kRitmDemo, ritmDemoNow;
import 'ritm_scores.dart' show plural;
import 'ritm_ui.dart';

String _id(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _now() => ritmDemoNow() ?? DateTime.now();

// ───────────────────────── «Датчик пульса» ─────────────────────────

/// Карточка в «Источниках»: трансляция пульса Garmin или нагрудный датчик.
/// Пульс с датчика на тренировке идёт в Нагрузку вместо браслета.
class RitmHrSensorCard extends StatefulWidget {
  final bool garmin;
  const RitmHrSensorCard({super.key, required this.garmin});
  @override
  State<RitmHrSensorCard> createState() => _RitmHrSensorCardState();
}

class _RitmHrSensorCardState extends State<RitmHrSensorCard> {
  String? _name;
  int _todayMin = 0;

  @override
  void initState() {
    super.initState();
    RitmHrsRecorder.live.addListener(_tick);
    unawaited(_load());
  }

  @override
  void dispose() {
    RitmHrsRecorder.live.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (kRitmDemo) {
      setState(() => (_name = widget.garmin ? 'Garmin fēnix 8' : 'нагрудный датчик', _todayMin = 46));
      return;
    }
    try {
      final row = await HrsLink.pairedSensorRow();
      final n = DateTime.now();
      final d0 = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch ~/ 1000;
      final xs = await RitmHrsRecorder.dayRange(d0, d0 + 86400);
      if (!mounted) return;
      setState(() {
        _name = row == null ? null : '${row['name'] ?? row['label'] ?? 'Датчик пульса'}';
        _todayMin = RitmHrsRecorder.minutes(xs);
      });
    } catch (_) {}
  }

  Future<void> _pair(BuildContext c) async {
    if (kRitmDemo) return;
    await Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const PairSensorScreen(entry: kBleHrs)));
    await _load();
  }

  @override
  Widget build(BuildContext c) {
    final live = kRitmDemo ? null : RitmHrsRecorder.live.value;
    final fresh = live != null && DateTime.now().millisecondsSinceEpoch ~/ 1000 - live.$2 < 15;
    final how = widget.garmin
        ? 'На часах Garmin удерживайте LIGHT → «Трансляция пульса» (или включите её в настройках занятия). '
              'Потом нажмите «Начать» на главной: пульс часов пойдёт в Нагрузку вместо браслета. '
              'Если телефон не видит часы — запустите на часах занятие «Виртуальный бег» (Virtual Run): в нём трансляция включается сама.'
        : 'Нагрудный датчик пульса с блютузом (Garmin и другие): наденьте, подключите один раз и '
              'нажмите «Начать» на главной — пульс с груди пойдёт в Нагрузку вместо браслета.';
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RCardHead('Датчик пульса', trailing: null),
          const SizedBox(height: RS.tileHead),
          Row(
            children: [
              RDot(_name == null ? RC.ink3 : (fresh ? RC.green : RC.yellow)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _name == null
                      ? 'Не подключён'
                      : fresh
                      ? '$_name · ${live.$1} уд/мин сейчас'
                      : '$_name · подключён, сейчас не передаёт',
                  style: RT.body.copyWith(color: RC.ink),
                ),
              ),
            ],
          ),
          if (_name != null) ...[
            const SizedBox(height: 4),
            const Text('Имя — из последнего подключения датчика', style: RT.micro),
            const SizedBox(height: 2),
            Text(
              _todayMin == 0
                  ? 'Сегодня трансляции не было'
                  : 'Сегодня $_todayMin ${plural(_todayMin, 'минута', 'минуты', 'минут')} трансляции — в Нагрузке',
              style: RT.small,
            ),
          ],
          const SizedBox(height: 10),
          Text(how, style: RT.small),
          const SizedBox(height: 12),
          RButton(
            LucideIcons.bluetooth,
            _name == null ? 'Подключить датчик' : 'Сменить датчик',
            onTap: () => _pair(c),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── D9: ручной VO₂max ─────────────────────────

/// Лист ввода VO₂max (тест на дорожке, лаборатория, часы без «Здоровья»).
Future<void> showRitmVo2Sheet(BuildContext c) => showModalBottomSheet<void>(
  context: c,
  isScrollControlled: true,
  backgroundColor: RC.card,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
  builder: (_) => const _Vo2Sheet(),
);

class _Vo2Sheet extends StatefulWidget {
  const _Vo2Sheet();
  @override
  State<_Vo2Sheet> createState() => _Vo2SheetState();
}

class _Vo2SheetState extends State<_Vo2Sheet> {
  late final TextEditingController _t;
  String? _err;

  @override
  void initState() {
    super.initState();
    final v = RitmVo2Manual.value;
    _t = TextEditingController(text: v == null ? '' : v.$1.toStringAsFixed(1).replaceAll('.', ','));
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _save() {
    final e = RitmVo2Manual.validate(_t.text);
    if (e != null) {
      setState(() => _err = e);
      return;
    }
    RitmVo2Manual.set(double.parse(_t.text.trim().replaceAll(',', '.')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext c) {
    final cur = RitmVo2Manual.value;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(c).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('VO₂max вручную', style: RT.title),
          const SizedBox(height: 6),
          const Text(
            'Из теста на дорожке, лаборатории или часов, которые не пишут в «Здоровье». '
            'В биовозрасте — с подписью «введено». Замер Apple Watch, если есть, важнее; '
            'введённое значение действует 180 дней.',
            style: RT.small,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _t,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: RT.num.copyWith(fontSize: 22),
            cursorColor: RC.brandA,
            decoration: InputDecoration(
              hintText: 'например 44,5',
              hintStyle: RT.body,
              suffixText: 'мл/кг/мин',
              suffixStyle: RT.small,
              errorText: _err,
              filled: true,
              fillColor: RC.cardHi,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 14),
          RButton(LucideIcons.check, 'Сохранить', kind: RButtonKind.primary, onTap: _save),
          if (cur != null) ...[
            const SizedBox(height: 8),
            RButton(
              LucideIcons.trash2,
              'Удалить введённое',
              kind: RButtonKind.ghost,
              onTap: () {
                RitmVo2Manual.clear();
                Navigator.of(c).pop();
              },
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────── K17: «Дыхание ночью» ─────────────────────────

/// Карточка «Монитора здоровья»: переключатель (выкл. по умолчанию) и итог.
class RitmCvhrCard extends StatefulWidget {
  /// Только демо-скриншоты: включено и «непохожая» ночь.
  final bool demoUnlike;
  const RitmCvhrCard({super.key, this.demoUnlike = false});
  @override
  State<RitmCvhrCard> createState() => _RitmCvhrCardState();
}

class _RitmCvhrCardState extends State<RitmCvhrCard> {
  CvhrVerdict? _v;
  bool _on = RitmCvhrPrefs.on;

  @override
  void initState() {
    super.initState();
    if (widget.demoUnlike) _on = true;
    if (_on) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    if (kRitmDemo) {
      // Демо: 30 обычных ночей (8–14 циклов/ч) и две непохожие подряд.
      final now = _now();
      final rows = [
        for (var i = 31; i >= 0; i--)
          CvhrNightRow(
            _id(now.subtract(Duration(days: i))),
            widget.demoUnlike && i < 2 ? 23.0 + i : 8.0 + (i * 7 % 6),
            6.5,
          ),
      ];
      if (mounted) setState(() => _v = cvhrVerdict(rows));
      return;
    }
    final repo = repoOf(context);
    if (repo == null) return;
    final now = DateTime.now();
    final days = [for (var i = 33; i >= 0; i--) _id(now.subtract(Duration(days: i)))];
    final rows = await loadCvhrRows(repo, days);
    if (mounted) setState(() => _v = cvhrVerdict(rows));
  }

  @override
  Widget build(BuildContext c) {
    final v = _v;
    return RCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Ночь непохожа на ваши (дыхание и пульс)', style: RT.title)),
              RSwitch(
                value: _on,
                onChanged: (x) {
                  RitmCvhrPrefs.set(x);
                  setState(() => (_on = x, _v = null));
                  if (x) unawaited(_load());
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Сравнивает ритм пульса во сне с вашими же ночами за месяц: замечает ночи, '
            'непохожие на ваши обычные. Дыхание выводится из ритма пульса (во время задержек дыхания пульс '
            'то замедляется, то ускоряется). Не диагноз и не медицинский прибор; в «В норме · N из N» не входит. '
            'Как считается: нужно 14 ночей по 4 часа и больше; отметка — только если две ночи подряд '
            'выше вашего обычного верха.',
            style: RT.small,
          ),
          if (_on) ...[
            const SizedBox(height: 10),
            if (v == null)
              const Text('Считаю…', style: RT.body)
            else if (v.state == CvhrState.learning)
              Text(
                'Учусь вашим ночам: ${v.nights} из $kCvhrMinNights ночей по 4 часа и больше.',
                style: RT.body.copyWith(color: RC.ink),
              )
            else if (v.state == CvhrState.usual)
              Row(
                children: [
                  RDot(RC.green),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Последние ночи похожи на ваши обычные.', style: RT.body.copyWith(color: RC.ink))),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(padding: EdgeInsets.only(top: 6), child: RDot(RC.yellow)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(kRitmCvhrText, style: RT.body.copyWith(color: RC.ink))),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
