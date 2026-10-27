import AppKit
import ContactBridgeCore
import SwiftUI

enum MainWindow {
    static let id = "main"
}

/// The menu-bar icon. Also hands the window opener to `ActivationPolicyController` (as the window itself and the menu do),
/// so the opener is known even when the window was hidden at a launch at login.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = MenuBarState(model.sync.snapshot)
        Group {
            if model.deps.isDemo {
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarGlyph.image(for: state.icon))
                    Text("Demo")
                }
            } else {
                Image(nsImage: MenuBarGlyph.image(for: state.icon))
            }
        }
        .accessibilityLabel("Contact Bridge: \(state.statusLine)")
        .task {
            ActivationPolicyController.shared.openMainWindow = { openWindow(id: MainWindow.id) }
        }
    }
}

extension MenuBarIcon {
    /// The badge in the glyph's corner; nil when all is well.
    var badgeSymbol: String? {
        switch self {
        case .normal: nil
        case .syncing: "arrow.triangle.2.circlepath"
        case .paused: "pause.fill"
        case .needsAttention: "exclamationmark"
        }
    }
}

/// The two figures of the app icon as a template image, so the menu bar tints it. Drawn from the icon's own geometry
/// (`Resources/AppIcon.icon/Assets/*-figure.svg`, a 1024 canvas); the state shows as a badge cut into the lower right.
@MainActor
enum MenuBarGlyph {
    private static var cache: [MenuBarIcon: NSImage] = [:]
    private static let size = NSSize(width: 22, height: 18)

    static func image(for icon: MenuBarIcon) -> NSImage {
        if let cached = cache[icon] { return cached }
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The figures span x 200...824 and y 228...730 of the icon: fit them to 16 pt high, centred.
            let scale = 16.0 / 502.0
            context.saveGState()
            context.translateBy(x: (size.width - 624 * scale) / 2, y: 1)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -200, y: -228)
            context.addPath(figures)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            if let symbol = icon.badgeSymbol { drawBadge(symbol, in: context) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Contact Bridge"
        cache[icon] = image
        return image
    }

    /// The front figure and its mirror image (the back figure is the front one reflected about x = 512).
    private static let figures: CGPath = {
        let front = CGMutablePath()
        front.addEllipse(in: CGRect(x: 290, y: 228, width: 180, height: 180))
        front.move(to: CGPoint(x: 370, y: 730))
        front.addLine(to: CGPoint(x: 244, y: 730))
        front.addCurve(to: CGPoint(x: 200, y: 686), control1: CGPoint(x: 214.67, y: 730), control2: CGPoint(x: 200, y: 715.33))
        front.addCurve(to: CGPoint(x: 380, y: 446), control1: CGPoint(x: 200, y: 470), control2: CGPoint(x: 281, y: 446))
        front.addCurve(to: CGPoint(x: 546.01, y: 558.13), control1: CGPoint(x: 454.44, y: 446), control2: CGPoint(x: 518.71, y: 459.57))
        front.addCurve(to: CGPoint(x: 461.66, y: 563.22), control1: CGPoint(x: 518.03, y: 551.23), control2: CGPoint(x: 488.61, y: 553.01))
        front.addCurve(to: CGPoint(x: 395.14, y: 615.33), control1: CGPoint(x: 434.71, y: 573.44), control2: CGPoint(x: 411.51, y: 591.61))
        front.addCurve(to: CGPoint(x: 370, y: 696), control1: CGPoint(x: 378.77, y: 639.04), control2: CGPoint(x: 370, y: 667.18))
        front.closeSubpath()
        let mirror = CGAffineTransform(translationX: 1024, y: 0).scaledBy(x: -1, y: 1)
        let both = CGMutablePath()
        both.addPath(front)
        both.addPath(front, transform: mirror)
        return both
    }()

    /// A small symbol in the lower right, with a clear ring cut around it so it reads against the figures.
    private static func drawBadge(_ name: String, in context: CGContext) {
        let centre = CGPoint(x: size.width - 4.5, y: size.height - 4.5)
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: centre.x - 5.5, y: centre.y - 5.5, width: 11, height: 11))
        context.setBlendMode(.normal)
        let configuration = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let box = symbol.size
        symbol.draw(in: NSRect(x: centre.x - box.width / 2, y: centre.y - box.height / 2, width: box.width, height: box.height))
    }
}

/// The menu. It reads the same `AppModel` as the window, so there is one engine and one source of truth.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = MenuBarState(model.sync.snapshot)
        if model.deps.isDemo {
            Text("Demo mode: sample data, nothing real")
        }
        Text(state.statusLine)
        if let line = state.reviewLine {
            Button(line) { show(.sync) }
        }
        if state.needsConfirmation {
            Button("Review and confirm…") { show(.sync) }
        }
        Divider()
        Button("Sync now") { Task { await model.sync.syncNow() } }
            .disabled(!state.canSyncNow)
        switch state.pauseControl {
        case .pause: Button("Pause syncing") { Task { await model.sync.pause() } }
        case .resume: Button("Resume syncing") { Task { await model.sync.resume() } }
        case .none: EmptyView()
        }
        Divider()
        Toggle("Open at login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.setEnabled($0) }))
        if model.loginItem.needsApproval {
            Button("Allow in Login Items settings…") { model.loginItem.openSystemSettings() }
        }
        Divider()
        Button("Open Contact Bridge") { show(nil) }
        Button("Quit Contact Bridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ section: SidebarSection?) {
        // The menu has the window opener at hand even if the label has not handed it over.
        ActivationPolicyController.shared.openMainWindow = { openWindow(id: MainWindow.id) }
        model.showWindow(section)
    }
}
