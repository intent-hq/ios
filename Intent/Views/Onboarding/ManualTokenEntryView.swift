import SwiftUI

/// Classification of the manual-entry "Host / Tailcat Address" input: a
/// direct host/IP dialed as today, or a Tailcat connection blob dialed via
/// TailcatKit. Pinned tailcat v0.4.0 encodes blobs as lowercase `tc` followed
/// by unpadded base64url-encoded CBOR; the tunnel dial remains the authoritative
/// validation of the decoded contents.
enum ManualConnectionInput: Equatable {
    private static let base64BlockSize = 4
    private static let minimumConnectionBlobByteCount = 37
    private static let cborMapPrefixRange: ClosedRange<UInt8> = 0xa1...0xa4
    private static let publicKeyHeaderRange = 1...4
    private static let publicKeyHeader = Array("apX ".utf8)

    case direct(host: String)
    case tailcat(tcAddress: String)

    static func classify(_ raw: String) -> Self {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTailcatConnectionBlob(trimmed) {
            return .tailcat(tcAddress: trimmed)
        }
        return .direct(host: trimmed)
    }

    private static func isTailcatConnectionBlob(_ input: String) -> Bool {
        guard input.hasPrefix("tc") else { return false }
        let encoded = input.dropFirst(2)
        let base64URLCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy(base64URLCharacters.contains)
        else { return false }

        var base64 = String(encoded)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (base64BlockSize - base64.count % base64BlockSize) % base64BlockSize
        base64 += String(repeating: "=", count: paddingCount)
        guard let decoded = Data(base64Encoded: base64),
              decoded.count >= minimumConnectionBlobByteCount else { return false }
        // v0.4.0's wireConnInfo emits a 1–4 entry map whose first, required
        // field is `p`: a 32-byte server public key. Requiring that structure
        // prevents short legal DNS labels such as `tcoA` (an empty CBOR map)
        // from being mistaken for connection blobs.
        return cborMapPrefixRange.contains(decoded[0])
            && decoded[publicKeyHeaderRange].elementsEqual(publicKeyHeader)
    }

    /// Direct hosts to race and persist: empty for a tunnel-only target
    /// (the post-connect route refresh fills in daemon-reported IPs).
    var hosts: [String] {
        switch self {
        case .direct(let host): [host]
        case .tailcat: []
        }
    }

    /// tc address to race the tunnel with; persisted on the paired server so
    /// reconnects race the tunnel route too.
    var tcAddress: String? {
        switch self {
        case .direct: nil
        case .tailcat(let tcAddress): tcAddress
        }
    }
}

struct ManualTokenEntryView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    /// When set, pairing success is reported to the presenting context instead
    /// of the first-run coordinator flow.
    var onPaired: ((StoredConnection) -> Void)?
    @State private var host = ""
    @State private var port = "5180"
    @State private var token = ""
    @State private var isTokenVisible = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var probedFingerprint: String?
    /// The classified target whose fingerprint was probed, captured alongside
    /// `probedFingerprint` so the confirmation alert connects to exactly the
    /// target the user confirmed — never a re-classification of a possibly
    /// edited field.
    @State private var probedInput: ManualConnectionInput?
    @State private var showFingerprintConfirmation = false
    @State private var connectTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field { case host, port, token }

    var body: some View {
        ConnectionSheet(
            initialHeight: Constants.ManualTokenEntry.initialSheetHeight,
            backgroundColor: Constants.Pairing.background(for: colorScheme),
            closeForeground: Constants.Pairing.foreground(for: colorScheme)
        ) {
            entryForm
        }
            .alert("Verify Server Identity", isPresented: $showFingerprintConfirmation) {
                Button("Cancel", role: .cancel) { isValidating = false }
                Button("Trust & Connect") { connectWithFingerprint() }
            } message: {
                Text("The server's TLS certificate fingerprint is:\n\n\(probedFingerprint ?? "")\n\nDo you trust this server?")
            }
    }

    private var entryForm: some View {
        VStack(spacing: Constants.ManualTokenEntry.contentSpacing) {
            ManualConnectionHeader()
            VStack(spacing: Constants.ManualTokenEntry.buttonSpacing) {
                connectionFields
                validationError
                connectButton
            }
        }
    }

    private var connectionFields: some View {
        VStack(spacing: Constants.ManualTokenEntry.formSpacing) {
            hostField
            portField
            tokenField
        }
        .disabled(isValidating)
    }

    private var hostField: some View {
        VStack(alignment: .leading, spacing: Constants.ManualTokenEntry.fieldSpacing) {
            ManualConnectionField(label: hostLabel) {
                TextField("192.168.1.42", text: $host, prompt: placeholder("192.168.1.42"))
                    .interFont(Constants.Typography.bodySEmphasized)
                    .accessibilityLabel("Host / Tailcat Address")
                    .accessibilityIdentifier("manual.host")
                    .focused($focusedField, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .port }
            }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #if os(visionOS)
            Text("Tailcat addresses aren't supported on visionOS yet — pair over your local network.")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            #endif
        }
    }

    private var hostLabel: LocalizedStringKey {
        #if os(visionOS)
        "HOST"
        #else
        "HOST / TAILCAT ADDRESS"
        #endif
    }

    private var portField: some View {
        ManualConnectionField(label: "PORT") {
            TextField("5180", text: $port, prompt: placeholder("5180"))
                .interFont(Constants.Typography.bodySEmphasized)
                .accessibilityLabel("Port")
                .accessibilityIdentifier("manual.port")
                .focused($focusedField, equals: .port)
                .keyboardType(.numberPad)
        }
    }

    private var tokenField: some View {
        ManualConnectionField(label: "API TOKEN", verticalPadding: Constants.ManualTokenEntry.pasteVerticalPadding) {
            HStack(spacing: Constants.ManualTokenEntry.progressSpacing) {
                tokenEditor
                if token.isEmpty {
                    pasteTokenButton
                }
                tokenVisibilityButton
            }
        }
    }

    private var tokenEditor: some View {
        Group {
            if isTokenVisible {
                TextField("Paste token", text: $token, prompt: placeholder("Paste token"))
            } else {
                SecureField("Paste token", text: $token, prompt: placeholder("Paste token"))
            }
        }
            .interFont(Constants.Typography.bodySEmphasized)
            .accessibilityLabel("API Token")
            .accessibilityIdentifier("manual.token")
            .focused($focusedField, equals: .token)
            .submitLabel(.done)
            .onSubmit { focusedField = nil }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    private var pasteTokenButton: some View {
        Button(action: pasteToken) {
            Image(.connectionClipboard)
                // The exact export already has 30% white strokes.
                .renderingMode(colorScheme == .dark && !isValidating ? .original : .template)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .frame(
                    width: Constants.ConnectionSheet.minimumTouchTarget,
                    height: Constants.ConnectionSheet.minimumTouchTarget
                )
                .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        // Preserve the visible light paste affordance rather than Figma's white-on-white export.
        .foregroundStyle(isValidating
            ? Constants.ConnectionSheet.disabledForeground(for: colorScheme)
            : Theme.foreground(for: colorScheme))
        .accessibilityLabel("Paste API token")
    }

    private var tokenVisibilityButton: some View {
        Button {
            isTokenVisible.toggle()
            focusedField = .token
        } label: {
            Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .frame(
                    width: Constants.ConnectionSheet.minimumTouchTarget,
                    height: Constants.ConnectionSheet.minimumTouchTarget
                )
                .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .foregroundStyle(isValidating
            ? Constants.ConnectionSheet.disabledForeground(for: colorScheme)
            : Theme.foreground(for: colorScheme).opacity(colorScheme == .dark ? Constants.ConnectionSheet.placeholderOpacity : 1))
        .accessibilityLabel(isTokenVisible ? "Hide API token" : "Show API token")
        // Expand the trailing hit region inward, retaining the reference's 24pt glyph inset.
        .padding(.trailing, -Constants.ManualTokenEntry.pasteHitExpansion)
    }

    private func placeholder(_ text: LocalizedStringKey) -> Text {
        Text(text).foregroundStyle(Constants.Pairing.foreground(for: colorScheme)
            .opacity(Constants.ConnectionSheet.placeholderOpacity))
    }

    @ViewBuilder
    private var validationError: some View {
        if let error = errorMessage {
            Text(error)
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .accessibilityIdentifier("manual.error")
        }
    }

    private var connectButton: some View {
        Button(action: toggleConnectionValidation) {
            Group {
                if isValidating {
                    HStack(spacing: Constants.ManualTokenEntry.progressSpacing) {
                        ProgressView().tint(Constants.Pairing.onAccent)
                        Text("Cancel")
                            .interFont(Constants.Typography.bodySEmphasized)
                    }
                } else {
                    Text("Connect")
                        .interFont(Constants.Typography.bodySEmphasized)
                }
            }
            .tracking(Constants.Pairing.optionTitleTracking)
            .foregroundStyle(
                !isValidating && (host.isEmpty || token.isEmpty)
                    ? Constants.ConnectionSheet.disabledForeground(for: colorScheme) : Constants.Pairing.onAccent
            )
            .padding(.vertical, Constants.ConnectionSheet.fieldVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Constants.ConnectionSheet.fieldHeight)
            .background(
                !isValidating && (host.isEmpty || token.isEmpty)
                    ? Constants.ConnectionSheet.disabledBackground(for: colorScheme) : Constants.Pairing.accent,
                in: .rect(cornerRadius: Constants.ConnectionSheet.fieldCornerRadius)
            )
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(!isValidating && (host.isEmpty || token.isEmpty))
        .accessibilityIdentifier("manual.connect")
    }

    private func pasteToken() {
        if let clipboard = UIPasteboard.general.string { token = clipboard }
    }

    private func toggleConnectionValidation() {
        if isValidating {
            connectTask?.cancel()
            connectTask = nil
            isValidating = false
        } else {
            validateAndConnect()
        }
    }

    private func validateAndConnect() {
        guard let portNum = Int(port) else {
            PairingDiagnostics.invalidInput()
            errorMessage = "Invalid port number"
            return
        }
        let input = ManualConnectionInput.classify(host)
        #if os(visionOS)
        // Belt-and-braces behind the field explanation above: a pasted tc
        // address fails fast here instead of spinning through the dialer.
        if case .tailcat = input {
            PairingDiagnostics.phase(.input, .failed, failure: DiagnosticFailure(origin: .localOperation, classification: .unavailable))
            errorMessage = "Tailcat addresses aren't supported on visionOS yet — pair over your local network."
            return
        }
        #endif

        isValidating = true
        errorMessage = nil

        PairingDiagnostics.phase(.probe, .started)
        connectTask = Task {
            let probed: CertFingerprintProbe.ProbeResult
            switch input {
            case .direct(let host):
                probed = await CertFingerprintProbe.probe(host: host, port: portNum)
            case .tailcat(let tcAddress):
                do {
                    probed = try await CertFingerprintProbe.probeViaTunnel(
                        dialer: session.connection.tunnelDialer,
                        tcAddress: tcAddress,
                        remotePort: portNum
                    )
                } catch {
                    // Classification only recognizes the expected prefix,
                    // base64, and CBOR-header shape. TailcatKit authoritatively
                    // validates decoded fields, and the dial reports invalid
                    // or unreachable addresses.
                    guard !Task.isCancelled else { return }
                    PairingDiagnostics.phase(.probe, .failed, failure: TransportDiagnosticFailure.classify(error))
                    errorMessage = "Could not reach the Tailcat address: \(error.localizedDescription)"
                    isValidating = false
                    return
                }
            }

            // The user may have hit Cancel while the probe was in flight: a
            // cancelled direct probe surfaces here as `.cancelled` (the
            // tunnel branch handles its thrown cancellation above), and
            // processing it would show a spurious certificate error (or
            // clobber the state of a newer attempt). Drop the result instead.
            guard !Task.isCancelled else { return }

            PairingDiagnostics.probeResult(probed)
            switch CertFingerprintProbe.outcome(forProbe: probed) {
            case .confirmFingerprint(let fingerprint):
                probedFingerprint = fingerprint
                probedInput = input
                showFingerprintConfirmation = true
            case .abort(let message):
                // Never connect unpinned: without a probed certificate there is
                // no way to verify the server's identity. The message names
                // the stage the probe failed at (ios#233).
                errorMessage = message
                isValidating = false
            }
        }
    }

    private func connectWithFingerprint() {
        guard let portNum = Int(port), let fingerprint = probedFingerprint,
              let input = probedInput else { return }

        Task { await connect(input: input, port: portNum, fingerprint: fingerprint) }
    }

    private func connect(input: ManualConnectionInput, port: Int, fingerprint: String) async {
        do {
            let stored = try await Self.connectAndSave(
                input: input,
                port: port,
                fingerprint: fingerprint,
                token: token,
                connection: session.connection
            )
            dismiss()
            if let onPaired {
                onPaired(stored)
            } else {
                coordinator.onPaired(stored)
            }
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
            isValidating = false
        }
    }
}

extension ManualTokenEntryView {
    /// Each phase owns only its own errors; the view handles presentation for either failure.
    @MainActor static func connectAndSave(
        input: ManualConnectionInput,
        port: Int,
        fingerprint: String,
        token: String,
        connection: any SessionConnectionManaging,
        persistence: PersistenceManager = .shared,
        diagnostics: DiagnosticStore = .shared
    ) async throws -> StoredConnection {
        let attemptID = UUID()
        var persisted = false
        defer { if !persisted { connection.disconnectPairingAttempt(attemptID) } }
        PairingDiagnostics.phase(.connect, .started, store: diagnostics)
        do {
            try await PairingConnectionContext.$attemptID.withValue(attemptID) {
                try await DiagnosticConnectContext.$origin.withValue(.pairing) {
                    try await connection.connect(
                        hosts: input.hosts,
                        port: port,
                        token: token,
                        certFingerprint: fingerprint,
                        tcAddress: input.tcAddress
                    )
                }
            }
        } catch {
            PairingDiagnostics.phase(.connect, error is CancellationError ? .cancelled : .failed, store: diagnostics)
            throw error
        }
        if Task.isCancelled || connection.pairingAttemptID != attemptID {
            PairingDiagnostics.phase(.connect, .cancelled, store: diagnostics)
            throw CancellationError()
        }
        let server = PairedServer(
            hosts: input.hosts,
            port: port,
            name: "Intent",
            pairedAt: Date(),
            certFingerprint: fingerprint,
            tcAddress: input.tcAddress
        )
        do {
            PairingDiagnostics.phase(.save, .started, store: diagnostics)
            let stored = try await ConnectionPairing.finalize(
                server: server,
                token: token,
                connection: connection,
                persistence: persistence
            )
            persisted = true
            PairingDiagnostics.phase(.save, .succeeded, store: diagnostics)
            return stored
        } catch {
            PairingDiagnostics.phase(.save, error is CancellationError ? .cancelled : .failed, store: diagnostics)
            throw error
        }
    }
}
