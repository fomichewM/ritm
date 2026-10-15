// «Ритм» — вкладка «Ещё» (ТЗ v2 §8): ровно восемь пунктов —
// Профиль · Браслет · Источники и сверка · Уведомления · Помощник · Данные ·
// Значок · О приложении. Детальные экраны данных открываются с Главной и
// «Здоровья», не отсюда. «Оформление», «Единицы», «Дополнительно» удалены.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/cupertino.dart' show CupertinoDatePicker, CupertinoDatePickerMode, CupertinoTheme, CupertinoThemeData;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../coach/coach_config.dart';
import '../platform/app_icon.dart';
import '../state/app_state.dart';
import '../ui2/community_links.dart' show open3rdPartyLink;

import '../ui2/profile/alarm.dart' show AlarmScreen;
import '../ui2/profile/band_notifications.dart' show BandNotifications;
import '../ui2/profile/data.dart' show DataScreen;
import '../ui2/profile/devices.dart' show MyDevices;
import '../ui2/profile/gestures.dart' show BandGestures;
import '../ui2/profile/report_issue.dart' show ReportIssueScreen;
import '../ui2/profile/settings.dart' show EditProfile, NotificationSettings;
import '../ui2/screens/coach.dart' show CoachScreen, CoachSetup;
import '../ui2/screens/home_screen.dart' show go;
import 'ritm_avatar.dart';
import 'ritm_demo.dart'
    show
        kRitmDemo,
        ritmDemoAvatarPath,
        ritmDemoBirth,
        ritmDemoNow,
        ritmDemoSources,
        ritmDemoStep;
import 'ritm_bioage.dart' show ageOn, birthIso, parseBirth;
import 'ritm_watch_store.dart' show RitmHealthKitChannel;
import 'ritm_scores.dart' show pct, plural;
import 'ritm_seed.dart';
import 'ritm_watch.dart';
import 'ritm_sources.dart' show RitmSourcesScreen, agoRu, bandModel;
import 'ritm_hk_debug.dart' show RitmHkCheckScreen;
import 'ritm_whoop_csv.dart' show WhoopCycle, WhoopExport, dayId;
import 'ritm_whoop_ui.dart' show RitmWhoopCompareScreen, ritmDemoWhoopCompare;
import 'ritm_ui.dart';

/// Открытый репозиторий «Ритма» (AGPL-3.0, B6).
const kRitmRepoUrl = 'https://github.com/fomichewM/ritm';

class RitmMoreScreen extends StatefulWidget {
  const RitmMoreScreen({super.key});

  @override
  State<RitmMoreScreen> createState() => _RitmMoreScreenState();
}

class _RitmMoreScreenState extends State<RitmMoreScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (kRitmDemo) {
      ritmDemoStep.addListener(_demoStep);
      final v = ritmDemoStep.value;
      if (v == 27 || v == 33 || v == 45 || v == 59 || v == 69) {
        Future.delayed(Duration(milliseconds: v == 69 ? 250 : 900), () {
          if (mounted) _demoStep();
        });
      }
    }
  }

  Widget? _whoopDemo(int step) {
    final d = ritmDemoWhoopCompare();
    if (d == null) return null;
    return RitmWhoopCompareScreen(
      whoop: d.w,
      ours: d.ours,
      importedAt: ritmDemoNow(),
      initialTab: step == 63 ? 'sleep' : 'rings',
      sample: true,
      demoScrollTo: switch (step) {
        62 => .42,
        64 => 1.0,
        _ => null,
      },
    );
  }

  /// Как у Михаила сейчас: экспорт за 10.08.2025–09.08.2026, «Ритм» — с октября.
  Widget? _whoopDemoNoOverlap() {
    final d = ritmDemoWhoopCompare();
    if (d == null) return null;
    // Тот же охват, что у настоящего экспорта: 09.08.2025–09.08.2026.
    final w = WhoopExport(
      cycles: [
        for (var i = 0; i <= 365; i++)
          WhoopCycle(day: dayId(DateTime(2025, 8, 9 + i)), recovery: 60 + (i * 37 % 30).toDouble()),
      ],
    );
    return RitmWhoopCompareScreen(whoop: w, ours: d.ours, importedAt: DateTime(2026, 10, 15));
  }

  @override
  void dispose() {
    if (kRitmDemo) ritmDemoStep.removeListener(_demoStep);
    _scroll.dispose();
    super.dispose();
  }

  void _demoStep() {
    if (!mounted) return;
    final page = switch (ritmDemoStep.value) {
      8 => const RitmSourcesScreen(),
      9 => const RitmIconScreen(),
      10 => const RitmAboutScreen(),
      11 => const RitmProfileScreen(),
      12 => const RitmBandScreen(),
      13 => const RitmAssistantSettings(),
      14 => const RitmSourcesScreen(demoScrollEnd: true),
      15 => const EditProfile(),
      16 => const NotificationSettings(),
      17 => const DataScreen(),
      27 => const RitmDataScreen(),
      45 => const RitmProfileScreen(),
      33 => const RitmSourcesScreen(),
      34 => const RitmSourcesScreen(demoScrollTo: .42),
      35 => const RitmSourcesScreen(demoScrollEnd: true),
      36 => const RitmHkCheckScreen(),
      59 => const RitmSourcesScreen(),
      60 => const RitmSourcesScreen(demoScrollEnd: true),
      61 || 62 || 63 || 64 => _whoopDemo(ritmDemoStep.value),
      65 => _whoopDemoNoOverlap(),
      69 => const RitmSourcesScreen(),
      18 => const CoachSetup(),
      19 => const AlarmScreen(),
      _ => null,
    };
    final nav = Navigator.of(context);
    if (ritmDemoStep.value == 66) {
      // Уход в «Здоровье» (3D-шар): закрыть экраны «Ещё» поверх вкладок.
      Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
      nav.popUntil((r) => r.isFirst);
      return;
    }
    if (ritmDemoStep.value == 20) {
      nav.pop();
      return;
    }
    if (page == null) return;
    if (ritmDemoStep.value == 27 || ritmDemoStep.value == 45) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) go(context, page);
      });
      return;
    }
    if ((ritmDemoStep.value > 8 && ritmDemoStep.value < 20) ||
        (ritmDemoStep.value > 33 && ritmDemoStep.value <= 36) ||
        (ritmDemoStep.value > 59 && ritmDemoStep.value <= 65)) {
      nav.pop();
    }
    go(context, page);
  }

  @override
  Widget build(BuildContext c) {
    final bottom = RS.tabBarClearance + MediaQuery.paddingOf(c).bottom;
    String band = 'Синхронизация, будильник, жесты';
    try {
      final b = c.select<AppState, double?>((a) => a.device.batteryPct);
      if (b != null) band = 'Заряд ${pct(b)} · будильник, жесты';
    } catch (_) {}
    return DecoratedBox(
      decoration: RC.background,
      child: ListView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(RS.screen, 4, RS.screen, bottom),
        children: [
          const SizedBox(
            height: 44,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Ещё', style: RT.h1),
            ),
          ),
          const SizedBox(height: RS.cardGap),
          RGroup(
            rows: [
              RRow(
                icon: LucideIcons.circleUser,
                title: 'Профиль',
                sub: 'Фото, имя, возраст, рост, вес, пульс',
                onTap: () => go(c, const RitmProfileScreen()),
              ),
              RRow(
                icon: LucideIcons.watch,
                title: 'Браслет',
                sub: band,
                onTap: () => go(c, const RitmBandScreen()),
              ),
              RRow(
                icon: LucideIcons.gitCompareArrows,
                title: 'Источники и сверка',
                sub: 'Браслет, Apple Watch, Здоровье',
                onTap: () => go(c, const RitmSourcesScreen()),
              ),
              RRow(
                icon: LucideIcons.bell,
                title: 'Уведомления',
                sub: 'Здоровье, браслет, будильник, итоги',
                onTap: () => go(c, const NotificationSettings()),
              ),
              RRow(
                icon: LucideIcons.sparkles,
                title: 'Помощник',
                sub: 'Ключ и модель',
                onTap: () => go(c, const RitmAssistantSettings()),
              ),
              RRow(
                icon: LucideIcons.database,
                title: 'Данные',
                sub: 'Импорт CSV WHOOP, экспорт, удаление',
                onTap: () => go(c, const RitmDataScreen()),
              ),
              RRow(
                icon: LucideIcons.appWindow,
                title: 'Значок',
                sub: 'Три варианта иконки «Ритм»',
                onTap: () => go(c, const RitmIconScreen()),
              ),
              RRow(
                icon: LucideIcons.info,
                title: 'О приложении',
                sub: 'Версия, лицензия, сообщить о проблеме',
                onTap: () => go(c, const RitmAboutScreen()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Профиль ─────────────────────────

class RitmProfileScreen extends StatelessWidget {
  const RitmProfileScreen({super.key});

  Future<void> _photo(BuildContext c) async {
    await showRSheet<void>(
      c,
      (sc) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RButton(
            LucideIcons.image,
            'Выбрать из галереи',
            onTap: () {
              Navigator.of(sc).pop();
              unawaited(RitmAvatar.pick());
            },
          ),
          const SizedBox(height: 8),
          RButton(
            LucideIcons.camera,
            'Сделать фото',
            onTap: () {
              Navigator.of(sc).pop();
              unawaited(RitmAvatar.pick(camera: true));
            },
          ),
          if (RitmAvatar.path.value != null) ...[
            const SizedBox(height: 8),
            RButton(
              LucideIcons.trash2,
              'Удалить фото',
              kind: RButtonKind.ghost,
              onTap: () {
                Navigator.of(sc).pop();
                unawaited(RitmAvatar.remove());
              },
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    unawaited(RitmAvatar.load());
    String name = '';
    bool cycle = false;
    AppState? app;
    try {
      app = c.watch<AppState>();
      name = (app.user?['name'] ?? '').toString();
      if (kRitmDemo && name.isEmpty) name = 'Михаил';
      cycle = app.cycleTrackingEnabled;
    } catch (_) {}
    return RPage(
      title: 'Профиль',
      children: [
        Center(
          child: GestureDetector(
            onTap: () => _photo(c),
            child: Column(
              children: [
                ValueListenableBuilder<String?>(
                  valueListenable: RitmAvatar.path,
                  builder: (_, p, _) => RAvatar(
                    size: 72,
                    path: kRitmDemo ? ritmDemoAvatarPath() : p,
                    name: name,
                  ),
                ),
                const SizedBox(height: 8),
                Text(name.isEmpty ? 'Без имени' : name, style: RT.title),
                const SizedBox(height: 2),
                Text(
                  'Изменить фото',
                  style: RT.label.copyWith(color: RC.brandA),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RS.sectionGap),
        const RitmBirthGroup(),
        const SizedBox(height: RS.cardGap),
        RGroup(
          rows: [
            RRow(
              icon: LucideIcons.userPen,
              title: 'Данные профиля',
              sub: 'Имя, дата рождения, пол, рост, вес, макс. пульс',
              onTap: () => go(c, const EditProfile()),
            ),
            RRow(
              icon: LucideIcons.droplet,
              title: 'Отслеживание цикла',
              sub: 'Добавляет карточку «Цикл» во вкладку «Здоровье»',
              trailing: RSwitch(
                value: cycle,
                onChanged: app == null
                    ? null
                    : (v) => app!.setCycleTrackingEnabled(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Фото хранится только на этом телефоне.',
            style: RT.small,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Дата рождения (B4) ─────────────────────────

const _kMonthsGen = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа',
  'сентября', 'октября', 'ноября', 'декабря',
];

/// «21 марта 1989 · 37 лет».
String birthLine(DateTime b, DateTime now) {
  final a = ageOn(b, now);
  return '${b.day} ${_kMonthsGen[b.month - 1]} ${b.year} · $a ${plural(a, 'год', 'года', 'лет')}';
}

/// Дата рождения для биовозраста: показ, выбор, «Взять из Здоровья».
/// Возраст нигде не хранится числом сам по себе — считается от даты.
class RitmBirthGroup extends StatefulWidget {
  const RitmBirthGroup({super.key});

  @override
  State<RitmBirthGroup> createState() => _RitmBirthGroupState();
}

class _RitmBirthGroupState extends State<RitmBirthGroup> {
  String? _note;
  bool _busy = false;

  DateTime? _birth(BuildContext c) {
    final demo = ritmDemoBirth();
    if (demo != null) return demo;
    try {
      return parseBirth(c.watch<AppState>().user?['birth_date']);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(DateTime b, {String? sex}) async {
    try {
      await context.read<AppState>().updateProfile({
        'birth_date': birthIso(b),
        // Edge читает `age` в других расчётах — держим его из даты.
        'age': ageOn(b, DateTime.now()),
        'sex': ?sex,
      });
    } catch (_) {}
  }

  Future<void> _fromHealth() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    final r = await RitmHealthKitChannel.characteristics();
    if (!mounted) return;
    final b = r?.birth;
    if (b != null) await _save(b, sex: r?.sex);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = r == null
          ? 'Здоровье недоступно на этом устройстве'
          : b == null
          ? 'В «Здоровье» дата рождения не указана или доступ к ней не дан: Здоровье → Профиль → Данные о здоровье'
          : 'Взято из «Здоровья»: ${birthLine(b, DateTime.now())}';
    });
  }

  Future<void> _pick(BuildContext c, DateTime? cur) async {
    final now = DateTime.now();
    var v = cur ?? DateTime(now.year - 35, 1, 1);
    final ok = await showRSheet<bool>(
      c,
      (sc) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Дата рождения', style: RT.title),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: CupertinoTheme(
              data: const CupertinoThemeData(brightness: Brightness.dark),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: v,
                minimumYear: 1920,
                maximumDate: now,
                onDateTimeChanged: (d) => v = d,
              ),
            ),
          ),
          const SizedBox(height: 12),
          RButton(
            LucideIcons.check,
            'Сохранить',
            kind: RButtonKind.primary,
            onTap: () => Navigator.of(sc).pop(true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _save(DateTime(v.year, v.month, v.day));
      if (mounted) setState(() => _note = null);
    }
  }

  @override
  Widget build(BuildContext c) {
    final b = _birth(c);
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RGroup(
          title: 'Для биовозраста',
          rows: [
            RRow(
              icon: LucideIcons.cake,
              title: 'Дата рождения',
              sub: b == null ? 'не указана — биовозраст не считается' : birthLine(b, now),
              onTap: () => _pick(c, b),
            ),
            RRow(
              icon: LucideIcons.heart,
              iconColor: RC.red,
              title: 'Взять из «Здоровья»',
              sub: 'Дата рождения и пол из профиля Apple',
              trailing: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: RC.ink2),
                    )
                  : null,
              onTap: _fromHealth,
            ),
          ],
        ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(_note!, style: RT.small),
          ),
      ],
    );
  }
}

// ───────────────────────── Браслет ─────────────────────────

class RitmBandScreen extends StatefulWidget {
  const RitmBandScreen({super.key});
  @override
  State<RitmBandScreen> createState() => _RitmBandScreenState();
}

class _RitmBandScreenState extends State<RitmBandScreen> {
  bool _syncing = false;

  Future<void> _sync(AppState app) async {
    setState(() => _syncing = true);
    try {
      await app.syncNow().timeout(const Duration(seconds: 90));
    } catch (_) {}
    if (mounted) setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext c) {
    AppState? app;
    try {
      app = c.watch<AppState>();
    } catch (_) {}
    final demo = ritmDemoSources();
    final model =
        demo?.model ??
        bandModel(
          generation: app?.paired?.generation,
          maverick: app?.pairedIsMaverick ?? false,
        );
    final bat = demo?.battery ?? app?.device.batteryPct;
    final ts = demo?.lastSync == null
        ? app?.lastSynced?.tsEpoch
        : demo!.lastSync!.millisecondsSinceEpoch ~/ 1000;
    final status = [
      demo != null
          ? 'подключён'
          : app == null || !app.isPaired
          ? 'не подключён'
          : app.isConnected
          ? 'подключён'
          : 'нет связи',
      if (bat != null) pct(bat),
      if (ts != null)
        'синхронизация ${agoRu(DateTime.fromMillisecondsSinceEpoch(ts * 1000), DateTime.now())}',
    ].join(' · ');
    return RPage(
      title: 'Браслет',
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(model, style: RT.title),
              if ((demo?.bandName ?? app?.device.strapName ?? '')
                  .isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(demo?.bandName ?? app!.device.strapName!, style: RT.small),
              ],
              const SizedBox(height: 4),
              Text(status, style: RT.body),
              const SizedBox(height: 12),
              RButton(
                LucideIcons.refreshCw,
                _syncing ? 'Синхронизирую…' : 'Синхронизировать',
                height: 44,
                onTap: app == null || !app.isPaired || _syncing
                    ? null
                    : () => _sync(app!),
              ),
            ],
          ),
        ),
        const SizedBox(height: RS.cardGap),
        RGroup(
          rows: [
            RRow(
              icon: LucideIcons.bluetooth,
              title: 'Переподключить',
              sub: 'Сопряжение и состояние связи',
              onTap: () => go(c, const MyDevices()),
            ),
            RRow(
              icon: LucideIcons.alarmClock,
              title: 'Умный будильник',
              sub: 'Вибрация браслета в лёгкой фазе сна',
              onTap: () => go(c, const AlarmScreen()),
            ),
            RRow(
              icon: LucideIcons.hand,
              title: 'Жесты',
              sub: 'Что делает двойное касание',
              onTap: () => go(c, const BandGestures()),
            ),
            RRow(
              icon: LucideIcons.messageSquare,
              title: 'Уведомления на браслет',
              sub: 'Вибрация при сообщениях телефона',
              onTap: () => go(c, const BandNotifications()),
            ),
          ],
        ),
      ],
    );
  }
}

// ───────────────────────── Помощник ─────────────────────────

/// Кнопка «Помощник» у таб-бара: чат, если ключ задан; иначе — экран
/// «укажите ключ в Ещё → Помощник» (ТЗ v2 §0, §9).
void openRitmAssistant(BuildContext c) {
  var ready = false;
  try {
    ready = c.read<CoachConfig>().configured;
  } catch (_) {}
  go(c, ready ? const CoachScreen() : const RitmAssistantSettings());
}

class RitmAssistantSettings extends StatelessWidget {
  const RitmAssistantSettings({super.key});

  @override
  Widget build(BuildContext c) {
    var ready = false;
    var model = '';
    try {
      final cfg = c.watch<CoachConfig>();
      ready = cfg.configured;
      model = cfg.model;
    } catch (_) {}
    return RPage(
      title: 'Помощник',
      children: [
        RCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  RitmMark(size: 28),
                  SizedBox(width: 10),
                  Text('Помощник Ритма', style: RT.title),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                ready
                    ? 'Подключён${model.isEmpty ? '' : ' · $model'}. Отвечает по вашим сводкам за 7 дней: сон, восстановление, нагрузка, пульс покоя, ВСР, тренировки. Не диагноз и не лечение.'
                    : 'Укажите свой ключ OpenAI — помощник будет отвечать по вашим сводкам за 7 дней. Ключ хранится в связке ключей телефона.',
                style: RT.body,
              ),
              const SizedBox(height: 14),
              if (ready) ...[
                RButton(
                  LucideIcons.messageCircle,
                  'Открыть чат',
                  kind: RButtonKind.primary,
                  onTap: () => go(c, const CoachScreen()),
                ),
                const SizedBox(height: 8),
              ],
              RButton(
                LucideIcons.keyRound,
                ready ? 'Ключ и модель' : 'Указать ключ',
                onTap: () => go(c, const CoachSetup()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Значок ─────────────────────────

class RitmIconScreen extends StatefulWidget {
  const RitmIconScreen({super.key});
  @override
  State<RitmIconScreen> createState() => _RitmIconScreenState();
}

class _RitmIconScreenState extends State<RitmIconScreen> {
  AppIconChoice _cur = AppIconChoice.ritm;
  bool _available = true;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    if (kRitmDemo) return;
    final ok = await AppIcon.available();
    final cur = await AppIcon.current();
    if (mounted) setState(() => (_available = ok, _cur = cur));
  }

  Future<void> _pick(AppIconChoice c) async {
    if (kRitmDemo) {
      setState(() => _cur = c);
      return;
    }
    await AppIcon.set(c);
    await _read();
  }

  @override
  Widget build(BuildContext c) => RPage(
    title: 'Значок',
    children: [
      Row(
        children: [
          for (final ch in AppIconChoice.values) ...[
            if (ch != AppIconChoice.values.first) const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                button: true,
                selected: ch == _cur,
                label: ch.label,
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: _available ? () => _pick(ch) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: RC.card,
                      borderRadius: BorderRadius.circular(RS.rCard),
                      border: Border.all(
                        color: ch == _cur ? RC.brandA : const Color(0x00000000),
                        width: 2,
                      ),
                    ),
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(ch.asset, width: 60, height: 60),
                        ),
                        const SizedBox(height: 10),
                        Text(ch.label, style: RT.label),
                        const SizedBox(height: 4),
                        Icon(
                          ch == _cur
                              ? LucideIcons.circleCheck
                              : LucideIcons.circle,
                          size: 18,
                          color: ch == _cur ? RC.brandA : RC.ink3,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 12),
      Text(
        _available
            ? 'iOS спросит подтверждение при смене значка.'
            : 'На этом устройстве iOS не разрешает менять значок.',
        style: RT.small,
      ),
    ],
  );
}

// ───────────────────────── О приложении ─────────────────────────

class RitmAboutScreen extends StatelessWidget {
  const RitmAboutScreen({super.key});

  @override
  Widget build(BuildContext c) => RPage(
    title: 'О приложении',
    children: [
      Row(
        children: [
          const RitmMark(size: 44),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ритм', style: RT.h1),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (c, s) => Text(
                  s.hasData
                      ? 'Версия ${s.data!.version} (${s.data!.buildNumber})'
                      : ' ',
                  style: RT.small,
                ),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: RS.sectionGap),
      const RCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Не медицинское изделие', style: RT.title),
            SizedBox(height: 6),
            Text(
              'Ритм показывает оценки по данным браслета: сон, восстановление, '
              'нагрузку, пульс. Это не диагноз и не замена врачу. При плохом '
              'самочувствии, боли в груди или нерегулярном пульсе обращайтесь к врачу.',
              style: RT.body,
            ),
          ],
        ),
      ),
      const SizedBox(height: RS.cardGap),
      const RCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Как считаются показатели', style: RT.title),
            SizedBox(height: 6),
            Text(
              'Сон — доля сна от вашей потребности (зелёный от 85%, жёлтый 70–84%).\n'
              'Восстановление — по ВСР, пульсу покоя, дыханию и температуре кожи '
              'ночью относительно вашей нормы за 14+ ночей (зелёный от 67%, красный до 33%).\n'
              'Нагрузка — 0–21 по пульсу за день; каждая следующая единица даётся труднее.\n'
              'Монитор здоровья — ночные показатели против вашего коридора за 30 ночей.',
              style: RT.body,
            ),
          ],
        ),
      ),
      const SizedBox(height: RS.cardGap),
      RCard(
        onTap: () => open3rdPartyLink(kRitmRepoUrl),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RCardHead('Исходный код и лицензия'),
            SizedBox(height: 8),
            Text(
              'AGPL-3.0, форк OpenStrap Edge. Исходный код «Ритма» открыт: '
              'github.com/fomichewM/ritm',
              style: RT.body,
            ),
          ],
        ),
      ),
      const SizedBox(height: RS.cardGap),
      RButton(
        LucideIcons.messageSquareWarning,
        'Сообщить о проблеме',
        onTap: () => go(c, const ReportIssueScreen()),
      ),
    ],
  );
}

/// Вкладочный экран Edge как обычная страница с кнопкой «назад».
class RitmPaged extends StatelessWidget {
  final String title;
  final Widget child;
  const RitmPaged({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext c) => Scaffold(
    backgroundColor: RC.bg,
    appBar: AppBar(
      backgroundColor: RC.bg,
      foregroundColor: RC.ink,
      surfaceTintColor: RC.bg,
      elevation: 0,
      toolbarHeight: 44,
      title: Text(title, style: RT.title),
    ),
    body: Semantics(label: title, child: child),
  );
}


/// «Данные» (§8 п. 6): импорт CSV WHOOP и засев нормы из «Здоровья» (B2),
/// дальше — экран Edge с экспортом, копиями и удалением.
class RitmDataScreen extends StatefulWidget {
  const RitmDataScreen({super.key});
  @override
  State<RitmDataScreen> createState() => _RitmDataScreenState();
}

class _RitmDataScreenState extends State<RitmDataScreen> {
  RitmSeed _seed = RitmSeed.cached;
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    if (kRitmDemo) {
      _seed = RitmSeed(
        whoop: {
          for (var i = 1; i <= 30; i++)
            'd$i': const SeedNight(rhr: 52, hrv: 50, resp: 14.2),
        },
      );
      _msg = 'Добавлено 30 ночей из CSV WHOOP';
    } else {
      unawaited(RitmSeed.load().then((s) => mounted ? setState(() => _seed = s) : null));
    }
  }

  Future<void> _whoop() async {
    if (kRitmDemo) return;
    setState(() => (_busy = true, _msg = null));
    try {
      final r = await FilePicker.platform.pickFiles(allowMultiple: true);
      final paths = [for (final f in r?.files ?? const <PlatformFile>[]) ?f.path];
      if (paths.isEmpty) return;
      final nights = <String, SeedNight>{..._seed.whoop};
      var found = 0;
      for (final pth in paths) {
        final got = parseWhoopCycles(await File(pth).readAsString());
        found += got.length;
        nights.addAll(got);
      }
      // История дней — тем же импортом, что у Edge (не заменяет ночи браслета).
      try {
        if (mounted) await context.read<AppState>().importWhoopCsvs(paths);
      } catch (_) {}
      final s = _seed.copyWith(whoop: nights);
      await RitmSeed.save(s);
      if (mounted) {
        setState(() {
          _seed = s;
          _msg = found == 0
              ? 'В файле нет колонок пульса покоя и ВСР — нужен physiological_cycles.csv'
              : 'Добавлено $found ${plural(found, 'ночь', 'ночи', 'ночей')} из CSV WHOOP';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _msg = 'Не удалось прочитать файл');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _health() async {
    if (kRitmDemo) return;
    setState(() => (_busy = true, _msg = null));
    try {
      final rd = RitmWatchReader();
      await rd.requestAccess();
      final s = await rd.seedFromHealth(_seed);
      await RitmSeed.save(s);
      if (mounted) {
        final n = s.watch.length;
        setState(() {
          _seed = s;
          _msg = n == 0
              ? 'В «Здоровье» нет пульса покоя от Apple Watch за 60 дней'
              : 'Из «Здоровья»: $n ${plural(n, 'ночь', 'ночи', 'ночей')} пульса покоя, ${s.watchSdnn.length} — ВСР';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final w = _seed.whoop.length, a = _seed.watch.length;
    return RPage(
      title: 'Данные',
      children: [
        RGroup(
          title: 'История для личной нормы',
          rows: [
            RRow(
              icon: LucideIcons.fileUp,
              title: 'Импорт CSV WHOOP',
              sub: 'physiological_cycles.csv из «Мои данные» WHOOP',
              onTap: _busy ? null : _whoop,
            ),
            RRow(
              icon: LucideIcons.heartPulse,
              title: 'Взять историю из «Здоровья»',
              sub: 'Пульс покоя и ВСР Apple Watch за 60 дней — норма будет точной сразу',
              onTap: _busy ? null : _health,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            _msg ??
                (w + a == 0
                    ? 'Пока у браслета мало своих ночей, норма Монитора здоровья строится по этой истории. Ночи браслета всегда важнее.'
                    : 'В норме учтено: WHOOP — $w, Apple Watch — $a. Ночи браслета всегда важнее.'),
            style: RT.small,
          ),
        ),
        if (_msg != null) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'В норме учтено: WHOOP — $w, Apple Watch — $a. Ночи браслета всегда важнее.',
              style: RT.small,
            ),
          ),
        ],
        const SizedBox(height: RS.sectionGap),
        RGroup(
          title: 'Копии и удаление',
          rows: [
            RRow(
              icon: LucideIcons.database,
              title: 'Экспорт, копии, удаление',
              sub: 'CSV, полная копия, удалить всё',
              onTap: kRitmDemo ? null : () => go(c, const DataScreen()),
            ),
          ],
        ),
      ],
    );
  }
}
