import Foundation

enum ProviderBoundaryStage: Int32, Sendable {
    case keychainLookup = 1
    case domainCompile = 2
    case endpointResolver = 3
    case libXrayRun = 4
    case libXrayState = 5
    case packetBridge = 6
    case tunnelSettings = 7
    case packetPump = 8
    case providerLifecycle = 9
}

enum ProviderBoundaryEvent: Int32, Sendable {
    case begin = 1
    case success = 2
    case failure = 3
    case finalFailure = 4
}

enum ProviderBoundaryCode: Int32, Sendable {
    case none = 0
    case keychainLookupFailed = 1001
    case keychainInvalidSecret = 1002
    case keychainAccessGroupMissing = 1003
    case domainAbiMismatch = 2001
    case domainCompileFailed = 2002
    case domainResponseInvalid = 2003
    case endpointResolutionFailed = 3001
  case libXrayRunFailed = 4001
  case libXrayRunRejected = 4002
    case libXrayStateFailed = 5001
    case libXrayNotRunning = 5002
    case packetBridgeAbiMismatch = 6001
    case packetBridgeCreateFailed = 6002
    case packetBridgeAlreadyRunning = 6003
    case tunnelSettingsApplyFailed = 7001
  case packetPumpRuntimeFailed = 8002
  case providerUnhandledFailure = 9001
  case providerStopDeadlineExceeded = 9002
  case providerBridgeStopFailed = 9004
  case providerXrayStopFailed = 9005
  case providerClearSettingsInvalid = 9006
  case providerClearSettingsCanceled = 9007
  case providerClearSettingsRequestFailed = 9008
  case providerClearSettingsOther = 9009
}

enum ProviderKeychainStatusClass: Int32, Sendable {
    case none = 0
    case itemNotFound = 1
    case authFailed = 2
    case userCanceled = 3
    case interactionNotAllowed = 4
    case missingEntitlement = 5
    case other = 255
}

enum ProviderBoundaryReason: String, Sendable {
  case none
  case xrayBridgeFailed = "xray_bridge_failed"
  case xrayRealityClientShape = "xray_reality_client_shape"
  case xrayRealityLegacyServerNames = "xray_reality_legacy_server_names"
  case xrayValidationFailed = "xray_validation_failed"
  case xrayInitializationFailed = "xray_initialization_failed"
  case xrayStartFailed = "xray_start_failed"
  case xrayAddressInUse = "xray_address_in_use"
  case xrayPermissionDenied = "xray_permission_denied"
  case xrayFileMissing = "xray_file_missing"

  static func xrayDiagnostic(_ message: String) -> (Self, ProviderBoundaryPath) {
    let message = message.lowercased()
    if message.contains("non-empty \"servernames\"") { return (.xrayRealityLegacyServerNames, .realityServerNames) }
    if message.contains("empty \"servernames\"") { return (.xrayRealityClientShape, .realitySettings) }
    if message.contains("address already in use") { return (.xrayAddressInUse, .root) }
    if message.contains("permission denied") || message.contains("operation not permitted") { return (.xrayPermissionDenied, .root) }
    if message.contains("no such file or directory") { return (.xrayFileMissing, .root) }
    if message.hasPrefix("xray_config_invalid:") { return (.xrayValidationFailed, .root) }
    if message.hasPrefix("xray_initialization_failed:") { return (.xrayInitializationFailed, .root) }
    return (.xrayStartFailed, .root)
  }
}

enum ProviderBoundaryPath: String, Sendable {
  case none = "-"
  case root = "$"
  case realitySettings = "$.outbounds[*].streamSettings.realitySettings"
  case realityServerNames = "$.outbounds[*].streamSettings.realitySettings.serverNames"
}

struct ProviderBoundaryAttempt: Equatable, Sendable {
    fileprivate let generation: UInt64
}

struct ProviderBoundaryMarker: Equatable, Sendable {
  let stage: ProviderBoundaryStage
  let event: ProviderBoundaryEvent
  let code: ProviderBoundaryCode
  let statusClass: ProviderKeychainStatusClass
  let status: Int32
  let reason: ProviderBoundaryReason
  let path: ProviderBoundaryPath
  let generation: UInt64
  let monotonicNanoseconds: UInt64

  init(
    stage: ProviderBoundaryStage,
    event: ProviderBoundaryEvent,
    code: ProviderBoundaryCode,
    statusClass: ProviderKeychainStatusClass,
    status: Int32,
    reason: ProviderBoundaryReason = .none,
    path: ProviderBoundaryPath = .none,
    generation: UInt64 = 0,
    monotonicNanoseconds: UInt64 = 0
  ) {
    self.stage = stage
    self.event = event
    self.code = code
    self.statusClass = statusClass
    self.status = status
    self.reason = reason
    self.path = path
    self.generation = generation
    self.monotonicNanoseconds = monotonicNanoseconds
  }

  func stamped(generation: UInt64) -> ProviderBoundaryMarker {
    ProviderBoundaryMarker(
      stage: stage,
      event: event,
      code: code,
      statusClass: statusClass,
      status: status,
      reason: reason,
      path: path,
      generation: generation,
      monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
    )
  }

  static func == (lhs: ProviderBoundaryMarker, rhs: ProviderBoundaryMarker) -> Bool {
    lhs.stage == rhs.stage
      && lhs.event == rhs.event
      && lhs.code == rhs.code
      && lhs.statusClass == rhs.statusClass
      && lhs.status == rhs.status
      && lhs.reason == rhs.reason
      && lhs.path == rhs.path
  }
}

final class ProviderBoundaryGate: @unchecked Sendable {
    typealias Emitter = @Sendable (ProviderBoundaryMarker) -> Void

    private let lock = NSLock()
    private let emitter: Emitter
    private var generation: UInt64 = 0
    private var active = false
    private var firstFailure: ProviderBoundaryMarker?
    private var finalized = false

    init(emitter: @escaping Emitter) {
        self.emitter = emitter
    }

    func reset() -> ProviderBoundaryAttempt {
        lock.lock()
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
        active = true
        firstFailure = nil
        finalized = false
        let attempt = ProviderBoundaryAttempt(generation: generation)
        lock.unlock()
        return attempt
    }

    @discardableResult
    func emit(
        _ marker: ProviderBoundaryMarker,
        attempt: ProviderBoundaryAttempt
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, attempt.generation == generation, !finalized else {
            return false
        }

        switch marker.event {
        case .begin, .success:
            guard firstFailure == nil else { return false }
        case .failure:
            guard firstFailure == nil else { return false }
            firstFailure = marker
        case .finalFailure:
            return false
        }

    emitter(marker.stamped(generation: generation))
        return true
    }

    @discardableResult
    func finalFailure(attempt: ProviderBoundaryAttempt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, attempt.generation == generation, !finalized else {
            return false
        }

        let failure = firstFailure ?? ProviderBoundaryMarker(
            stage: .providerLifecycle,
            event: .failure,
            code: .providerUnhandledFailure,
            statusClass: .none,
            status: 0
        )
        finalized = true
    emitter(
      ProviderBoundaryMarker(
        stage: failure.stage,
        event: .finalFailure,
        code: failure.code,
        statusClass: failure.statusClass,
        status: failure.status,
        reason: failure.reason,
        path: failure.path
      ).stamped(generation: generation)
    )
        return true
    }

    func finish(_ attempt: ProviderBoundaryAttempt) {
        lock.lock()
        if active, attempt.generation == generation {
            active = false
            firstFailure = nil
            finalized = false
        }
        lock.unlock()
    }
}
