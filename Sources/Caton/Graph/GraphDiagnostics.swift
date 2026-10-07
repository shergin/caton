import Baton
import OSLog

/// Baton's events contain operation names and counts, never credentials,
/// query variables, or response bodies.
enum GraphDiagnostics {
    private static let logger = Logger(subsystem: "dev.caton.Caton", category: "GraphQL")

    static func record(_ event: LogEvent) {
        switch event {
        case .fetchFailed, .fieldError, .imageUnavailable, .imageWriteFailed,
             .missing, .unexpected, .ambiguousIdentity, .requiredFieldMissing, .partDropped:
            logger.error("\(String(describing: event))")
        default:
            logger.debug("\(String(describing: event))")
        }
    }
}
