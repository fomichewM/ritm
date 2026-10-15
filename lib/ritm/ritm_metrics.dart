// «Ритм» — «Мои показатели» на главной (ТЗ v2 §2 п. 6, сборка B2):
// строки 56 pt (иконка 20 · название · значение · подпись), «Настроить» —
// переключатели строк и порядок перетаскиванием (хранится в Prefs).
// B3: VO₂max (Apple Watch через Swift-канал) и шаги с подписью источника (§10.10).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/prefs.dart';
import 'ritm_scores.dart';
import 'ritm_ui.dart';

/// Ключи строк в порядке по умолчанию.
const kRitmMetricKeys = [
  'hrv',
  'rhr',
  'vo2',
  'steps',
  'z13',
  'z45',
  'strength',
  'kcal',
];

String ritmMetricName(String k) => switch (k) {
  'hrv' => 'ВСР',
  'rhr' => 'Пульс покоя',
  'vo2' => 'VO₂max',
  'steps' => 'Шаги',
  'z13' => 'Зоны 1–3 за неделю',
  'z45' => 'Зоны 4–5 за неделю',
  'strength' => 'Силовые за неделю',
  'kcal' => 'Калории',
  _ => k,
};

IconData ritmMetricIcon(String k) => switch (k) {
  'hrv' => LucideIcons.activity,
  'rhr' => LucideIcons.heartPulse,
  'vo2' => LucideIcons.wind,
  'steps' => LucideIcons.footprints,
  'z13' => LucideIcons.gauge,
  'z45' => LucideIcons.zap,
  'strength' => LucideIcons.dumbbell,
  'kcal' => LucideIcons.flame,
  _ => LucideIcons.circle,
};

/// Значения строк (null — «—»).
class RitmMetricValues {
  final num? hrv, hrvNorm, rhr, rhrMean30, steps, kcal;
  final int? z13, z45, strength;
  final String stepsSource;

  /// VO₂max Apple Watch; [watchKnown] — Watch вообще есть в «Здоровье».
  final double? vo2;
  final bool watchKnown;
  const RitmMetricValues({
    this.hrv,
    this.hrvNorm,
    this.rhr,
    this.rhrMean30,
    this.steps,
    this.kcal,
    this.z13,
    this.z45,
    this.strength,
    this.stepsSource = 'браслет',
    this.vo2,
    this.watchKnown = false,
  });

  /// Те же значения + данные Apple Watch (VO₂max, шаги по правилу §10.10).
  RitmMetricValues withWatch({
    double? vo2,
    bool watchKnown = false,
    num? steps,
    String? stepsSource,
  }) => RitmMetricValues(
    hrv: hrv,
    hrvNorm: hrvNorm,
    rhr: rhr,
    rhrMean30: rhrMean30,
    steps: steps ?? this.steps,
    kcal: kcal,
    z13: z13,
    z45: z45,
    strength: strength,
    stepsSource: stepsSource ?? this.stepsSource,
    vo2: vo2 ?? this.vo2,
    watchKnown: watchKnown || this.watchKnown,
  );

  /// (значение, подпись, цвет подписи) строки [k].
  (String, String, Color) cell(String k) {
    String n(num? v) => v == null ? '—' : thousands(v);
    String hm(int? m) => m == null ? '—' : hmm(m);
    switch (k) {
      case 'hrv':
        return (
          n(hrv),
          hrv == null ? '' : (hrvNorm == null ? 'мс' : 'мс · обычно ${hrvNorm!.round()}'),
          RC.ink3,
        );
      case 'rhr':
        if (rhr == null) return ('—', '', RC.ink3);
        if (rhrMean30 == null) return (n(rhr), 'уд/мин', RC.ink3);
        final d = (rhr! - rhrMean30!).round();
        return (
          n(rhr),
          // Дельта — к среднему за 30 дней (не к вчера), так и подписано.
          d == 0 ? 'как за 30 дней' : '${signed(d)} к 30 дн.',
          d < 0 ? RC.green : (d > 0 ? RC.yellow : RC.ink3),
        );
      case 'vo2':
        if (vo2 == null) {
          return ('—', watchKnown ? 'не измерял' : 'нет источника', RC.ink3);
        }
        return (dec1(vo2!), 'Watch', RC.ink3);
      case 'steps':
        return (n(steps), steps == null ? '' : stepsSource, RC.ink3);
      case 'z13':
        return (hm(z13), z13 == null ? '' : 'цель 2:30', RC.ink3);
      case 'z45':
        return (hm(z45), '', RC.ink3);
      case 'strength':
        return (hm(strength), '', RC.ink3);
      case 'kcal':
        return (n(kcal), kcal == null ? '' : 'ккал ±25%', RC.ink3);
    }
    return ('—', '', RC.ink3);
  }
}

/// Порядок и видимость строк.
class RitmMetricsConfig {
  static const _orderKey = 'ritm.metrics.order';
  static const _offKey = 'ritm.metrics.off';

  static List<String> order() {
    final saved = Prefs.getString(_orderKey, '');
    final list = [
      for (final k in saved.split(','))
        if (kRitmMetricKeys.contains(k)) k,
    ];
    for (final k in kRitmMetricKeys) {
      if (!list.contains(k)) list.add(k);
    }
    return list;
  }

  static Set<String> off() =>
      {for (final k in Prefs.getString(_offKey, '').split(',')) if (k.isNotEmpty) k};

  static List<String> visible() {
    final o = off();
    return [for (final k in order()) if (!o.contains(k)) k];
  }

  static void save(List<String> order, Set<String> off) {
    Prefs.setString(_orderKey, order.join(','));
    Prefs.setString(_offKey, off.join(','));
  }
}

/// Список строк.
class RitmMetricsList extends StatelessWidget {
  final RitmMetricValues v;
  final List<String> keys;
  final void Function(String key)? onTap;
  const RitmMetricsList({super.key, required this.v, required this.keys, this.onTap});

  @override
  Widget build(BuildContext c) => Column(
    children: [
      for (final k in keys) _row(k),
    ],
  );

  Widget _row(String k) {
    final (value, note, noteColor) = v.cell(k);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null ? null : () => onTap!(k),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: RC.card,
            borderRadius: BorderRadius.circular(RS.rTile),
          ),
          child: Row(
            children: [
              Icon(ritmMetricIcon(k), size: 20, color: RC.ink2),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  ritmMetricName(k),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RT.title.copyWith(fontSize: 15),
                ),
              ),
              Text(value, style: RT.num.copyWith(fontSize: 17)),
              if (note.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(note, style: RT.small.copyWith(color: noteColor)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Кнопка «Настроить» для RSection.
class RitmTuneButton extends StatelessWidget {
  final VoidCallback? onTap;
  const RitmTuneButton({super.key, this.onTap});
  @override
  Widget build(BuildContext c) => Semantics(
    button: true,
    label: 'Настроить показатели',
    excludeSemantics: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(RS.rTile),
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: RC.cardHi,
          borderRadius: BorderRadius.circular(RS.rTile),
        ),
        child: Text(
          'НАСТРОИТЬ',
          style: RT.cap.copyWith(fontSize: 12, color: RC.ink),
        ),
      ),
    ),
  );
}

/// Лист «Настроить»: переключатели + перетаскивание. Возвращает true, если
/// что-то поменяли.
Future<bool> showRitmMetricsTune(BuildContext c) async {
  final order = RitmMetricsConfig.order();
  final off = RitmMetricsConfig.off();
  var changed = false;
  await showRSheet<void>(
    c,
    (sc) => StatefulBuilder(
      builder: (sc, set) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Мои показатели', style: RT.h2),
          const SizedBox(height: 4),
          const Text('Выключите лишнее, порядок — перетащите за ручку.', style: RT.small),
          const SizedBox(height: 12),
          SizedBox(
            height: order.length * 56.0,
            child: ReorderableListView(
              buildDefaultDragHandles: false,
              physics: const NeverScrollableScrollPhysics(),
              onReorderItem: (a, b) => set(() {
                order.insert(b, order.removeAt(a));
                changed = true;
                RitmMetricsConfig.save(order, off);
              }),
              children: [
                for (var i = 0; i < order.length; i++)
                  SizedBox(
                    key: ValueKey(order[i]),
                    height: 56,
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: const SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(LucideIcons.gripVertical, size: 20, color: RC.ink3),
                          ),
                        ),
                        Icon(ritmMetricIcon(order[i]), size: 20, color: RC.ink2),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            ritmMetricName(order[i]),
                            style: RT.title.copyWith(fontSize: 15),
                          ),
                        ),
                        RSwitch(
                          value: !off.contains(order[i]),
                          onChanged: (v) => set(() {
                            v ? off.remove(order[i]) : off.add(order[i]);
                            changed = true;
                            RitmMetricsConfig.save(order, off);
                          }),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          RButton(
            null,
            'Готово',
            kind: RButtonKind.primary,
            onTap: () => Navigator.of(sc).pop(),
          ),
        ],
      ),
    ),
  );
  return changed;
}
