import HealthKit

/// Errors the small HealthKit wrapper can report before a query or write begins.
enum HealthKitWriterError: Error {
  case notAvailable
}

/// Centralizes HealthKit permission requests, reads, writes, and deletion for
/// sleep-analysis samples. Keeping the framework calls here lets the pipeline
/// remain focused on transforming data.
final class HealthKitWriter {
  private let store = HKHealthStore()

  /// Namespace-prefixed to avoid clashing with any of HealthKit's own metadata keys.
  /// Attached only to each session's `.inBed` envelope sample (see
  /// SleepPipeline.save) — never to every stage sample — since the envelope
  /// is a reliable one-per-session anchor and tagging every stage sample would
  /// multiply metadata writes (and therefore iCloud sync cost) for no benefit.
  static let pipelineVersionMetadataKey = "com.sleepbridge.version"

  func requestAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw HealthKitWriterError.notAvailable
    }
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      throw HealthKitWriterError.notAvailable
    }
    // Requesting both access modes supports duplicate detection and writing new samples.
    try await store.requestAuthorization(toShare: [sleepType], read: [sleepType])
  }

  /// Saves a single HealthKit category sample for one sleep interval.
  /// `metadata` is optional — SleepPipeline.save only passes it for the
  /// `.inBed` envelope sample, not per-stage samples.
  func writeSample(
    start: Date, end: Date, value: HKCategoryValueSleepAnalysis, metadata: [String: Any]? = nil
  ) async throws {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      throw HealthKitWriterError.notAvailable
    }
    let sample = HKCategorySample(
      type: sleepType, value: value.rawValue, start: start, end: end, metadata: metadata)
    try await store.save(sample)
  }

  /// Writes one "In Bed" sample spanning a whole session, derived from the session's
  /// own start/end — Google Fit doesn't track "in bed" as its own concept.
  func writeInBedSpan(start: Date, end: Date, metadata: [String: Any]? = nil) async throws {
    try await writeSample(start: start, end: end, value: .inBed, metadata: metadata)
  }

  /// Reads existing sleep-analysis samples overlapping the given range.
  /// Used to check for duplicates before writing, and to find/remove test data.
  func existingSamples(from start: Date, to end: Date) async throws -> [HKCategorySample] {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      throw HealthKitWriterError.notAvailable
    }
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

    // HKSampleQuery is callback-based; bridge it to async/await for callers.
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: sleepType,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: nil
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
      }
      store.execute(query)
    }
  }

  /// Reads existing sleep-analysis samples in range that were written by
  /// this app only. Used by reconcile (version-based staleness
  /// checks) and by any manual full-range replace, so deletion never touches
  /// data this app doesn't own.
  func existingSamplesWrittenByThisApp(from start: Date, to end: Date) async throws
    -> [HKCategorySample]
  {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      throw HealthKitWriterError.notAvailable
    }
    let datePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
    let sourcePredicate = HKQuery.predicateForObjects(from: HKSource.default())
    let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      datePredicate, sourcePredicate,
    ])

    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: sleepType,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: nil
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
      }
      store.execute(query)
    }
  }

  /// Deletes the given samples. Used for removing manually-written test data,
  /// and by reconcile/replaceExisting to clear stale SleepBridge-authored samples.
  func delete(_ samples: [HKCategorySample]) async throws {
    try await store.delete(samples)
  }
}
