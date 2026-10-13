import SwiftUI

struct QRScannerOverlay: View {
    let showsGuide: Bool
    let isValidating: Bool
    let errorMessage: String?
    let isEmbedded: Bool
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsGuide { scanGuide }
            Group {
                if isEmbedded {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(IntentButtonStyle(variant: .secondary))
                        .environment(\.colorScheme, .light)
                        .accessibilityIdentifier("ipad.pairing.cancel")
                } else {
                    IntentIconButton(icon: .close, label: "Cancel", action: onCancel)
                }
            }
            .padding(.leading, isEmbedded ? IPadSidebarStyle.topInset : Constants.QRScanner.horizontalInset)
            .padding(.top, isEmbedded ? IPadSidebarStyle.topInset : Constants.QRScanner.cancelTopPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scanGuide: some View {
        let geometry = QRScannerGeometry(
            horizontalInset: Constants.QRScanner.horizontalInset,
            verticalOffset: isEmbedded ? 0 : Constants.QRScanner.windowVerticalOffset,
            maximumSide: isEmbedded ? IPadPairingDetail.scannerWindowSize : nil
        )
        return ZStack {
            QRScannerMask(geometry: geometry, cornerRadius: Constants.QRScanner.windowCornerRadius)
                .fill(.black.opacity(Constants.QRScanner.dimmingOpacity), style: FillStyle(eoFill: true))
            QRScannerCorners(
                geometry: geometry,
                armLength: Constants.QRScanner.bracketArmLength,
                cornerRadius: Constants.QRScanner.windowCornerRadius
            )
            .stroke(.white, style: StrokeStyle(lineWidth: Constants.QRScanner.bracketWidth, lineCap: .round))
            QRScannerStatusLayout(geometry: geometry, topPadding: Constants.QRScanner.instructionTopPadding) {
                scannerStatus
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Constants.QRScanner.horizontalInset)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var scannerStatus: some View {
        VStack(spacing: Constants.QRScanner.statusSpacing) {
            HStack(spacing: Constants.QRScanner.statusSpacing) {
                if isValidating {
                    ProgressView().tint(.white)
                    Text("Connecting…")
                        .interFont(Constants.Typography.bodyXS)
                } else if let error = errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .interFont(Constants.Typography.bodyXS)
                } else {
                    Image(.scanHint)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Constants.QRScanner.hintIconSize, height: Constants.QRScanner.hintIconSize)
                        .accessibilityHidden(true)
                    Text("Find QR code in Settings -> Mobile\nin the Intent desktop app")
                        .interFont(Constants.Typography.bodyXS)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
    }
}

/// All guide elements derive their coordinates during layout, including the first frame.
nonisolated private struct QRScannerGeometry {
    let horizontalInset: CGFloat
    let verticalOffset: CGFloat
    var maximumSide: CGFloat?

    func window(in rect: CGRect) -> CGRect {
        let side = max(0, min(rect.width - 2 * horizontalInset, rect.height / 2, maximumSide ?? .infinity))
        return CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2 + verticalOffset,
            width: side,
            height: side
        )
    }
}

nonisolated private struct QRScannerMask: Shape {
    let geometry: QRScannerGeometry
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addPath(
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .path(in: geometry.window(in: rect))
        )
        return path
    }
}

private struct QRScannerStatusLayout: Layout {
    let geometry: QRScannerGeometry
    let topPadding: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let window = geometry.window(in: bounds)
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: window.maxY + topPadding),
                anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}

nonisolated private struct QRScannerCorners: Shape {
    let geometry: QRScannerGeometry
    let armLength: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let window = geometry.window(in: rect)
        let arm = min(armLength, window.width / 2)
        let radius = min(cornerRadius, arm)
        var corner = Path()
        corner.move(to: CGPoint(x: arm, y: 0))
        corner.addArc(tangent1End: .zero, tangent2End: CGPoint(x: 0, y: arm), radius: radius)
        corner.addLine(to: CGPoint(x: 0, y: arm))
        var path = Path()
        for (scaleX, originX) in [(1.0, window.minX), (-1.0, window.maxX)] {
            for (scaleY, originY) in [(1.0, window.minY), (-1.0, window.maxY)] {
                path.addPath(corner, transform: CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: originX, ty: originY))
            }
        }
        return path
    }
}
