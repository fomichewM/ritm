import Flutter
import HealthKit

// «Ритм» — канал `ritm/health` (ТЗ v2 §10, сборка B3). Только чтение того,
// чего нет в плагине `health`: VO₂max, SpO₂, температура запястья во сне,
// восстановление пульса за минуту, ЭКГ Apple Watch, тренировки с источником
// (bundle, productType, модель устройства) и пульсом внутри и после них,
// пульс покоя и сон с источником, шаги дня по источникам.
//
// Отдаём СЫРЫЕ сэмплы в единицах HealthKit (SpO₂ — доля 0…1, как отдаёт
// HKUnit.percent()), Dart сам считает медианы, коридоры и сверку — так
// логика проверяется юнит-тестами на тех же фикстурах.
//
// DEBUG (и только симулятор; в сборке для телефона кода нет): метод `debugSeed` пишет в «Здоровье» симулятора тестовые записи
// с устройством «Apple Watch» и меткой RitmDebugSeed — чтобы показать, что
// данные Watch проходят по этому каналу. ЭКГ приложение записать не может
// (у HKElectrocardiogram нет публичного конструктора), поэтому в DEBUG после
// засева канал добавляет к настоящим записям ЭКГ синтетическую с флагом
// `synthetic: true`. В сборке для телефона (TestFlight) этого кода нет, а Dart
// вызывает его только при kDebugMode.
enum RitmHealthKit {
  private static let channelName = "ritm/health"
  private static let store = HKHealthStore()
  private static let seededKey = "ritm.debugSeeded.v4"
  private static let bgKey = "ritm.bgDelivery.v1"
  private static var channelRef: FlutterMethodChannel?
  private static var observers: [HKObserverQuery] = []

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channelRef = channel
    // B4½ D5: наблюдатели нужно ставить на каждом запуске (в т.ч. фоновом,
    // когда iOS будит приложение по новой записи) — если пользователь уже
    // включил доставку.
    if UserDefaults.standard.bool(forKey: bgKey) { startObservers() }
    channel.setMethodCallHandler { call, result in
      let reply: (Any?) -> Void = { v in DispatchQueue.main.async { result(v) } }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "available":
        reply(HKHealthStore.isHealthDataAvailable())
      case "readTypes":
        reply(readTypes().map { $0.identifier })
      case "requestAuthorization":
        guard HKHealthStore.isHealthDataAvailable() else { reply(false); return }
        store.requestAuthorization(toShare: [], read: readTypes()) { ok, _ in reply(ok) }
      case "snapshot":
        guard HKHealthStore.isHealthDataAvailable() else {
          reply(["available": false]); return
        }
        let nowMs = (args["nowMs"] as? NSNumber)?.doubleValue
          ?? Date().timeIntervalSince1970 * 1000
        snapshot(now: Date(timeIntervalSince1970: nowMs / 1000)) { reply($0) }
      case "workoutsIn":
        // Только тренировки Watch в окне — для правила записи §10.11.
        guard HKHealthStore.isHealthDataAvailable(),
          let f = (args["fromMs"] as? NSNumber)?.doubleValue,
          let t = (args["toMs"] as? NSNumber)?.doubleValue
        else { reply([]); return }
        workouts(
          from: Date(timeIntervalSince1970: f / 1000),
          to: Date(timeIntervalSince1970: t / 1000), withHr: false) { reply($0) }
      case "characteristics":
        // B4: дата рождения и пол — для биовозраста (кнопка «Взять из Здоровья»).
        guard HKHealthStore.isHealthDataAvailable() else { reply(nil); return }
        let chars: Set<HKObjectType> = [
          HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
        ]
        store.requestAuthorization(toShare: [], read: chars) { _, _ in
          var d: [String: Any] = [:]
          if let c = try? store.dateOfBirthComponents(), let y = c.year, let m = c.month,
            let dd = c.day
          {
            d["dob"] = String(format: "%04d-%02d-%02d", y, m, dd)
          }
          if let s = try? store.biologicalSex().biologicalSex {
            switch s {
            case .female: d["sex"] = "f"
            case .male: d["sex"] = "m"
            default: break
            }
          }
          reply(d)
        }
      case "startBackgroundDelivery":
        // B4½ D5: фоновая доставка «Здоровья» — кольца без открытия приложения.
        guard HKHealthStore.isHealthDataAvailable() else { reply(false); return }
        UserDefaults.standard.set(true, forKey: bgKey)
        startObservers()
        reply(true)
      case "debugSeed":
        #if DEBUG || targetEnvironment(simulator)
          let nowMs = (args["nowMs"] as? NSNumber)?.doubleValue
            ?? Date().timeIntervalSince1970 * 1000
          debugSeed(now: Date(timeIntervalSince1970: nowMs / 1000)) { reply($0) }
        #else
          reply(["ok": false, "error": "release"])
        #endif
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: фоновая доставка (B4½ D5)

  /// Типы для HKObserverQuery + enableBackgroundDelivery (ТЗ v3 §4.2 D5).
  static func bgTypes() -> [HKSampleType] {
    var t: [HKSampleType] = [
      HKCategoryType(.sleepAnalysis),
      HKObjectType.workoutType(),
      HKQuantityType(.restingHeartRate),
      HKQuantityType(.heartRateVariabilitySDNN),
      HKQuantityType(.oxygenSaturation),
      HKQuantityType(.vo2Max),
      HKQuantityType(.stepCount),
    ]
    t.append(HKObjectType.electrocardiogramType())
    return t
  }

  /// Наблюдатели: на новую запись — событие `changed` в Dart; completion
  /// вызывается, когда Dart досчитал (или через 25 с — iOS не любит ждать).
  static func startObservers() {
    guard HKHealthStore.isHealthDataAvailable() else { return }
    // Повторный вызов (после выдачи доступа) пересоздаёт наблюдателей: до
    // разрешения iOS их останавливает («Authorization not determined»).
    for q in observers { store.stop(q) }
    observers.removeAll()
    for type in bgTypes() {
      let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
        if error != nil { completion(); return }
        var done = false
        let finish = {
          if !done { done = true; completion() }
        }
        DispatchQueue.main.async {
          if let ch = channelRef {
            ch.invokeMethod("changed", arguments: ["type": type.identifier]) { _ in finish() }
          } else {
            finish()
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 25) { finish() }
        }
      }
      observers.append(q)
      store.execute(q)
      let freq: HKUpdateFrequency = type == HKQuantityType(.stepCount) ? .hourly : .immediate
      store.enableBackgroundDelivery(for: type, frequency: freq) { _, _ in }
    }
  }

  // MARK: типы

  static func readTypes() -> Set<HKObjectType> {
    var s: Set<HKObjectType> = [
      HKQuantityType(.vo2Max),
      HKQuantityType(.oxygenSaturation),
      HKQuantityType(.restingHeartRate),
      HKQuantityType(.heartRate),
      HKQuantityType(.stepCount),
      HKCategoryType(.sleepAnalysis),
      HKObjectType.workoutType(),
      HKObjectType.electrocardiogramType(),
    ]
    if #available(iOS 16.0, *) {
      s.insert(HKQuantityType(.appleSleepingWristTemperature))
      s.insert(HKQuantityType(.heartRateRecoveryOneMinute))
    }
    return s
  }

  // MARK: источник

  static func isWatch(_ s: HKSample) -> Bool {
    if (s.device?.model ?? "").lowercased().contains("watch") { return true }
    return (s.sourceRevision.productType ?? "").hasPrefix("Watch")
  }

  static func src(_ s: HKObject) -> [String: Any] {
    var d: [String: Any] = [
      "bundle": s.sourceRevision.source.bundleIdentifier,
      "name": s.sourceRevision.source.name,
      "product": s.sourceRevision.productType ?? "",
      "model": s.device?.model ?? "",
    ]
    if (s.metadata?["RitmDebugSeed"] as? Bool) == true { d["seed"] = true }
    return d
  }

  static func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

  // MARK: запросы

  private static func quantities(
    _ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date,
    completion: @escaping ([[String: Any]]) -> Void
  ) {
    let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let q = HKSampleQuery(
      sampleType: HKQuantityType(id), predicate: p, limit: HKObjectQueryNoLimit,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
    ) { _, samples, _ in
      let out: [[String: Any]] = (samples as? [HKQuantitySample] ?? []).map {
        ["v": $0.quantity.doubleValue(for: unit), "s": ms($0.startDate), "e": ms($0.endDate),
         "src": src($0)]
      }
      completion(out)
    }
    store.execute(q)
  }

  private static func sleep(
    from: Date, to: Date, completion: @escaping ([[String: Any]]) -> Void
  ) {
    let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let q = HKSampleQuery(
      sampleType: HKCategoryType(.sleepAnalysis), predicate: p, limit: HKObjectQueryNoLimit,
      sortDescriptors: nil
    ) { _, samples, _ in
      completion((samples as? [HKCategorySample] ?? []).map {
        ["v": $0.value, "s": ms($0.startDate), "e": ms($0.endDate), "src": src($0)]
      })
    }
    store.execute(q)
  }

  private static func ecgName(_ c: HKElectrocardiogram.Classification) -> String {
    switch c {
    case .sinusRhythm: return "sinusRhythm"
    case .atrialFibrillation: return "atrialFibrillation"
    case .inconclusiveLowHeartRate: return "inconclusiveLowHeartRate"
    case .inconclusiveHighHeartRate: return "inconclusiveHighHeartRate"
    case .inconclusivePoorReading: return "inconclusivePoorReading"
    case .inconclusiveOther: return "inconclusiveOther"
    case .unrecognized: return "unrecognized"
    case .notSet: return "notSet"
    @unknown default: return "unrecognized"
    }
  }

  private static func ecgs(
    from: Date, to: Date, completion: @escaping ([[String: Any]]) -> Void
  ) {
    let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let q = HKSampleQuery(
      sampleType: HKObjectType.electrocardiogramType(), predicate: p, limit: 20,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
    ) { _, samples, _ in
      completion((samples as? [HKElectrocardiogram] ?? []).map { e in
        var d: [String: Any] = [
          "s": ms(e.startDate), "e": ms(e.endDate), "cls": ecgName(e.classification),
          "src": src(e),
        ]
        if let hr = e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
          d["hr"] = hr
        }
        return d
      })
    }
    store.execute(q)
  }

  /// Тренировки в окне. [withHr] — добавить пульс внутри тренировки (среднее,
  /// максимум, число замеров) и замеры 0–120 с после конца (для HRR).
  static func workouts(
    from: Date, to: Date, withHr: Bool, completion: @escaping ([[String: Any]]) -> Void
  ) {
    let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let q = HKSampleQuery(
      sampleType: HKObjectType.workoutType(), predicate: p, limit: 50,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
    ) { _, samples, _ in
      let ws = samples as? [HKWorkout] ?? []
      if ws.isEmpty { completion([]); return }
      let group = DispatchGroup()
      let lock = DispatchQueue(label: "ritm.health.workouts")
      var out = [[String: Any]](repeating: [:], count: ws.count)
      for (i, w) in ws.enumerated() {
        var d: [String: Any] = [
          "uuid": w.uuid.uuidString, "s": ms(w.startDate), "e": ms(w.endDate),
          "type": Int(w.workoutActivityType.rawValue), "src": src(w),
        ]
        if #available(iOS 16.0, *) {
          if let m = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()
            ?? w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()
            ?? w.statistics(for: HKQuantityType(.distanceSwimming))?.sumQuantity()
          {
            d["dist"] = m.doubleValue(for: .meter())
          }
          if let k = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            d["kcal"] = k.doubleValue(for: .kilocalorie())
          }
        } else {
          if let m = w.totalDistance { d["dist"] = m.doubleValue(for: .meter()) }
          if let k = w.totalEnergyBurned { d["kcal"] = k.doubleValue(for: .kilocalorie()) }
        }
        out[i] = d
        guard withHr else { continue }
        group.enter()
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hp = HKQuery.predicateForSamples(
          withStart: w.startDate, end: w.endDate.addingTimeInterval(120), options: [])
        let hq = HKSampleQuery(
          sampleType: HKQuantityType(.heartRate), predicate: hp, limit: HKObjectQueryNoLimit,
          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, hs, _ in
          var inside: [Double] = []
          var series: [[Double]] = []
          var after: [[Double]] = []
          for h in (hs as? [HKQuantitySample] ?? []) where isWatch(h) {
            let v = h.quantity.doubleValue(for: bpm)
            if h.startDate <= w.endDate {
              inside.append(v)
              series.append([Double(ms(h.startDate)), v])
            } else {
              after.append([Double(ms(h.startDate)), v])
            }
          }
          lock.async {
            if !inside.isEmpty {
              out[i]["hrAvg"] = inside.reduce(0, +) / Double(inside.count)
              out[i]["hrMax"] = inside.max()
              out[i]["hrN"] = inside.count
              // B4: ряд пульса для графика по зонам (не больше ~600 точек).
              let stride = max(1, series.count / 600)
              out[i]["hrSeries"] = Swift.stride(from: 0, to: series.count, by: stride).map {
                series[$0]
              }
            }
            out[i]["hrAfter"] = after
            group.leave()
          }
        }
        store.execute(hq)
      }
      group.notify(queue: lock) { completion(out) }
    }
    store.execute(q)
  }

  /// Шаги за день: все источники (как считает «Здоровье», без двойного счёта),
  /// только Watch, и часы ношения Watch (часы суток с пульсом Watch).
  private static func steps(
    dayStart: Date, now: Date, completion: @escaping ([String: Any]) -> Void
  ) {
    let group = DispatchGroup()
    let lock = DispatchQueue(label: "ritm.health.steps")
    var d: [String: Any] = [:]
    let p = HKQuery.predicateForSamples(withStart: dayStart, end: now, options: [])
    group.enter()
    let all = HKStatisticsQuery(
      quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: p,
      options: .cumulativeSum
    ) { _, st, _ in
      lock.async {
        if let v = st?.sumQuantity()?.doubleValue(for: .count()) { d["all"] = v }
        group.leave()
      }
    }
    store.execute(all)
    group.enter()
    let raw = HKSampleQuery(
      sampleType: HKQuantityType(.stepCount), predicate: p, limit: HKObjectQueryNoLimit,
      sortDescriptors: nil
    ) { _, ss, _ in
      var w = 0.0
      var any = false
      for s in (ss as? [HKQuantitySample] ?? []) where isWatch(s) {
        w += s.quantity.doubleValue(for: .count())
        any = true
      }
      lock.async {
        if any { d["watch"] = w }
        group.leave()
      }
    }
    store.execute(raw)
    group.enter()
    let hr = HKSampleQuery(
      sampleType: HKQuantityType(.heartRate), predicate: p, limit: HKObjectQueryNoLimit,
      sortDescriptors: nil
    ) { _, hs, _ in
      var hours = Set<Int>()
      for h in (hs as? [HKQuantitySample] ?? []) where isWatch(h) {
        hours.insert(Int(h.startDate.timeIntervalSince(dayStart) / 3600))
      }
      lock.async {
        d["watchHours"] = hours.count
        group.leave()
      }
    }
    store.execute(hr)
    group.notify(queue: lock) { completion(d) }
  }

  // MARK: снимок

  static func snapshot(now: Date, completion: @escaping (Any?) -> Void) {
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: now)
    let nightFrom = dayStart.addingTimeInterval(-6 * 3600)  // 18:00 вчера
    let bpm = HKUnit.count().unitDivided(by: .minute())
    let group = DispatchGroup()
    let lock = DispatchQueue(label: "ritm.health.snapshot")
    var out: [String: Any] = ["available": true, "nowMs": ms(now)]
    func put(_ k: String, _ v: Any) { lock.async { out[k] = v; group.leave() } }

    group.enter()
    quantities(
      .vo2Max, unit: HKUnit(from: "ml/kg*min"), from: now.addingTimeInterval(-90 * 86400),
      to: now
    ) { put("vo2", $0) }
    group.enter()
    quantities(
      .oxygenSaturation, unit: .percent(), from: nightFrom, to: now
    ) { put("spo2", $0) }
    group.enter()
    quantities(.restingHeartRate, unit: bpm, from: now.addingTimeInterval(-2 * 86400), to: now) {
      put("rhr", $0)
    }
    if #available(iOS 16.0, *) {
      group.enter()
      quantities(
        .appleSleepingWristTemperature, unit: .degreeCelsius(),
        from: now.addingTimeInterval(-31 * 86400), to: now
      ) { put("wristTemp", $0) }
      group.enter()
      quantities(
        .heartRateRecoveryOneMinute, unit: bpm, from: now.addingTimeInterval(-7 * 86400), to: now
      ) { put("hrr", $0) }
    }
    group.enter()
    sleep(from: nightFrom, to: now) { put("sleep", $0) }
    group.enter()
    ecgs(from: now.addingTimeInterval(-90 * 86400), to: now) { list in
      var l = list
      #if DEBUG || targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: seededKey) {
          l += debugEcg(now: now)
        }
      #endif
      put("ecg", l)
    }
    group.enter()
    workouts(from: now.addingTimeInterval(-7 * 86400), to: now, withHr: true) {
      put("workouts", $0)
    }
    group.enter()
    steps(dayStart: dayStart, now: now) { put("steps", $0) }
    group.notify(queue: lock) {
      #if DEBUG || targetEnvironment(simulator)
        out["debugSeeded"] = UserDefaults.standard.bool(forKey: seededKey)
      #endif
      completion(out)
    }
  }

  // MARK: DEBUG — засев симулятора

  #if DEBUG || targetEnvironment(simulator)
    private static let watchDevice = HKDevice(
      name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch",
      hardwareVersion: "Watch7,1", firmwareVersion: nil, softwareVersion: "11.0",
      localIdentifier: nil, udiDeviceIdentifier: nil)
    private static let seedMeta: [String: Any] = ["RitmDebugSeed": true]

    private static func debugEcg(now: Date) -> [[String: Any]] {
      let day = Calendar.current.startOfDay(for: now)
      let s1 = day.addingTimeInterval(8 * 3600 + 50 * 60)
      let s2 = day.addingTimeInterval(-86400 + 21 * 3600 + 15 * 60)
      let src: [String: Any] = [
        "bundle": "com.apple.NanoHeartRhythm", "name": "ЭКГ", "product": "Watch7,1",
        "model": "Watch", "seed": true,
      ]
      return [
        ["s": ms(s1), "e": ms(s1.addingTimeInterval(30)), "cls": "sinusRhythm", "hr": 62.0,
         "src": src, "synthetic": true],
        ["s": ms(s2), "e": ms(s2.addingTimeInterval(30)), "cls": "inconclusiveOther",
         "hr": 71.0, "src": src, "synthetic": true],
      ]
    }

    private static func q(_ id: HKQuantityTypeIdentifier, _ v: Double, _ u: HKUnit,
                          _ s: Date, _ e: Date) -> HKQuantitySample {
      HKQuantitySample(
        type: HKQuantityType(id), quantity: HKQuantity(unit: u, doubleValue: v), start: s,
        end: e, device: watchDevice, metadata: seedMeta)
    }

    static func debugSeed(now: Date, completion: @escaping (Any?) -> Void) {
      let share: Set<HKSampleType> = [
        HKQuantityType(.vo2Max), HKQuantityType(.oxygenSaturation),
        HKQuantityType(.restingHeartRate), HKQuantityType(.heartRate),
        HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
      ]
      store.requestAuthorization(toShare: share, read: readTypes()) { ok, err in
        NSLog("[ritm] debugSeed auth ok=%d err=%@", ok ? 1 : 0, err?.localizedDescription ?? "-")
        guard ok else {
          completion(["ok": false, "error": err?.localizedDescription ?? "auth"])
          return
        }
        // Уже засеяно сегодня — не дублируем.
        let day = Calendar.current.startOfDay(for: now)
        let stamp = Int(day.timeIntervalSince1970)
        if UserDefaults.standard.integer(forKey: seededKey + ".day") == stamp {
          UserDefaults.standard.set(true, forKey: seededKey)
          completion(["ok": true, "already": true])
          return
        }
        // Прежний засев (другой версии) убираем, чтобы данные не двоились.
        let mine = HKQuery.predicateForObjects(withMetadataKey: "RitmDebugSeed", allowedValues: [true])
        let g = DispatchGroup()
        for t in share {
          g.enter()
          // Тренировки засева v1 были без метки — их узнаём по источнику.
          let p = t == HKObjectType.workoutType()
            ? HKQuery.predicateForObjects(from: HKSource.default()) : mine
          store.deleteObjects(of: t, predicate: p) { _, _, _ in g.leave() }
        }
        g.wait()
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var objs: [HKObject] = []
        func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Date {
          day.addingTimeInterval(Double(dayOffset * 86400 + h * 3600 + m * 60))
        }
        // VO₂max: шесть замеров за 90 дней (44,8 → 46,2), последний 46,2.
        let vo2 = [44.8, 45.0, 45.3, 45.6, 45.9, 46.2]
        for (i, v) in vo2.enumerated() {
          let t = at(-75 + i * 15, 8, 30)
          objs.append(q(.vo2Max, v, HKUnit(from: "ml/kg*min"), t, t))
        }
        // SpO₂ ночью 23:00–07:00 каждые 30 мин, медиана 96 %.
        let sp = [0.97, 0.96, 0.95, 0.96, 0.97, 0.96, 0.94, 0.96, 0.97, 0.96, 0.95, 0.96, 0.98,
                  0.96, 0.97, 0.96]
        for (i, v) in sp.enumerated() {
          let t = at(-1, 23, 0).addingTimeInterval(Double(i) * 1800)
          objs.append(q(.oxygenSaturation, v, .percent(), t, t))
        }
        // Пульс покоя Watch: вчера 53, сегодня 52.
        objs.append(q(.restingHeartRate, 53, bpm, at(-1, 7, 5), at(-1, 7, 5)))
        objs.append(q(.restingHeartRate, 52, bpm, at(0, 7, 12), at(0, 7, 12)))
        // Сон Watch: 23:12–06:55 стадиями, 7:21 сна.
        // Значения HKCategoryValueSleepAnalysis: 3 — Core, 4 — Deep, 5 — REM, 2 — бодрствование.
        let stages: [(Int, Int)] = [
          (3, 95), (4, 50), (3, 60), (5, 40), (2, 22), (3, 70), (4, 30), (5, 55), (3, 41),
        ]
        var t0 = at(-1, 23, 12)
        for (st, mins) in stages {
          let t1 = t0.addingTimeInterval(Double(mins * 60))
          objs.append(
            HKCategorySample(
              type: HKCategoryType(.sleepAnalysis), value: st, start: t0, end: t1,
              device: watchDevice, metadata: seedMeta))
          t0 = t1
        }
        // Пульс Watch весь день каждые 10 минут (ношение), шаги по часам.
        var t = at(0, 0, 0)
        while t < now {
          let h = Calendar.current.component(.hour, from: t)
          let v = h < 7 ? 52.0 : 68.0
          // Внутри бега 07:40–08:26 пульс пишет сама тренировка (seedWorkout).
          if t < at(0, 7, 40) || t > at(0, 8, 28) {
            objs.append(q(.heartRate, v, bpm, t, t))
          }
          t = t.addingTimeInterval(600)
        }
        // Шаги ≈ дистанции: ходьба 06:42–07:09 (≈ 2 830) + бег 7,24 км (≈ 7 600)
        // + дом; в сумме 10 860 — в пределах 5 % от браслета (§10.10).
        let stepsByHour = [0, 0, 0, 0, 0, 0, 1890, 4380, 4410, 180]
        for (h, n) in stepsByHour.enumerated() where n > 0 {
          let s = at(0, h, 0)
          let e = min(at(0, h, 59), now)
          if s < now { objs.append(q(.stepCount, Double(n), .count(), s, e)) }
        }
        store.save(objs) { ok1, e1 in
          NSLog("[ritm] debugSeed save ok=%d err=%@", ok1 ? 1 : 0, e1?.localizedDescription ?? "-")
          guard ok1 else {
            completion(["ok": false, "error": e1?.localizedDescription ?? "save"])
            return
          }
          seedWorkout(start: at(0, 7, 40), end: at(0, 8, 26), now: now) { ok2, e2 in
            if ok2 {
              UserDefaults.standard.set(true, forKey: seededKey)
              UserDefaults.standard.set(stamp, forKey: seededKey + ".day")
            }
            completion(["ok": ok2, "error": e2 ?? "", "objects": objs.count])
          }
        }
      }
    }

    /// Бег Watch 07:40–08:26: 7,24 км, 512 ккал, пульс каждые 5 с внутри
    /// и спад после финиша (восстановление за минуту ≈ 31).
    private static func seedWorkout(
      start: Date, end: Date, now: Date, completion: @escaping (Bool, String?) -> Void
    ) {
      let bpm = HKUnit.count().unitDivided(by: .minute())
      let cfg = HKWorkoutConfiguration()
      cfg.activityType = .running
      cfg.locationType = .outdoor
      let b = HKWorkoutBuilder(healthStore: store, configuration: cfg, device: watchDevice)
      b.beginCollection(withStart: start) { ok, err in
        guard ok else { completion(false, err?.localizedDescription); return }
        var hr: [HKSample] = []
        var t = start
        var k = 0
        while t < end {
          let v = 146 + 8 * sin(Double(k) / 40) + (k < 60 ? Double(k - 60) / 3 : 0)
          hr.append(q(.heartRate, v, bpm, t, t))
          t = t.addingTimeInterval(5)
          k += 1
        }
        let dist = q(.distanceWalkingRunning, 7240, .meter(), start, end)
        let kcal = q(.activeEnergyBurned, 512, .kilocalorie(), start, end)
        b.add(hr + [dist, kcal]) { ok2, err2 in
          guard ok2 else { completion(false, err2?.localizedDescription); return }
          b.addMetadata(["RitmDebugSeed": true]) { _, _ in }
          b.endCollection(withEnd: end) { ok3, err3 in
            guard ok3 else { completion(false, err3?.localizedDescription); return }
            b.finishWorkout { w, err4 in
              guard w != nil else { completion(false, err4?.localizedDescription); return }
              // После финиша: 158 → 127 за минуту, дальше 118.
              var after: [HKObject] = []
              let pts: [(Double, Double)] = [(5, 158), (20, 149), (40, 136), (60, 127), (90, 121),
                                             (115, 118)]
              for (dt, v) in pts {
                let tt = end.addingTimeInterval(dt)
                after.append(q(.heartRate, v, bpm, tt, tt))
              }
              store.save(after) { ok5, err5 in completion(ok5, err5?.localizedDescription) }
            }
          }
        }
      }
    }
  #endif
}
