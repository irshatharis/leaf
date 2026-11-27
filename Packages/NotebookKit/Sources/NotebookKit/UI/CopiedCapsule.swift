#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// What Copy File shows: a capsule of glass saying what was copied, for as long as it takes to read, at the bottom of
/// the window you are working in, on iPhone and iPad above the bar at the bottom. VoiceOver says it too.
struct CopiedCapsuleView: View {
    let name: String

    var body: some View {
        Label("Copied “\(name)”", systemImage: "doc.on.doc")
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 420)
            .accessibilityHidden(true)
    }

    /// How long it stays.
    static let shownFor = Duration.seconds(1.6)

    static func announce(_ name: String) {
        let text = "Copied “\(name)”"
        #if os(macOS)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #else
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

/// The capsule over a SwiftUI window, the main window on the Mac, the scene on iPhone and iPad.
extension View {
    func copiedCapsule(_ workspace: Workspace) -> some View {
        modifier(CopiedCapsuleOverlay(workspace: workspace))
    }
}

private struct CopiedCapsuleOverlay: ViewModifier {
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    private let bottom: CGFloat = 28
    #else
    /// Clear of the bar of buttons at the bottom of a note.
    private let bottom: CGFloat = 76
    #endif

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let copied = workspace.copied.file {
                    CopiedCapsuleView(name: copied.name)
                        .padding(.bottom, bottom)
                        .padding(.horizontal, 20)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.94)))
                        .id(copied.id)
                        .allowsHitTesting(false)
                        .task {
                            CopiedCapsuleView.announce(copied.name)
                            try? await Task.sleep(for: CopiedCapsuleView.shownFor)
                            if workspace.copied.file?.id == copied.id { workspace.copied.file = nil }
                        }
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.2), value: workspace.copied.file)
    }
}
