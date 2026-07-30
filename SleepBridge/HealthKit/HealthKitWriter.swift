import HealthKit

enum HealthKitWriterError: Error {
    case notAvailable
}

final class HealthKitWriter {
    private let store = HKHealthStore()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitWriterError.notAvailable
        }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitWriterError.notAvailable
        }
        try await store.requestAuthorization(toShare: [sleepType], read: [sleepType])
    }

    func writeSample(start: Date, end: Date, value: HKCategoryValueSleepAnalysis) async throws {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitWriterError.notAvailable
        }
        let sample = HKCategorySample(type: sleepType, value: value.rawValue, start: start, end: end)
        try await store.save(sample)
    }

    /// Writes one "In Bed" sample spanning a whole session, derived from the session's
    /// own start/end — Google Fit doesn't track "in bed" as its own concept.
    func writeInBedSpan(start: Date, end: Date) async throws {
        try await writeSample(start: start, end: end, value: .inBed)
    }

    /// Reads existing sleep-analysis samples overlapping the given range.
    /// Used to check for duplicates before writing, and to find/remove test data.
    func existingSamples(from start: Date, to end: Date) async throws -> [HKCategorySample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitWriterError.notAvailable
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

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

    /// Deletes the given samples. Used for removing manually-written test data.
    func delete(_ samples: [HKCategorySample]) async throws {
        try await store.delete(samples)
    }
}
