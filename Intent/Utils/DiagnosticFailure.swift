import Security

/// Classification accepts only closed values. Boundary helpers discard unknown
/// numeric codes; they never accept Error/NSError or inspect foreign text.
nonisolated struct DiagnosticFailure: Codable, Equatable, Sendable {
    enum Origin: String, Codable, CaseIterable, Sendable {
        case localOperation = "local_operation"
        case localRequest = "local_request"
        case none, persistence, probe
        case remoteRPC = "remote_rpc"
        case transport, unknown, upload
    }

    enum Classification: String, Codable, CaseIterable, Sendable {
        case activeFailed = "active_failed"
        case cleanupFailed = "cleanup_failed"
        case connectionClosed = "connection_closed"
        case contractUnavailable = "contract_unavailable"
        case decodeCorrupt = "decode_corrupt"
        case decodeKeyMissing = "decode_key_missing"
        case decodeTypeMismatch = "decode_type_mismatch"
        case decodeValueMissing = "decode_value_missing"
        case deleteFailed = "delete_failed"
        case encodingFailed = "encoding_failed"
        case httpFailure = "http_failure"
        case invalidInput = "invalid_input"
        case malformedResponse = "malformed_response"
        case missingPin = "missing_pin"
        case noCertificate = "no_certificate"
        case none
        case notConnected = "not_connected"
        case notImage = "not_image"
        case permissionDenied = "permission_denied"
        case pinMismatch = "pin_mismatch"
        case readFailed = "read_failed"
        case remoteRejected = "remote_rejected"
        case requestTimeout = "request_timeout"
        case restricted
        case startFailed = "start_failed"
        case tooLarge = "too_large"
        case transportUnknown = "transport_unknown"
        case unavailable, unknown, unreadable
        case unsupportedVersion = "unsupported_version"
        case writeFailed = "write_failed"
    }

    enum Code: String, Codable, CaseIterable, Sendable {
        case authentication, cancelled, decode, duplicate
        case interactionNotAllowed = "interaction_not_allowed"
        case internalError = "internal_error"
        case invalidParameters = "invalid_parameters"
        case invalidRequest = "invalid_request"
        case methodNotFound = "method_not_found"
        case none, other
        case parseError = "parse_error"
        case permission
    }

    let origin: Origin
    let classification: Classification
    let code: Code

    static let none = Self(origin: .none, classification: .none)

    private static let rpcParseError = -32_700
    private static let rpcInvalidRequest = -32_600
    private static let rpcMethodNotFound = -32_601
    private static let rpcInvalidParameters = -32_602
    private static let rpcInternalError = -32_603

    init(origin: Origin, classification: Classification, code: Code = .none) {
        self.origin = origin
        self.classification = classification
        self.code = code
    }

    /// Call only at the remote response boundary, not on the flattened
    /// WebSocket NSError domain shared by local and remote errors.
    static func remoteRPC(code: Int) -> Self {
        let safeCode: Code = switch code {
        case rpcParseError: .parseError
        case rpcInvalidRequest: .invalidRequest
        case rpcMethodNotFound: .methodNotFound
        case rpcInvalidParameters: .invalidParameters
        case rpcInternalError: .internalError
        default: .other
        }
        return Self(origin: .remoteRPC, classification: .remoteRejected, code: safeCode)
    }

    /// The operation owner decides whether item-not-found is a failure at all.
    /// Unknown status integers are deliberately not retained.
    static func securityStatus(_ status: Int32, classification: Classification) -> Self {
        let safeCode: Code = switch status {
        case errSecAuthFailed: .authentication
        case errSecDecode: .decode
        case errSecDuplicateItem: .duplicate
        case errSecInteractionNotAllowed: .interactionNotAllowed
        case errSecUserCanceled: .cancelled
        default: .other
        }
        return Self(origin: .persistence, classification: classification, code: safeCode)
    }
}
