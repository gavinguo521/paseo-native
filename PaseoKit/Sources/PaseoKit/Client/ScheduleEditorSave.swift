import Observation

/// Schedule and notification preferences live in separate services. Retain the
/// created ID across partial failures so the same editor can safely retry.
@MainActor @Observable
public final class ScheduleEditorSave {
    public private(set) var createdID: String?

    public enum Failure: Error { case notification(any Error) }

    public init() {}

    public func save(existingID: String?,
                     create: @MainActor () async throws -> String,
                     update: @MainActor (String) async throws -> Void,
                     saveNotification: (@MainActor (String) async throws -> Void)?) async throws {
        let id: String
        if let existing = existingID ?? createdID {
            try await update(existing)
            id = existing
        } else {
            id = try await create()
            createdID = id
        }
        do { try await saveNotification?(id) }
        catch { throw Failure.notification(error) }
    }
}
