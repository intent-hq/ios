import SwiftUI

struct BonjourDiscoveryView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var browser = BonjourBrowser()
    @State private var selectedServer: DiscoveredServer?
    @State private var showTokenEntry = false
    @State private var showQRScanner = false
    @State private var resolvedHost: String?
    @State private var resolvedPort: Int?
    @State private var resolvedCertFingerprint: String?
    @State private var isResolving = false
    @State private var resolutionError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                VStack(spacing: 0) {
                    if browser.servers.isEmpty && browser.isSearching {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Searching for Intent on your network...")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            Text("Make sure Network Discovery is enabled in Intent Settings")
                                .font(.caption)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .frame(maxHeight: .infinity)
                    } else if browser.servers.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.slash")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            Text("No Intent apps found")
                                .font(.headline)
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                            Text("Make sure Intent is running and Network Discovery is enabled in Settings")
                                .font(.caption)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List {
                            Section {
                                ForEach(browser.servers) { server in
                                    Button {
                                        selectServer(server)
                                    } label: {
                                        HStack {
                                            Image(systemName: "desktopcomputer")
                                                .foregroundStyle(Theme.primary(for: colorScheme))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(server.name)
                                                    .font(.body.weight(.medium))
                                                    .foregroundStyle(Theme.foreground(for: colorScheme))
                                                if let host = server.host, let port = server.port {
                                                    Text("\(host):\(port)")
                                                        .font(.caption)
                                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                                }
                                            }
                                            Spacer()
                                            if isResolving && selectedServer?.id == server.id {
                                                ProgressView()
                                            } else {
                                                Image(systemName: "chevron.right")
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                            }
                                        }
                                    }
                                }
                            } header: {
                                Text("Intent Running on Your Network")
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Find on Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        browser.stopBrowsing()
                        dismiss()
                    }
                }
            }
            .onAppear { browser.startBrowsing() }
            .onDisappear { browser.stopBrowsing() }
            .sheet(isPresented: $showTokenEntry) {
                BonjourTokenEntryView(
                    serverName: selectedServer?.name ?? "Intent",
                    host: resolvedHost ?? "",
                    port: resolvedPort ?? 5179,
                    certFingerprint: resolvedCertFingerprint
                )
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView()
            }
            .alert("Connection Failed", isPresented: .init(
                get: { resolutionError != nil },
                set: { if !$0 { resolutionError = nil } }
            )) {
                Button("OK") { resolutionError = nil }
            } message: {
                Text(resolutionError ?? "")
            }
        }
    }

    private func selectServer(_ server: DiscoveredServer) {
        selectedServer = server
        isResolving = true
        resolutionError = nil

        Task {
            if let resolved = await browser.resolve(server) {
                resolvedHost = resolved.host
                resolvedPort = resolved.port
                resolvedCertFingerprint = resolved.certFingerprint
                isResolving = false
                showTokenEntry = true
            } else {
                isResolving = false
                resolutionError = "Couldn't connect to \(server.name). Make sure both devices are on the same network."
            }
        }
    }
}

