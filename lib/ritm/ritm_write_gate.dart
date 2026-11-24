// «Ритм» — переключатели ЗАПИСИ в «Здоровье» по типам (ТЗ v2 §8.1, §10.11).
//
// Edge пишет в Здоровье всё сразу по одному переключателю `health_sync`.
// «Ритм» добавляет поверх него ворота по типам. Пока пользователь ни разу не
// трогал эти переключатели (`ritm.write.configured` нет), ворота открыты —
// поведение Edge не меняется (и тесты Edge остаются в силе); экран
// «Источники и сверка» показывает их как «включено», если включена запись.
// Первое касание любого переключателя фиксирует все типы явно.

import '../state/prefs.dart';
import 'ritm_hk.dart' show ritmMayWriteEnergy;

/// Ключ Prefs: Apple Watch встречался в «Здоровье».
const kRitmWatchPresentKey = 'ritm.watch.present';

enum RitmWriteKind { sleep, rhr, hrv, resp, workouts, hr, energy }

class RitmWriteGate {
  RitmWriteGate._();

  static const _configured = 'ritm.write.configured';
  static String _key(RitmWriteKind k) => 'ritm.write.${k.name}';

  static bool get configured => Prefs.getBool(_configured, false);

  /// Можно ли писать этот тип (поверх общего `health_sync`).
  static bool allows(RitmWriteKind k) {
    // §10.11: калории не пишем, если есть Apple Watch — иначе кольца
    // Активности удвоятся (Watch уже пишет свои).
    if (k == RitmWriteKind.energy &&
        !ritmMayWriteEnergy(
          toggle: true,
          watchPresent: Prefs.getBool(kRitmWatchPresentKey, false),
        )) {
      return false;
    }
    return !configured || Prefs.getBool(_key(k), false);
  }

  /// Включить/выключить тип. При первом изменении остальные типы получают
  /// текущее фактическое состояние [legacyAll] (вкл, если запись уже шла).
  static void set(RitmWriteKind k, bool on, {required bool legacyAll}) {
    if (!configured) {
      for (final t in RitmWriteKind.values) {
        Prefs.setBool(_key(t), legacyAll);
      }
      Prefs.setBool(_configured, true);
    }
    Prefs.setBool(_key(k), on);
  }

  /// Хоть один тип включён (тогда общий `health_sync` должен быть вкл.).
  static bool get any =>
      RitmWriteKind.values.any((k) => Prefs.getBool(_key(k), false));
}
