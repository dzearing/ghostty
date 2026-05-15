import SwiftUI
import GhosttyKit

struct HeroCarouselItem: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let isSelected: Bool
    let isHovered: Bool
    let thumbnailSize: CGSize

    var body: some View {
        ZStack {
            if isSelected {
                SnapshotView(surfaceView: surfaceView, size: thumbnailSize)
            } else {
                Ghostty.SurfaceRepresentable(view: surfaceView, size: thumbnailSize)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: glowColor, radius: isSelected ? 15 : 0)
        .shadow(color: glowColor.opacity(0.5), radius: isSelected ? 30 : 0)
        .opacity(isSelected || isHovered ? 1.0 : 0.35)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var borderColor: Color {
        if isSelected {
            return Color(red: 0.416, green: 0.416, blue: 1.0) // #6a6aff
        } else if isHovered {
            return Color(red: 0.545, green: 0.361, blue: 0.965) // #8b5cf6
        } else {
            return Color.gray.opacity(0.3)
        }
    }

    private var borderWidth: CGFloat {
        isSelected ? 2 : 1
    }

    private var glowColor: Color {
        isSelected ? Color(red: 0.416, green: 0.416, blue: 1.0).opacity(0.4) : .clear
    }
}

struct SnapshotView: View {
    let surfaceView: Ghostty.SurfaceView
    let size: CGSize

    @State private var snapshot: NSImage?
    private let refreshTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let snapshot = snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { captureSnapshot() }
        .onReceive(refreshTimer) { _ in captureSnapshot() }
    }

    private func captureSnapshot() {
        snapshot = surfaceView.asImage
    }
}
