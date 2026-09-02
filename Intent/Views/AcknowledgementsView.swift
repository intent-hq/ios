import SwiftUI

/// Open-source acknowledgements shown from Settings. Each entry
/// reproduces the dependency's license text in full, as its terms
/// require for binary distribution.
struct AcknowledgementsView: View {
    @Environment(\.colorScheme) var colorScheme

    struct Entry: Identifiable {
        let name: String
        let url: String
        let licenseTitle: String
        let licenseText: String
        var id: String { name }
    }

    static let entries: [Entry] = [
        Entry(
            name: "tailcat",
            url: "https://github.com/tailscale/tailcat",
            licenseTitle: "BSD 3-Clause License",
            licenseText: """
            BSD 3-Clause License

            Copyright (c) 2020 Tailscale Inc & contributors.

            Redistribution and use in source and binary forms, with or without
            modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this
               list of conditions and the following disclaimer.

            2. Redistributions in binary form must reproduce the above copyright notice,
               this list of conditions and the following disclaimer in the documentation
               and/or other materials provided with the distribution.

            3. Neither the name of the copyright holder nor the names of its
               contributors may be used to endorse or promote products derived from
               this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
            AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
            IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
            DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
            FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
            DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
            SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
            CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
            OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
            OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """
        ),
    ]

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Self.entries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .textCase(.uppercase)

                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.licenseTitle)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Theme.foreground(for: colorScheme))
                                Text(entry.url)
                                    .font(.caption)
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                Text(entry.licenseText)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Theme.card(for: colorScheme))
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Acknowledgements")
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview("Acknowledgements") {
    NavigationStack {
        AcknowledgementsView()
    }
}
