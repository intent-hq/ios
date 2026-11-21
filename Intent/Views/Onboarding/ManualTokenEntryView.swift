import SwiftUI

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
        return cborMapPrefixRange.contains(decoded[0])
            && decoded[publicKeyHeaderRange].elementsEqual(publicKeyHeader)
    }

    var hosts: [String] {
        switch self {
        case .direct(let host): [host]
        case .tailcat: []
        }
    }

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
    var onPaired: ((StoredConnection) -> Void)?
    var isEmbedded = false
    var onCancel: (() -> Void)?
    @State private var host = ""
    @State private var port = "5181"
    @State private var token = ""
    @State private var isTokenVisible = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var probedFingerprint: String?
    @State private var probedInput: ManualConnectionInput?
    @State private var showFingerprintConfirmation = false
    @State private var connectTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field { case host, port }

    var body: some View {
        Group {
            if isEmbedded {
                IPadManualPairingSurface(onCancel: cancel) { entryForm }
            } else {
                sheetPresentation
            }
        }
            .onDisappear { connectTask?.cancel() }
            .accessibilityAction(.escape, cancel)
            .alert("Verify Server Identity", isPresented: $showFingerprintConfirmation) {
                Button("Cancel", role: .cancel) { isValidating = false }
                Button("Trust & Connect") { connectWithFingerprint() }
            } message: {
                Text("The server's TLS certificate fingerprint is:\n\n\(probedFingerprint ?? "")\n\nDo you trust this server?")
            }
    }

    private var sheetPresentation: some View {
        ConnectionSheet(
            initialHeight: Constants.ManualTokenEntry.initialSheetHeight,
            backgroundColor: Constants.Pairing.background(for: colorScheme),
            closeForeground: Constants.Pairing.foreground(for: colorScheme)
        ) {
            entryForm
        }
    }

    private func cancel() {
        connectTask?.cancel()
        connectTask = nil
        focusedField = nil
        if isEmbedded { onCancel?() } else { dismiss() }
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
                    .accessibilityLabel(hostAccessibilityLabel)
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

    private var hostAccessibilityLabel: LocalizedStringKey {
        #if os(visionOS)
        "Host"
        #else
        "Host / Tailcat Address"
        #endif
    }

    private var portField: some View {
        ManualConnectionField(label: "PORT") {
            TextField("5181", text: $port, prompt: placeholder("5181"))
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
        ManualTokenTextField(
            text: $token,
            isSecure: !isTokenVisible
        )
    }

    private var pasteTokenButton: some View {
        Button(action: pasteToken) {
            Image(.connectionClipboard)
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
        .foregroundStyle(isValidating
            ? Constants.ConnectionSheet.disabledForeground(for: colorScheme)
            : Theme.foreground(for: colorScheme))
        .accessibilityLabel("Paste API token")
    }

    private var tokenVisibilityButton: some View {
        Button {
            isTokenVisible.toggle()
        } label: {
            Image(isTokenVisible ? .eyeClosed : .eye)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .frame(
                    width: Constants.ConnectionSheet.minimumTouchTarget,
                    height: Constants.ConnectionSheet.minimumTouchTarget
                )
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(IntentContentButtonStyle())
        .foregroundStyle(isValidating
            ? Constants.ConnectionSheet.disabledForeground(for: colorScheme)
            : Theme.foreground(for: colorScheme).opacity(colorScheme == .dark ? Constants.ConnectionSheet.placeholderOpacity : 1))
        .accessibilityLabel(isTokenVisible ? "Hide API token" : "Show API token")
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
        ManualConnectionSubmitButton(
            isValidating: isValidating,
            canConnect: !host.isEmpty && !token.isEmpty,
            onSubmit: toggleConnectionValidation
        )
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
            showError("Invalid port number")
            return
        }
        let input = ManualConnectionInput.classify(host)
        #if os(visionOS)
        if case .tailcat = input {
            PairingDiagnostics.phase(.input, .failed, failure: DiagnosticFailure(origin: .localOperation, classification: .unavailable))
            showError("Tailcat addresses aren't supported on visionOS yet — pair over your local network.")
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
                    guard !Task.isCancelled else { return }
                    PairingDiagnostics.phase(.probe, .failed, failure: TransportDiagnosticFailure.classify(error))
                    showError("Could not reach the Tailcat address: \(error.localizedDescription)")
                    isValidating = false
                    return
                }
            }

            guard !Task.isCancelled else { return }

            PairingDiagnostics.probeResult(probed)
            switch CertFingerprintProbe.outcome(forProbe: probed) {
            case .confirmFingerprint(let fingerprint):
                probedFingerprint = fingerprint
                probedInput = input
                showFingerprintConfirmation = true
            case .abort(let message):
                showError(message)
                isValidating = false
            }
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    private func connectWithFingerprint() {
        guard let portNum = Int(port), let fingerprint = probedFingerprint,
              let input = probedInput else { return }

        connectTask = Task { await connect(input: input, port: portNum, fingerprint: fingerprint) }
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
            guard !Task.isCancelled else { return }
            if !isEmbedded { dismiss() }
            if let onPaired {
                onPaired(stored)
            } else {
                coordinator.onPaired(stored)
            }
        } catch {
            guard !Task.isCancelled else { return }
            showError("Connection failed: \(error.localizedDescription)")
            isValidating = false
        }
    }
}

extension ManualTokenEntryView {
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
