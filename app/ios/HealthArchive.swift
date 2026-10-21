import Foundation
import HealthKit
import UIKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

// Full-history Apple Health archive — resumable, incremental, and quiet.
//
// The v1 lane exported `HKSampleQuery(limit: 500)` per type: the 500 most recent samples, which is a
// demo, not a backup. This replaces it with two engines that share one archive layout:
//
//   BACKFILL (runs once, then never again)
//     Walks month-sized windows backwards from today to the earliest sample. Month windows give us
//     bounded memory (a decade of heart-rate samples will not fit in an array), a natural resume
//     cursor ("next month to fetch"), idempotent retries (re-running a month rewrites one file), and
//     an archive a human can navigate.
//
//   LIVE (runs forever)
//     HKAnchoredObjectQuery per type. The anchor is HealthKit's own resumption token: it returns
//     exactly what changed since last time — including DELETIONS, which a date-range query cannot
//     report at all. We persist the anchor only AFTER the data is durably uploaded; persisting it
//     first would silently drop whatever was in flight when the process died.
//
// Archive layout on the user's own storage:
//     Health/manifest.json          per-type anchor, cursor, counts
//     Health/<Type>/<YYYY-MM>.jsonl one line per sample, append-only within a month
//     Health/<Type>/deleted.jsonl   tombstones, so the archive can reflect deletions
//
// THE reliability trap: HealthKit is inaccessible while the device is LOCKED — the store is
// encrypted at rest, so a background wake on a locked phone throws HKError.errorDatabaseInaccessible.
// That is not a failure, it is "ask again when unlocked". Treating it as an error would burn a
// scheduled run and, worse, tempt you into advancing an anchor past data you never read.

// MARK: - persisted state

struct TypeState: Codable {
    var anchor: Data?            // archived HKQueryAnchor
    var cursor: String?          // "YYYY-MM" of the next (older) window to fetch; nil = not started
    var earliest: Date?          // oldest sample that exists, discovered once
    var backfillDone = false
    var samples = 0
    var deletions = 0
}

struct ArchiveState: Codable {
    var types: [String: TypeState] = [:]
    var startedAt: Date?
    var lastRun: Date?
    var device: String?          // which iPhone wrote this archive (the Mac's Health tile names it)
}

// MARK: - engine

@MainActor
final class HealthArchive: ObservableObject {
    /// One short human-readable line. Never a modal, never a blocking spinner.
    @Published private(set) var summary = ""
    /// 0…1 across the whole backfill, or nil once there is nothing left to do.
    @Published private(set) var backfillProgress: Double?
    @Published private(set) var busy = false
    /// Health access has been granted and the engines are running (persisted: `startedAt`).
    @Published private(set) var started = false

    static let backfillTaskID = "com.mineracks.micloud.phone.healthbackfill"

    /// One pass at a time, process-wide. Every HKObserverQuery fires once on registration — 55 types, 55
    /// concurrent incremental passes, each appending to the same month files: Nextcloud logged six PUTs
    /// from the phone cut off in the same second ("Expected filesize … but read …"), the files on disk were
    /// truncated, and the card said "error 1". A pass that finds another running asks for one more pass
    /// afterwards and returns; the backfill simply waits for its next slot.
    private static var passRunning = false
    private static var passRequested = false

    private let store = HKHealthStore()
    /// Set after pairing (the app signs in after launch); every run re-checks it.
    var dav: NextcloudWebDAV?
    private var state = ArchiveState()
    private var observers: [HKObserverQuery] = []

    /// The types we archive: the full detailed picture — activity, heart, respiratory, body, mobility, hearing,
    /// sleep and events — plus workouts. Every one is a sample type, so the same two engines carry all of them.
    private let quantityIDs: [HKQuantityTypeIdentifier] = [
        // activity
        .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .swimmingStrokeCount, .flightsClimbed,
        .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime, .appleStandTime, .appleMoveTime, .physicalEffort,
        // heart + respiratory
        .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute,
        .respiratoryRate, .oxygenSaturation, .vo2Max, .bloodPressureSystolic, .bloodPressureDiastolic,
        // body
        .bodyMass, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass, .height, .waistCircumference, .bodyTemperature,
        .appleSleepingWristTemperature, .bloodGlucose, .dietaryWater,
        // mobility
        .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
        .sixMinuteWalkTestDistance, .stairAscentSpeed, .stairDescentSpeed, .appleWalkingSteadiness, .runningSpeed, .runningPower,
        // hearing + environment
        .environmentalAudioExposure, .headphoneAudioExposure, .timeInDaylight,
    ]
    private let categoryIDs: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis, .mindfulSession, .appleStandHour,
        .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent, .lowCardioFitnessEvent,
        .appleWalkingSteadinessEvent, .environmentalAudioExposureEvent, .headphoneAudioExposureEvent,
    ]

    init(dav: NextcloudWebDAV?) {
        self.dav = dav
        state = (try? Self.loadState()) ?? ArchiveState()
        started = state.startedAt != nil
        if started { summary = summaryLine(); recomputeProgress() }
    }

    // MARK: types

    private var sampleTypes: [HKSampleType] {
        var out: [HKSampleType] = quantityIDs.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
        out += categoryIDs.compactMap { HKCategoryType.categoryType(forIdentifier: $0) }
        out.append(HKObjectType.workoutType())
        return out
    }

    private func unit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .stepCount, .flightsClimbed, .swimmingStrokeCount, .bodyMassIndex: return .count()
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate, .heartRateRecoveryOneMinute:
                                                     return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN:              return .secondUnit(with: .milli)
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .bodyMass, .leanBodyMass:               return .gramUnit(with: .kilo)
        case .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .sixMinuteWalkTestDistance, .walkingStepLength, .height, .waistCircumference:
                                                     return .meter()
        case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage, .appleWalkingSteadiness:
                                                     return .percent()
        case .appleExerciseTime, .appleStandTime, .appleMoveTime, .timeInDaylight: return .minute()
        case .vo2Max:                                return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .bloodPressureSystolic, .bloodPressureDiastolic: return .millimeterOfMercury()
        case .bodyTemperature, .appleSleepingWristTemperature: return .degreeCelsius()
        case .bloodGlucose:                          return HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
        case .dietaryWater:                          return .liter()
        case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed, .runningSpeed: return HKUnit.meter().unitDivided(by: .second())
        case .runningPower:                          return .watt()
        case .physicalEffort:                        return HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        case .environmentalAudioExposure, .headphoneAudioExposure: return .decibelAWeightedSoundPressureLevel()
        default:                                     return .count()
        }
    }

    private func unit(for type: HKSampleType) -> HKUnit {
        guard let q = type as? HKQuantityType else { return .count() }
        return unit(for: HKQuantityTypeIdentifier(rawValue: q.identifier))
    }

    private func shortName(_ type: HKSampleType) -> String {
        type.identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "Workouts")
    }

    // MARK: public entry points

    /// Ask once, then start both engines. Safe to call on every launch.
    func begin() async {
        guard HKHealthStore.isHealthDataAvailable() else { summary = L("health.unavailable"); return }
        guard dav != nil else { summary = L("err.notpaired"); return }
        do {
            let types = Set(sampleTypes)
            try await store.requestAuthorization(toShare: [], read: types)
        } catch {
            summary = L("health.failed", error.localizedDescription); return
        }
        // The server manifest is the durable copy of the anchors, cursors and counts. A phone whose local
        // state is empty or behind it (fresh install, lost Application Support — the Mac's Health tile fell
        // from 15,051 to 867 "records" on 2026-10-19) must not restart the archive from zero: adopt every type
        // the server knows and this phone does not, before anything is written.
        if let dav, let data = try? await dav.fetch("Health/manifest.json"),
           let remote = try? JSONDecoder.archive().decode(ArchiveState.self, from: data) {
            var adopted = 0
            for (key, st) in remote.types where state.types[key] == nil { state.types[key] = st; adopted += 1 }
            if state.startedAt == nil { state.startedAt = remote.startedAt }
            if adopted > 0 { summary = L("health.restored", adopted) }
        }
        if state.startedAt == nil { state.startedAt = Date() }
        state.device = UIDevice.current.name; try? saveState()
        started = true
        try? await uploadManifest(dav: dav!)      // the Mac's Health tile turns "on" from this, before any data
        await runIncremental()
        startObservers()
        scheduleBackfill()
        // Opportunistic: while the user is looking at the app anyway, walk history — a bounded slice, every
        // completed month durable, so being backgrounded costs at most one window. The bar shows it moving.
        await runBackfill(budget: 240)
    }

    /// New/changed/deleted samples since the last anchor, for every type.
    func runIncremental() async {
        guard let dav else { return }
        if Self.passRunning { Self.passRequested = true; return }
        Self.passRunning = true
        defer {
            Self.passRunning = false
            if Self.passRequested { Self.passRequested = false; Task { @MainActor in await self.runIncremental() } }
        }
        busy = true; defer { busy = false }
        for type in sampleTypes {
            summary = L("health.checking", shortName(type))
            do {
                try await syncAnchored(type, dav: dav)
                try? await uploadManifest(dav: dav)
            } catch let e as HKError where e.code == .errorDatabaseInaccessible {
                summary = L("health.locked")            // phone was locked; retry later, anchor untouched
                return
            } catch {
                summary = L("health.failed", error.localizedDescription)
                return                                   // leave the anchor alone so nothing is skipped
            }
        }
        state.lastRun = Date(); try? saveState()
        summary = summaryLine()
        try? await uploadManifest(dav: dav)     // cheap, and what the Mac's Health tile reads for counts
    }

    /// Do as much historical backfill as fits in `budget` seconds, then stop cleanly.
    /// Every completed window is durable, so being cut off costs at most one window.
    func runBackfill(budget: TimeInterval) async {
        guard let dav else { return }
        if Self.passRunning { return }                 // the scheduler (or the next foreground visit) brings us back
        Self.passRunning = true; defer { Self.passRunning = false }
        let deadline = Date().addingTimeInterval(budget)
        busy = true; defer { busy = false }

        for type in sampleTypes {
            let key = shortName(type)
            var st = state.types[key] ?? TypeState()
            if st.backfillDone { continue }

            if st.earliest == nil {
                st.earliest = (try? await earliestSample(type)) ?? Date()
                state.types[key] = st; try? saveState()
            }
            guard let earliest = st.earliest else { continue }

            var cursor = st.cursor.flatMap(Self.month(from:)) ?? Self.monthStart(Date())
            while cursor >= Self.monthStart(earliest) {
                if Date() >= deadline { state.types[key] = st; try? saveState(); return }
                let end = Self.nextMonth(cursor)
                do {
                    let n = try await archiveWindow(type, from: cursor, to: end, dav: dav)
                    st.samples += n
                } catch let e as HKError where e.code == .errorDatabaseInaccessible {
                    state.types[key] = st; try? saveState(); summary = L("health.locked"); return
                } catch {
                    // Network or store hiccup: stop here. The cursor still points at this window, so
                    // the next run repeats it — writes are idempotent, so a repeat is harmless.
                    state.types[key] = st; try? saveState()
                    summary = L("health.failed", error.localizedDescription); return
                }
                cursor = Self.prevMonth(cursor)
                st.cursor = Self.monthKey(cursor)
                state.types[key] = st; try? saveState()
                recomputeProgress()
                summary = summaryLine()
                try? await uploadManifest(dav: dav)
            }
            st.backfillDone = true; st.cursor = nil
            state.types[key] = st; try? saveState()
        }
        backfillProgress = nil
        summary = summaryLine()
        try? await uploadManifest(dav: dav)
    }

    // MARK: HealthKit plumbing

    private func earliestSample(_ type: HKSampleType) async throws -> Date {
        try await withCheckedThrowingContinuation { cont in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: sort) { _, samples, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: samples?.first?.startDate ?? Date()) }
            }
            store.execute(q)
        }
    }

    /// One month of one type → one .jsonl file. Returns how many samples were written.
    private func archiveWindow(_ type: HKSampleType, from: Date, to: Date,
                               dav: NextcloudWebDAV) async throws -> Int {
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let q = HKSampleQuery(sampleType: type, predicate: pred,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, s, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: s ?? []) }
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return 0 }

        let rel = "Health/\(shortName(type))/\(Self.monthKey(from)).jsonl"
        try await putJSONL(samples.map { encode($0, unit: unit(for: type)) }, to: rel, dav: dav)
        return samples.count
    }

    /// Incremental sync for one type. Anchor is persisted ONLY after a successful upload.
    private func syncAnchored(_ type: HKSampleType, dav: NextcloudWebDAV) async throws {
        let key = shortName(type)
        var st = state.types[key] ?? TypeState()
        let anchor = st.anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }

        // No anchor yet = first run. Without a predicate that query returns every sample of the type ever
        // recorded, in one array: ten years of step counts came back as 104 month files in one go, and ten
        // years of heart rate would not fit in memory. Bound the first pull to the last week (Watch sync lag);
        // the month-by-month backfill owns everything older and writes the same files, deduplicated.
        let since = anchor == nil ? state.startedAt.map { $0.addingTimeInterval(-7 * 86400) } : nil
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
        let (new, deleted, next): ([HKSample], [HKDeletedObject], HKQueryAnchor?) =
            try await withCheckedThrowingContinuation { cont in
                let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                              limit: HKObjectQueryNoLimit) { _, s, d, a, err in
                    if let err { cont.resume(throwing: err) }
                    else { cont.resume(returning: (s ?? [], d ?? [], a)) }
                }
                store.execute(q)
            }

        if !new.isEmpty {
            // Group by month so live data lands in the same files backfill uses.
            let byMonth = Dictionary(grouping: new) { Self.monthKey(Self.monthStart($0.startDate)) }
            for (month, group) in byMonth {
                let rel = "Health/\(key)/\(month).jsonl"
                try await appendJSONL(group.map { encode($0, unit: unit(for: type)) }, to: rel, dav: dav)
            }
            st.samples += new.count
        }
        if !deleted.isEmpty {
            let now = Self.iso(Date())
            let rows = deleted.map { ["uuid": $0.uuid.uuidString, "observed": now] }
            try await appendJSONL(rows, to: "Health/\(key)/deleted.jsonl", dav: dav)
            st.deletions += deleted.count
        }

        // Only now is it safe to move the anchor forward.
        if let next {
            st.anchor = try? NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
        }
        state.types[key] = st
        try? saveState()
    }

    private func encode(_ s: HKSample, unit: HKUnit) -> [String: Any] {
        var row: [String: Any] = [
            "uuid": s.uuid.uuidString,
            "start": Self.iso(s.startDate),
            "end": Self.iso(s.endDate),
            "source": s.sourceRevision.source.name,
        ]
        if let q = s as? HKQuantitySample {
            row["value"] = q.quantity.doubleValue(for: unit)
            row["unit"] = unit.unitString
        } else if let c = s as? HKCategorySample {
            row["value"] = c.value
            if c.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
               let v = HKCategoryValueSleepAnalysis(rawValue: c.value) {
                row["label"] = Self.sleepLabel(v)
            }
        } else if let w = s as? HKWorkout {
            row["activity"] = w.workoutActivityType.rawValue
            row["activityName"] = Self.workoutName(w.workoutActivityType)
            row["duration"] = w.duration
            if let d = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity() ?? w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity() {
                row["distance"] = d.doubleValue(for: .meter())
            }
            if let e = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { row["energy"] = e.doubleValue(for: .kilocalorie()) }
        }
        if let dev = s.device?.name { row["device"] = dev }
        if let md = s.metadata, !md.isEmpty {
            // Only JSON-safe scalars; HealthKit metadata can carry quantities and dates too.
            var m: [String: Any] = [:]
            for (k, v) in md {
                switch v {
                case let x as String: m[k] = x
                case let x as NSNumber: m[k] = x
                case let x as Date: m[k] = Self.iso(x)
                case let x as HKQuantity: m[k] = "\(x)"
                default: break
                }
            }
            if !m.isEmpty { row["metadata"] = m }
        }
        return row
    }

    private static func sleepLabel(_ v: HKCategoryValueSleepAnalysis) -> String {
        switch v {
        case .inBed: return "inBed"; case .asleepUnspecified: return "asleep"; case .awake: return "awake"
        case .asleepCore: return "core"; case .asleepDeep: return "deep"; case .asleepREM: return "rem"
        @unknown default: return "unknown"
        }
    }
    private static func workoutName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "running"; case .walking: return "walking"; case .cycling: return "cycling"
        case .swimming: return "swimming"; case .hiking: return "hiking"; case .yoga: return "yoga"
        case .functionalStrengthTraining: return "strength"; case .traditionalStrengthTraining: return "strength"
        case .highIntensityIntervalTraining: return "hiit"; case .rowing: return "rowing"; case .elliptical: return "elliptical"
        case .coreTraining: return "core"; case .mixedCardio: return "mixedCardio"; case .other: return "other"
        default: return "activity\(t.rawValue)"
        }
    }

    // MARK: upload helpers

    private func putJSONL(_ rows: [[String: Any]], to rel: String, dav: NextcloudWebDAV) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var out = Data()
        for r in rows {
            out.append(try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]))
            out.append(0x0A)
        }
        try out.write(to: tmp)
        try await dav.ensureParents(of: rel)
        try await dav.upload(localFile: tmp, to: rel)
    }

    /// Append = fetch-existing + rewrite. WebDAV has no append; at month granularity the files stay
    /// small enough that this is honest and simple, and it keeps every write idempotent.
    private func appendJSONL(_ rows: [[String: Any]], to rel: String, dav: NextcloudWebDAV) async throws {
        var existing = Data()
        if let prior = try? await dav.fetch(rel) { existing = prior }
        // Rows already in the file (a repeated window, a sample in both the first incremental pull and the
        // backfill's month) are not appended again — that is what makes every write idempotent.
        var seen = Set<String>()
        if !existing.isEmpty, let text = String(data: existing, encoding: .utf8) {
            // A PUT that was cut off mid-way (the app killed, the network gone) leaves the file ending in a
            // partial row. Drop it: it is not a record, and its uuid must not count as "already there".
            if let last = text.split(separator: "\n", omittingEmptySubsequences: false).last,
               !last.isEmpty, !last.hasSuffix("}") {
                let keep = text.dropLast(last.count)
                existing = Data(keep.utf8)
            }
            for line in String(decoding: existing, as: UTF8.self).split(separator: "\n") {
                guard line.hasSuffix("}") else { continue }
                if let a = line.range(of: "\"uuid\":\""), let b = line[a.upperBound...].firstIndex(of: "\"") {
                    seen.insert(String(line[a.upperBound..<b]))
                }
            }
        }
        let fresh = rows.filter { r in (r["uuid"] as? String).map { !seen.contains($0) } ?? true }
        if fresh.isEmpty && !existing.isEmpty { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var out = existing
        if !out.isEmpty && out.last != 0x0A { out.append(0x0A) }
        for r in fresh {
            out.append(try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]))
            out.append(0x0A)
        }
        try out.write(to: tmp)
        try await dav.ensureParents(of: rel)
        try await dav.upload(localFile: tmp, to: rel)
    }

    private func uploadManifest(dav: NextcloudWebDAV) async throws {
        let data = try JSONEncoder().encoded(state)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        try await dav.ensureParents(of: "Health/manifest.json")
        try await dav.upload(localFile: tmp, to: "Health/manifest.json")
    }

    // MARK: background

    /// Wake on new Health data even when the app isn't running. Needs the
    /// com.apple.developer.healthkit.background-delivery entitlement (the ad-hoc profile grants it).
    private func startObservers() {
        guard observers.isEmpty else { return }
        for type in sampleTypes {
            let q = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in
                    await self?.runIncremental()
                    completion()               // must always be called or iOS throttles future wakes
                }
            }
            store.execute(q)
            observers.append(q)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// The heavy historical walk runs on the charger, on wifi, while the phone is idle — the user
    /// should never watch a progress bar for this.
    func scheduleBackfill() {
        #if canImport(BackgroundTasks)
        guard state.types.values.contains(where: { !$0.backfillDone }) || state.types.isEmpty else { return }
        let req = BGProcessingTaskRequest(identifier: Self.backfillTaskID)
        req.requiresExternalPower = true
        req.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(req)
        #endif
    }

    // MARK: state persistence

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("health-archive.json")
    }
    private static func loadState() throws -> ArchiveState {
        let d = try Data(contentsOf: stateURL)
        // Must match `encoded` (ISO 8601 dates). With the default decoder every load threw once `startedAt`
        // was set, so every cold launch began the archive from zero — the Mac's Health tile fell 15,051 → 867
        // → 0 across two TestFlight installs on 2026-10-19 before this was found.
        return try JSONDecoder.archive().decode(ArchiveState.self, from: d)
    }
    private func saveState() throws {
        try JSONEncoder().encoded(state).write(to: Self.stateURL, options: .atomic)
    }

    /// Fraction of the whole historical walk that is done, across every type.
    /// Months are the unit because they're what the cursor moves in — so the bar advances at the
    /// same granularity as the work actually durably completes.
    private func recomputeProgress() {
        var total = 0, done = 0
        let now = Self.monthStart(Date())
        for st in state.types.values {
            guard let earliest = st.earliest else { continue }
            let span = max(1, Self.months(from: Self.monthStart(earliest), to: now) + 1)
            total += span
            if st.backfillDone { done += span }
            else if let c = st.cursor.flatMap(Self.month(from:)) {
                done += max(0, Self.months(from: c, to: now))
            }
        }
        backfillProgress = (total == 0 || done >= total) ? nil : Double(done) / Double(total)
    }

    private func summaryLine() -> String {
        let total = state.types.values.reduce(0) { $0 + $1.samples }
        let pending = state.types.values.filter { !$0.backfillDone }.count
        if pending > 0, let oldest = state.types.values.compactMap({ $0.cursor }).min() {
            return L("health.backfilling", "\(total)", oldest)
        }
        return L("health.archived", "\(total)")
    }

    // MARK: date helpers (UTC month windows — stable across travel and DST)

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    static func monthStart(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }
    static func nextMonth(_ d: Date) -> Date { cal.date(byAdding: .month, value: 1, to: d) ?? d }
    static func prevMonth(_ d: Date) -> Date { cal.date(byAdding: .month, value: -1, to: d) ?? d }
    static func monthKey(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    static func months(from: Date, to: Date) -> Int {
        cal.dateComponents([.month], from: from, to: to).month ?? 0
    }
    static func month(from key: String) -> Date? {
        let p = key.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m
        return cal.date(from: c)
    }
    private static let isoFmt: ISO8601DateFormatter = { ISO8601DateFormatter() }()
    static func iso(_ d: Date) -> String { isoFmt.string(from: d) }
}

private extension JSONEncoder {
    func encoded<T: Encodable>(_ v: T) throws -> Data {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        dateEncodingStrategy = .iso8601
        return try encode(v)
    }
}
private extension JSONDecoder {
    /// The counterpart of `encoded`: the archive state and manifest carry ISO 8601 dates.
    static func archive() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
