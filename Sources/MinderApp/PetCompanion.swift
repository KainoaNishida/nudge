import AppKit
import Combine
import SwiftUI

enum PetEdge: String, Codable, CaseIterable {
    case left, right
    var label: String { self == .left ? "Left" : "Right" }
}

struct PetOptions: Codable, Equatable {
    var enabled = true
    var edge: PetEdge = .right
    var verticalFraction = 0.28
    var displayID: UInt32?
    var hiddenUntil: Date?
    var pausedForScreenSharing = false
}

@MainActor
final class PetSettings: ObservableObject {
    static let shared = PetSettings()
    private static let key = "nudge.pixel-cat.options.v1"
    @Published private(set) var options: PetOptions {
        didSet { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(PetOptions.self, from: data) {
            options = decoded
        } else {
            options = PetOptions()
        }
    }

    func update(_ change: (inout PetOptions) -> Void) {
        var next = options
        change(&next)
        next.verticalFraction = min(0.9, max(0.1, next.verticalFraction))
        options = next
    }

    func hideForOneHour() { update { $0.hiddenUntil = Date().addingTimeInterval(3_600) } }
    func resume() { update { $0.hiddenUntil = nil; $0.pausedForScreenSharing = false } }

    var isVisibleNow: Bool {
        options.enabled && !options.pausedForScreenSharing && (options.hiddenUntil ?? .distantPast) <= Date()
    }
}

@MainActor
final class PetDisplay: ObservableObject {
    @Published var alerting = false
    @Published var edge: PetEdge = .right
}

@MainActor
final class PetWindowController {
    private let settings: PetSettings
    private let display = PetDisplay()
    private let panel: NSPanel
    private let openQueue: () -> Void
    private let openSettings: () -> Void
    private var dragOrigin: NSPoint?
    private var attentionTimer: Timer?
    private static let catSize = NSSize(width: 72, height: 72)
    private static let alertSize = NSSize(width: 164, height: 102)

    init(settings: PetSettings, openQueue: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.openQueue = openQueue
        self.openSettings = openSettings
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.catSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PixelCatOverlay(
            display: display,
            open: { [weak self] in self?.openFromPet() },
            drag: { [weak self] translation in self?.drag(translation) },
            finishDrag: { [weak self] in self?.finishDrag() },
            hide: { [weak self] in self?.settings.hideForOneHour() },
            pause: { [weak self] in self?.settings.update { $0.pausedForScreenSharing = true } },
            settings: { [weak self] in self?.openSettings() }
        ))
        refresh()
    }

    func refresh() {
        guard settings.isVisibleNow else { panel.orderOut(nil); return }
        display.edge = settings.options.edge
        place(on: selectedScreen(), animated: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func signal() {
        guard settings.isVisibleNow else { return }
        attentionTimer?.invalidate()
        display.alerting = true
        refresh()
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.display.alerting = false
                self?.refresh()
            }
        }
    }

    func acknowledge() {
        attentionTimer?.invalidate()
        display.alerting = false
        refresh()
    }

    private func openFromPet() {
        acknowledge()
        openQueue()
    }

    private func selectedScreen() -> NSScreen? {
        if let id = settings.options.displayID,
           let screen = NSScreen.screens.first(where: { $0.nudgeDisplayID == id }) { return screen }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func place(on screen: NSScreen?, animated: Bool) {
        guard let screen else { return }
        let area = screen.visibleFrame
        let size = display.alerting ? Self.alertSize : Self.catSize
        let x = settings.options.edge == .right ? area.maxX - size.width - 12 : area.minX + 12
        let y = area.minY + (area.height - Self.catSize.height) * settings.options.verticalFraction
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func drag(_ translation: CGSize) {
        if dragOrigin == nil { dragOrigin = panel.frame.origin }
        guard let dragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: dragOrigin.x + translation.width, y: dragOrigin.y - translation.height))
    }

    private func finishDrag() {
        dragOrigin = nil
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? selectedScreen()
        guard let screen else { return }
        let area = screen.visibleFrame
        let edge: PetEdge = center.x < area.midX ? .left : .right
        let fraction = (panel.frame.minY - area.minY) / max(1, area.height - Self.catSize.height)
        settings.update {
            $0.edge = edge
            $0.verticalFraction = fraction
            $0.displayID = screen.nudgeDisplayID
        }
        refresh()
    }
}

extension NSScreen {
    var nudgeDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private struct PixelCatOverlay: View {
    @ObservedObject var display: PetDisplay
    var open: () -> Void
    var drag: (CGSize) -> Void
    var finishDrag: () -> Void
    var hide: () -> Void
    var pause: () -> Void
    var settings: () -> Void

    var body: some View {
        VStack(alignment: display.edge == .right ? .trailing : .leading, spacing: 2) {
            if display.alerting {
                Text("New updates!")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .background(Color(red: 0.16, green: 0.19, blue: 0.24), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Nudge has new updates")
            }
            TimelineView(.periodic(from: .now, by: 0.35)) { timeline in
                PixelCatSprite(alerting: display.alerting,
                               alternate: Int(timeline.date.timeIntervalSinceReferenceDate * 3) % 2 == 0)
                    .frame(width: 64, height: 64)
            }
            .frame(width: 72, height: 72)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5)
                .onChanged { drag($0.translation) }
                .onEnded { _ in finishDrag() })
            .onTapGesture(perform: open)
            .contextMenu {
                Button("Open Nudge", action: open)
                Button("Hide for one hour", action: hide)
                Button("Pause for screen sharing", action: pause)
                Button("Pet settings", action: settings)
            }
            .accessibilityLabel("Nudge pixel cat. Click to open Nudge; drag to move.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: display.edge == .right ? .bottomTrailing : .bottomLeading)
    }
}

private struct PixelCatSprite: View {
    var alerting: Bool
    var alternate: Bool

    private struct Block {
        var x: Int; var y: Int; var width: Int; var height: Int; var color: Color
        init(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
            self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
        }
    }

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width, size.height) / 16
            for block in blocks {
                context.fill(Path(CGRect(x: CGFloat(block.x) * cell, y: CGFloat(block.y) * cell,
                                         width: CGFloat(block.width) * cell, height: CGFloat(block.height) * cell)),
                             with: .color(block.color))
            }
        }
        .accessibilityHidden(true)
    }

    private var blocks: [Block] {
        let ink = Color(red: 0.19, green: 0.22, blue: 0.25)
        let fur = Color(red: 0.93, green: 0.72, blue: 0.45)
        let light = Color(red: 1.0, green: 0.89, blue: 0.69)
        let pink = Color(red: 0.96, green: 0.53, blue: 0.54)
        let spark = Color(red: 1.0, green: 0.83, blue: 0.23)
        var result = [
            Block(12, 9, 2, 2, ink), Block(13, 7, 2, 3, ink),
            Block(13, 8, 1, 2, fur),
            Block(4, 9, 8, 6, ink), Block(5, 10, 6, 4, fur),
            Block(4, 14, 3, 1, ink), Block(9, 14, 3, 1, ink),
            Block(3, 1, 3, 4, ink), Block(10, 1, 3, 4, ink),
            Block(4, 2, 1, 2, pink), Block(11, 2, 1, 2, pink),
            Block(2, 4, 12, 7, ink), Block(3, 5, 10, 5, fur),
            Block(4, 9, 8, 1, light), Block(7, 8, 2, 2, light),
            Block(8, 8, 1, 1, pink)
        ]
        if alerting && alternate {
            result += [Block(5, 7, 2, 1, ink), Block(10, 7, 2, 1, ink),
                       Block(14, 3, 1, 3, spark), Block(14, 7, 1, 1, spark)]
        } else {
            result += [Block(5, 6, 2, 2, ink), Block(10, 6, 2, 2, ink)]
        }
        return result
    }
}

struct PetSettingsView: View {
    @ObservedObject private var settings = PetSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle("Show the pixel cat", isOn: Binding(
                get: { settings.options.enabled },
                set: { enabled in settings.update { $0.enabled = enabled } }
            ))
            Text("The cat appears on normal desktop Spaces. It reacts only when an actionable conversation is added or substantively updated.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Screen", selection: Binding(
                    get: { settings.options.displayID },
                    set: { id in settings.update { $0.displayID = id } }
                )) {
                    Text("Current screen").tag(UInt32?.none)
                    ForEach(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                        guard let id = screen.nudgeDisplayID else { return nil }
                        return (id, screen.localizedName)
                    }, id: \.0) { id, name in
                        Text(name).tag(Optional(id))
                    }
                }
                Picker("Edge", selection: Binding(
                    get: { settings.options.edge },
                    set: { edge in settings.update { $0.edge = edge } }
                )) {
                    ForEach(PetEdge.allCases, id: \.self) { edge in Text(edge.label).tag(edge) }
                }
            }
            Text("Drag the cat to move it. It snaps to the nearest edge and remembers the screen.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Hide for one hour") { settings.hideForOneHour() }
                Toggle("Pause for screen sharing", isOn: Binding(
                    get: { settings.options.pausedForScreenSharing },
                    set: { paused in settings.update { $0.pausedForScreenSharing = paused } }
                ))
                Button("Show now") { settings.resume() }
            }
            Text("The screen-sharing pause is a manual switch. The cat has no sound and never shows names or message text.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
