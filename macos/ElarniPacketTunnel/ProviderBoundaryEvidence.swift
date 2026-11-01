import Foundation
import OSLog
import Security

enum ProviderBoundaryEvidence {
    private static let logger = Logger(subsystem: "com.elarni.mac.packet-tunnel.boundary", category: "provider")
    private static let gate = ProviderBoundaryGate(emitter: { marker in
        emit(marker)
    })

    static func reset() -> ProviderBoundaryAttempt {
        gate.reset()
    }

    static func begin(
        _ stage: ProviderBoundaryStage,
        attempt: ProviderBoundaryAttempt
    ) {
        gate.emit(
            ProviderBoundaryMarker(
                stage: stage,
                event: .begin,
                code: .none,
                statusClass: .none,
                status: 0
            ),
            attempt: attempt
        )
    }

    static func success(
        _ stage: ProviderBoundaryStage,
        attempt: ProviderBoundaryAttempt
    ) {
        gate.emit(
            ProviderBoundaryMarker(
                stage: stage,
                event: .success,
                code: .none,
                statusClass: .none,
                status: 0
            ),
            attempt: attempt
        )
    }

    static func failure(
        _ stage: ProviderBoundaryStage,
        code: ProviderBoundaryCode,
        statusClass: ProviderKeychainStatusClass = .none,
        status: Int32 = 0,
        reason: ProviderBoundaryReason = .none,
        path: ProviderBoundaryPath = .none,
        attempt: ProviderBoundaryAttempt
    ) {
        gate.emit(
            ProviderBoundaryMarker(
                stage: stage,
                event: .failure,
                code: code,
                statusClass: statusClass,
                status: status,
                reason: reason,
                path: path
            ),
            attempt: attempt
        )
    }

    static func finalFailure(attempt: ProviderBoundaryAttempt) {
        gate.finalFailure(attempt: attempt)
    }

    static func finish(_ attempt: ProviderBoundaryAttempt) {
        gate.finish(attempt)
    }

    static func keychainStatusClass(for status: Int32) -> ProviderKeychainStatusClass {
        if status == Int32(errSecSuccess) {
            return .none
        }
        if status == Int32(errSecItemNotFound) {
            return .itemNotFound
        }
        if status == Int32(errSecAuthFailed) {
            return .authFailed
        }
        if status == Int32(errSecUserCanceled) {
            return .userCanceled
        }
        if status == Int32(errSecInteractionNotAllowed) {
            return .interactionNotAllowed
        }
        if status == Int32(errSecMissingEntitlement) {
            return .missingEntitlement
        }
        return .other
    }

    private static func emit(_ marker: ProviderBoundaryMarker) {
        DiagnosticLog.record("provider_boundary", ["generation": Int64(marker.generation), "stage": Int64(marker.stage.rawValue), "event": Int64(marker.event.rawValue), "code": Int64(marker.code.rawValue), "status": Int64(marker.status)])
        logger.notice(
      "RVBOUNDARY v=2 generation=\(marker.generation, privacy: .public) monotonicNs=\(marker.monotonicNanoseconds, privacy: .public) stage=\(marker.stage.rawValue, privacy: .public) event=\(marker.event.rawValue, privacy: .public) code=\(marker.code.rawValue, privacy: .public) statusClass=\(marker.statusClass.rawValue, privacy: .public) status=\(marker.status, privacy: .public) reason=\(marker.reason.rawValue, privacy: .public) path=\(marker.path.rawValue, privacy: .public)"
        )
    }
}
