import SwiftUI

/// The window under the menu bar icon: a display, the volume, and one key per station.
struct Panel: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        PanelBody(model: model)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.space) { model.togglePlay(); return .handled }
            .onKeyPress(.upArrow) { model.setVolume(model.volume + 5); return .handled }
            .onKeyPress(.downArrow) { model.setVolume(model.volume - 5); return .handled }
            .onKeyPress(.rightArrow) { model.skip(1); return .handled }
            .onKeyPress(.leftArrow) { model.skip(-1); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "12"), phases: .down) { press in
                if let channel = model.channels.first(where: { $0.id == press.characters }) { model.play(channel) }
                return .handled
            }
            .background(WindowWatcher { isOpen in  // MenuBarExtra keeps its window; key state says open or closed
                if isOpen {
                    focused = true
                    model.panelOpened()
                } else {
                    model.panelClosed()
                }
            })
    }
}

enum Metrics {
    static let width: CGFloat = 320
    static let margin: CGFloat = 16
    static let gap: CGFloat = 8
    static let columns = 6
    static let key = (width - 2 * margin - CGFloat(columns - 1) * gap) / CGFloat(columns)
}

struct PanelBody: View {
    let model: AppModel
    @State private var hover = Hover()
    @Namespace private var led

    var body: some View {
        VStack(spacing: 0) {
            Display(model: model)
            if !model.searching {
                Transport(model: model).padding(.top, 14)
                Keys(model: model, hover: hover, led: led).padding(.top, 14)
                Caption(hover: hover).padding(.top, 9)
            }
            Footer(model: model).padding(.top, model.searching ? 14 : 5)
        }
        .padding(Metrics.margin)
        .frame(width: Metrics.width)
        .background(.panel)
    }
}

// MARK: - Display

/// The dark screen: what plays, in large type.
struct Display: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            screen
                .id(screenID)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity))
        }
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)  // fixed, so the keys never move
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.screen))
        .animation(.smooth(duration: 0.28), value: screenID)
    }

    private var screenID: String {
        if model.searching { return "searching" }
        return model.isPlaying ? model.currentID ?? model.playerTitle : "stopped"
    }

    @ViewBuilder private var screen: some View {
        if model.searching {
            Screen(header: "Searching", title: "Looking for your player", detail: model.status) {
                Button("Try again", action: model.retry)
                    .buttonStyle(.plain)
                    .panelLabel()
                    .foregroundStyle(.signal)
            }
        } else if model.isPlaying, let channel = model.current {
            if channel.isLive {
                LiveScreen(channel: channel)
            } else {
                Screen(header: "Infinite mixtape", title: channel.name, detail: channel.show) {
                    if let glyph = model.glyphs[channel.id] {
                        HStack {
                            Spacer()
                            GlyphImage(glyph: glyph, side: 44).foregroundStyle(.screenFaint)
                        }
                    }
                }
            }
        } else if model.isPlaying {
            Screen(header: "NTS", title: model.playerTitle)
        } else {
            Screen(header: "Stopped", title: model.last?.name ?? "NTS", detail: "Press Space or a key to play.", dim: true)
        }
    }
}

struct LiveScreen: View {
    let channel: Channel

    var body: some View {
        Screen(header: channel.name, live: true, trailing: hours, title: channel.show.isEmpty ? channel.name : channel.show,
               detail: channel.location) {
            VStack(alignment: .leading, spacing: 9) {
                if let start = channel.start, let end = channel.end, start < end {
                    Dial(start: start, end: end)
                }
                if !channel.next.isEmpty {
                    HStack(spacing: 6) {
                        Text("Next").foregroundStyle(.screenFaint)
                        Text(channel.next).foregroundStyle(.screenInk)
                    }
                    .panelLabel()
                    .lineLimit(1)
                }
            }
        }
    }

    private var hours: String {
        guard let start = channel.start, let end = channel.end, start < end else { return "" }
        return (start..<end).formatted(.interval.hour().minute())  // "17:00–18:00", or "5:00 – 6:00 PM"
    }
}

/// One layout for every state: label row, big title, detail, then whatever sits at the bottom.
struct Screen<Bottom: View>: View {
    let header: String
    var live = false
    var trailing = ""
    let title: String
    var detail = ""
    var dim = false
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(header).foregroundStyle(.screenInk)
                if live { OnAir() }
                Spacer(minLength: 8)
                Text(trailing).foregroundStyle(.screenFaint)
            }
            .panelLabel()
            .lineLimit(1)
            Text(title)
                .font(.title)
                .tracking(-0.3)
                .foregroundStyle(dim ? Tone.screenFaint : Tone.screenInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            if !detail.isEmpty {
                Text(detail)
                    .font(.detail)
                    .foregroundStyle(.screenFaint)
                    .lineLimit(live ? 1 : 3)
                    .padding(.top, 4)
            }
            Spacer(minLength: 8)
            bottom
        }
    }
}

extension Screen where Bottom == EmptyView {
    init(header: String, title: String, detail: String = "", dim: Bool = false) {
        self.init(header: header, title: title, detail: detail, dim: dim) { EmptyView() }
    }
}

/// An orange lamp that breathes while the show is live.
struct OnAir: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.signal)
                .frame(width: 6, height: 6)
                .phaseAnimator([1, 0.3]) { lamp, opacity in lamp.opacity(opacity) } animation: { _ in .easeInOut(duration: 1.2) }
            Text("Live").foregroundStyle(.screenFaint)
        }
    }
}

/// The show's hour as a radio dial: a tick every 5 minutes, a longer one every 15, an orange needle at now.
struct Dial: View {
    let start: Date
    let end: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let total = end.timeIntervalSince(start)
            let step: TimeInterval = [300, 600, 900, 1800, 3600].first { total / $0 <= 48 } ?? 3600
            let ticks = max(Int(total / step), 1)
            let done = min(max(context.date.timeIntervalSince(start) / total, 0), 1)
            Canvas { gc, size in
                for i in 0...ticks {
                    let x = (size.width - 1) * CGFloat(i) / CGFloat(ticks)
                    let major = (Double(i) * step).truncatingRemainder(dividingBy: 900) == 0
                    let height: CGFloat = major ? size.height - 4 : (size.height - 4) / 2
                    let tick = Path(CGRect(x: x, y: size.height - height, width: 1, height: height))
                    gc.fill(tick, with: Double(i) / Double(ticks) <= done ? .style(Tone.screenFaint) : .style(Tone.screenUnlit))
                }
                let needle = (size.width - 2) * done
                gc.fill(Path(roundedRect: CGRect(x: needle, y: 0, width: 2, height: size.height), cornerRadius: 1),
                        with: .style(Tone.signal))
            }
            .frame(height: 14)
            .accessibilityLabel("\(Int(done * 100)) percent of the show")
        }
    }
}

// MARK: - Play and volume

struct Transport: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(KeyStyle())
            .frame(width: Metrics.key)
            .help(model.isPlaying ? "Stop (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Stop" : "Play")
            VolumeMeter(model: model)
            VolumeReadout(model: model).frame(width: Metrics.key, alignment: .trailing)
        }
        .frame(height: 32)
    }
}

/// Twenty segments, like a level meter. Drag across them; ↑ ↓ move one segment.
struct VolumeMeter: View {
    let model: AppModel
    @GestureState private var dragging: Double?  // 0...1 while the pointer is down; resets even if the drag is cancelled
    private let segments = 20

    var body: some View {
        let level = dragging ?? Double(model.volume) / 100
        let lit = Int((level * Double(segments)).rounded(.up))
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i < lit ? Tone.ink : Tone.unlit)
                }
            }
            .frame(height: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { drag, state, _ in state = min(max(drag.location.x / geo.size.width, 0), 1) }
                    .onChanged { drag in
                        model.setVolume(Int((min(max(drag.location.x / geo.size.width, 0), 1) * 100).rounded()))
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(model.volume)")
        .accessibilityAdjustableAction { direction in
            model.setVolume(model.volume + (direction == .increment ? 5 : -5))
        }
    }
}

struct VolumeReadout: View {
    let model: AppModel

    var body: some View {
        Text(model.sonosVolume, format: .number.precision(.integerLength(2...)))
            .font(.readout)
            .foregroundStyle(.ink)
            .contentTransition(.numericText(value: Double(model.sonosVolume)))
            .animation(.snappy(duration: 0.2), value: model.sonosVolume)
            .help("Sonos volume (↑ ↓)")
    }
}

// MARK: - Station keys

/// The key under the pointer. Its own object, so a hover redraws the caption, not all 18 keys.
@MainActor @Observable final class Hover {
    var channel: Channel?
}

struct Keys: View {
    let model: AppModel
    let hover: Hover
    let led: Namespace.ID

    var body: some View {
        let selected = model.isPlaying ? model.currentID : nil
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.key), spacing: Metrics.gap), count: Metrics.columns),
                  spacing: Metrics.gap) {
            ForEach(model.channels) { channel in
                ChannelKey(channel: channel, glyph: model.glyphs[channel.id], isSelected: channel.id == selected,
                           led: led, hover: hover) { model.play(channel) }
                    .equatable()
            }
        }
        .animation(.snappy(duration: 0.3), value: selected)
    }
}

struct ChannelKey: View, Equatable {
    let channel: Channel
    let glyph: NSImage?
    let isSelected: Bool
    let led: Namespace.ID
    let hover: Hover
    let action: () -> Void

    nonisolated static func == (a: ChannelKey, b: ChannelKey) -> Bool {
        a.channel == b.channel && a.glyph === b.glyph && a.isSelected == b.isSelected
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let glyph {
                    GlyphImage(glyph: glyph, side: 30)
                } else {
                    Text(channel.name.prefix(2)).panelLabel()  // until the icon arrives
                }
            }
            .foregroundStyle(isSelected ? Tone.signal : Tone.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Circle().fill(.signal).frame(width: 4, height: 4)
                        .shadow(color: Color(hex: 0xFF5B1A).opacity(0.7), radius: 2.5)
                        .matchedGeometryEffect(id: "led", in: led)
                        .padding(5)
                }
            }
        }
        .buttonStyle(KeyStyle())
        .frame(width: Metrics.key, height: Metrics.key)
        .onHover { inside in
            if inside { hover.channel = channel } else if hover.channel?.id == channel.id { hover.channel = nil }
        }
        .accessibilityLabel(channel.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Names the key under the pointer.
struct Caption: View {
    let hover: Hover

    var body: some View {
        HStack(spacing: 8) {
            if let channel = hover.channel {
                Text(channel.name).panelLabel().foregroundStyle(.ink)
                Text(channel.show).font(.detail).foregroundStyle(.faint)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
    }
}

struct GlyphImage: View {
    let glyph: NSImage
    let side: CGFloat

    var body: some View {
        Image(nsImage: glyph)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// A flat key: darker under the pointer, darker and smaller while pressed.
struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyFace(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct KeyFace<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            label
                .foregroundStyle(.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(isPressed ? Tone.keyDown : hovering ? Tone.keyHover : Tone.key))
                .contentShape(shape)
                .scaleEffect(isPressed ? 0.95 : 1)
                .animation(.snappy(duration: 0.12), value: isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Sonos Room", selection: $model.room) {
                    ForEach(model.rooms, id: \.self) { Text($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(model.room.isEmpty ? "Sonos" : model.room).panelLabel().foregroundStyle(.ink)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.faint)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sonos room")
            Group {
                if !model.searching, !model.status.isEmpty {
                    Text(model.status)
                        .foregroundStyle(model.statusIsError ? Tone.signal : Tone.faint)
                        .truncationMode(.middle)
                        .help(model.status)
                } else {
                    SonosLamp(state: model.sonosState)
                }
            }
            .panelLabel()
            .foregroundStyle(.faint)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.25), value: model.status)
            Menu {
                Picker("Max Volume", selection: $model.maxVolume) {
                    ForEach([10, 20, 30, 40, 50, 60, 80, 100], id: \.self) { Text("\($0)") }
                }
                Toggle("Bridge on This Mac", isOn: $model.bridgeHere)
                Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
                Divider()
                Button("Quit Atonemo Sonos") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.faint)
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
    }
}

/// What the Sonos room does, in one word. Orange while it plays the player's stream.
struct SonosLamp: View {
    let state: SonosState

    var body: some View {
        if let word {
            HStack(spacing: 5) {
                Circle().fill(state == .ours ? Tone.signal : Tone.unlit).frame(width: 5, height: 5)
                Text(word)
            }
            .transition(.opacity)
        }
    }

    private var word: String? {
        switch state {
        case .unknown: nil
        case .ours: "Playing"
        case .tv: "On TV"
        case .other: "Other audio"
        case .stopped: "Idle"
        case .unreachable: "Offline"
        }
    }
}

// MARK: - Window

/// Tells when its window becomes key (panel opened) or stops being key (panel closed).
struct WindowWatcher: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(onChange: onChange) }
    func updateNSView(_ view: Watcher, context: Context) { view.onChange = onChange }

    final class Watcher: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(isKey) }
                })
            }
            if window.isKeyWindow { onChange(true) }
        }
    }
}
