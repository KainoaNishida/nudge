import AppKit
import Combine
import SwiftUI

enum PetEdge: String, Codable, CaseIterable {
    case left, right
    var label: String { self == .left ? "Left" : "Right" }
}

struct PetOptions: Codable, Equatable {
    static let defaultSpriteSize = 60
    static let spriteSizes = [48, 60, 72, 84, 96]

    var enabled = true
    var edge: PetEdge = .right
    // Optional so saved settings from older builds still decode.
    var spriteSize: Int?
    var horizontalFraction: Double?
    var verticalFraction = 0.28
    var displayID: UInt32?
    var hiddenUntil: Date?
    var pausedForScreenSharing = false

    var selectedSpriteSize: Int {
        let requested = min(Self.spriteSizes.last!, max(Self.spriteSizes.first!, spriteSize ?? Self.defaultSpriteSize))
        return Self.spriteSizes.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? Self.defaultSpriteSize
    }
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
        if next.spriteSize != nil { next.spriteSize = next.selectedSpriteSize }
        if let fraction = next.horizontalFraction { next.horizontalFraction = min(1, max(0, fraction)) }
        next.verticalFraction = min(1, max(0, next.verticalFraction))
        options = next
    }

    func hideForOneHour() { update { $0.hiddenUntil = Date().addingTimeInterval(3_600) } }
    func close() { update { $0.enabled = false } }
    func resume() { update { $0.hiddenUntil = nil; $0.pausedForScreenSharing = false } }

    var isVisibleNow: Bool {
        options.enabled && !options.pausedForScreenSharing && (options.hiddenUntil ?? .distantPast) <= Date()
    }
}

@MainActor
final class PetDisplay: ObservableObject {
    @Published var alerting = false
    @Published var edge: PetEdge = .right
    @Published var spriteSize: CGFloat = CGFloat(PetOptions.defaultSpriteSize)
}

@MainActor
final class PetWindowController {
    private let settings: PetSettings
    private let display = PetDisplay()
    private let panel: NSPanel
    private let openQueue: () -> Void
    private let openSettings: () -> Void
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var attentionTimer: Timer?
    private static func catSize(for spriteSize: CGFloat) -> NSSize {
        NSSize(width: spriteSize + 16, height: spriteSize + 24)
    }

    private static func alertSize(for spriteSize: CGFloat) -> NSSize {
        NSSize(width: spriteSize + 106, height: spriteSize + 52)
    }

    init(settings: PetSettings, openQueue: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.openQueue = openQueue
        self.openSettings = openSettings
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.catSize(for: CGFloat(settings.options.selectedSpriteSize))),
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
            drag: { [weak self] mouse in self?.drag(mouse) },
            finishDrag: { [weak self] in self?.finishDrag() },
            close: { [weak self] in self?.settings.close() },
            hide: { [weak self] in self?.settings.hideForOneHour() },
            pause: { [weak self] in self?.settings.update { $0.pausedForScreenSharing = true } },
            settings: { [weak self] in self?.openSettings() }
        ))
        refresh()
    }

    func refresh() {
        guard settings.isVisibleNow else { panel.orderOut(nil); return }
        if dragStart != nil { return }
        display.edge = settings.options.edge
        display.spriteSize = CGFloat(settings.options.selectedSpriteSize)
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
        let catSize = Self.catSize(for: display.spriteSize)
        let size = display.alerting ? Self.alertSize(for: display.spriteSize) : catSize
        let idleX: CGFloat
        if let fraction = settings.options.horizontalFraction {
            idleX = area.minX + max(0, area.width - catSize.width) * fraction
        } else {
            idleX = settings.options.edge == .right ? area.maxX - catSize.width - 12 : area.minX + 12
        }
        let preferredX = display.alerting && settings.options.edge == .right ? idleX - (size.width - catSize.width) : idleX
        let x = min(max(preferredX, area.minX), max(area.minX, area.maxX - size.width))
        let preferredY = area.minY + max(0, area.height - catSize.height) * settings.options.verticalFraction
        let y = min(max(preferredY, area.minY), max(area.minY, area.maxY - size.height))
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func drag(_ mouse: NSPoint) {
        if dragStart == nil { dragStart = (mouse: mouse, origin: panel.frame.origin) }
        guard let dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                                     y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
    }

    private func finishDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        let catSize = Self.catSize(for: display.spriteSize)
        let catX = display.alerting && display.edge == .right ? panel.frame.maxX - catSize.width : panel.frame.minX
        let center = NSPoint(x: catX + catSize.width / 2, y: panel.frame.minY + catSize.height / 2)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? selectedScreen()
        guard let screen else { return }
        let area = screen.visibleFrame
        let edge: PetEdge = center.x < area.midX ? .left : .right
        let horizontalFraction = (catX - area.minX) / max(1, area.width - catSize.width)
        let verticalFraction = (panel.frame.minY - area.minY) / max(1, area.height - catSize.height)
        settings.update {
            $0.edge = edge
            $0.horizontalFraction = horizontalFraction
            $0.verticalFraction = verticalFraction
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
    @State private var isHovered = false
    var open: () -> Void
    var drag: (NSPoint) -> Void
    var finishDrag: () -> Void
    var close: () -> Void
    var hide: () -> Void
    var pause: () -> Void
    var settings: () -> Void

    var body: some View {
        VStack(alignment: display.edge == .right ? .trailing : .leading, spacing: 0) {
            HStack {
                if display.edge == .right { Spacer(minLength: 0) }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color(red: 0.16, green: 0.19, blue: 0.24).opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .help("Close cat. Restore it in Nudge Settings.")
                .accessibilityLabel("Close pixel cat")
                if display.edge == .left { Spacer(minLength: 0) }
            }
            .frame(height: 22)
            if display.alerting {
                Text("New updates!")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .background(Color(red: 0.16, green: 0.19, blue: 0.24), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Nudge has new updates")
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let tick = Int(timeline.date.timeIntervalSinceReferenceDate * 4)
                PixelCatSprite(alerting: display.alerting,
                               alternate: tick % 4 < 2,
                               blink: !display.alerting && tick % 28 == 0)
                    .frame(width: display.spriteSize, height: display.spriteSize)
            }
            .frame(width: display.spriteSize + 4, height: display.spriteSize + 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in drag(NSEvent.mouseLocation) }
                .onEnded { _ in finishDrag() })
            .onTapGesture(perform: open)
            .contextMenu {
                Button("Open Nudge", action: open)
                Button("Hide for one hour", action: hide)
                Button("Pause for screen sharing", action: pause)
                Button("Pet settings", action: settings)
                Button("Close cat", action: close)
            }
            .accessibilityLabel("Nudge pixel cat. Click to open Nudge; drag anywhere on screen to move.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: display.edge == .right ? .bottomTrailing : .bottomLeading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
    }
}

private struct PixelCatSprite: View {
    var alerting: Bool
    var alternate: Bool
    var blink: Bool

    private struct Block {
        var x: Int; var y: Int; var width: Int; var height: Int; var color: Color
        init(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
            self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
        }
    }

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width, size.height) / 24
            for block in blocks {
                context.fill(Path(CGRect(x: CGFloat(block.x) * cell, y: CGFloat(block.y) * cell,
                                         width: CGFloat(block.width) * cell, height: CGFloat(block.height) * cell)),
                             with: .color(block.color))
            }
        }
        .accessibilityHidden(true)
    }

    private var blocks: [Block] {
        let ink = Color(red: 0.20, green: 0.18, blue: 0.23)
        let fur = Color(red: 0.93, green: 0.57, blue: 0.31)
        let shade = Color(red: 0.71, green: 0.36, blue: 0.25)
        let light = Color(red: 1.00, green: 0.84, blue: 0.60)
        let cream = Color(red: 1.00, green: 0.94, blue: 0.78)
        let pink = Color(red: 0.96, green: 0.53, blue: 0.58)
        let spark = Color(red: 1.00, green: 0.83, blue: 0.30)
        var result = [
            // A small grounded silhouette, a curled tail, and a cream chest.
            Block(4, 23, 17, 1, ink.opacity(0.18)),
            Block(18, 15, 4, 7, ink), Block(19, 16, 4, 5, shade),
            Block(20, 17, 3, 3, fur), Block(21, 18, 2, 1, light),
            Block(5, 14, 15, 9, ink), Block(6, 15, 13, 7, fur),
            Block(7, 17, 3, 4, shade), Block(9, 16, 7, 6, light),
            Block(10, 17, 5, 4, cream),
            Block(5, 21, 6, 2, ink), Block(6, 21, 4, 1, cream),
            Block(14, 21, 6, 2, ink), Block(15, 21, 4, 1, cream),
            // Pointed ears with visible pink interiors.
            Block(3, 2, 6, 7, ink), Block(15, 2, 6, 7, ink),
            Block(4, 3, 4, 6, fur), Block(16, 3, 4, 6, fur),
            Block(5, 4, 2, 4, pink), Block(17, 4, 2, 4, pink),
            Block(5, 3, 2, 1, light), Block(17, 3, 2, 1, light),
            // Rounded tabby face and slightly tufted cheeks.
            Block(3, 7, 18, 10, ink), Block(2, 11, 3, 5, ink), Block(19, 11, 3, 5, ink),
            Block(4, 8, 16, 8, fur), Block(3, 12, 3, 3, fur), Block(18, 12, 3, 3, fur),
            Block(7, 8, 3, 2, light), Block(14, 8, 3, 2, light),
            Block(10, 8, 1, 3, shade), Block(13, 8, 1, 3, shade),
            Block(5, 11, 2, 2, light), Block(17, 11, 2, 2, light),
            Block(8, 13, 8, 3, cream), Block(9, 12, 2, 3, light), Block(13, 12, 2, 3, light),
            Block(11, 13, 2, 1, pink), Block(11, 14, 1, 1, ink), Block(13, 14, 1, 1, ink),
            Block(3, 13, 4, 1, ink), Block(17, 13, 4, 1, ink),
            Block(6, 14, 1, 1, pink), Block(17, 14, 1, 1, pink)
        ]
        if blink {
            result += [Block(7, 11, 3, 1, ink), Block(14, 11, 3, 1, ink)]
        } else {
            result += [Block(7, 10, 3, 3, ink), Block(14, 10, 3, 3, ink),
                       Block(8, 10, 1, 1, cream), Block(15, 10, 1, 1, cream)]
        }
        if alternate {
            result += [Block(21, 14, 2, 2, ink), Block(21, 15, 1, 1, light)]
        } else {
            result += [Block(20, 13, 2, 2, ink), Block(20, 14, 1, 1, light)]
        }
        if alerting {
            result += [Block(1, 5, 1, 3, spark), Block(0, 6, 3, 1, spark),
                       Block(22, 5, 1, 3, spark), Block(21, 6, 3, 1, spark)]
            if alternate {
                result += [Block(16, 18, 4, 3, ink), Block(17, 18, 3, 2, cream)]
            }
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
            Text("The cat can sit anywhere on a screen, including full-screen Spaces. It reacts only when an actionable conversation is added or substantively updated.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Cat size", selection: Binding(
                get: { settings.options.selectedSpriteSize },
                set: { size in settings.update { $0.spriteSize = size } }
            )) {
                Text("Smaller").tag(48)
                Text("Default").tag(60)
                Text("Medium").tag(72)
                Text("Large").tag(84)
                Text("Largest").tag(96)
            }
            .pickerStyle(.segmented)
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
                    set: { edge in settings.update { $0.edge = edge; $0.horizontalFraction = nil } }
                )) {
                    ForEach(PetEdge.allCases, id: \.self) { edge in Text(edge.label).tag(edge) }
                }
            }
            Text("Drag the cat anywhere on a screen; it stays where you leave it. Choosing an edge moves it back to that edge.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Hide for one hour") { settings.hideForOneHour() }
                Toggle("Pause for screen sharing", isOn: Binding(
                    get: { settings.options.pausedForScreenSharing },
                    set: { paused in settings.update { $0.pausedForScreenSharing = paused } }
                ))
                Button("Show now") { settings.resume() }
            }
            Text("The X closes the cat until you turn on Show the pixel cat here. Screen-sharing pause is manual. The cat has no sound and never shows names or message text.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
