import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Settings

enum ShowMode: String { case always, whenActive }

final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var showMode: ShowMode { didSet { d.set(showMode.rawValue, forKey: "showMode") } }
    @Published var showModelSpeed: Bool { didSet { d.set(showModelSpeed, forKey: "showModelSpeed") } }
    @Published var showGenerationSpeed: Bool { didSet { d.set(showGenerationSpeed, forKey: "showGenerationSpeed") } }
    /// Floating capsule on the screen. Off by default; the menu-bar panel is the main view.
    @Published var floating: Bool { didSet { d.set(floating, forKey: "floating") } }
    /// One row per model used recently (default) instead of only the latest turn.
    @Published var perSource: Bool { didSet { d.set(perSource, forKey: "perSource") } }

    init() {
        showMode = ShowMode(rawValue: d.string(forKey: "showMode") ?? "") ?? .whenActive
        showModelSpeed = d.object(forKey: "showModelSpeed") as? Bool ?? true
        showGenerationSpeed = d.object(forKey: "showGenerationSpeed") as? Bool ?? true
        floating = d.bool(forKey: "floating")
        perSource = d.object(forKey: "perSource") as? Bool ?? true
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var turns: [Turn] = []
    @Published var limits: CodexLimits?
    @Published var claudeWeek = Usage()
    @Published var claudeToday = Usage()
    @Published var codexWeek = Usage()
    @Published var deepseekWeek = Usage()
    @Published var lastActivity: Date?
    @Published var loaded = false

    private let scanner = LogScanner()
    private let queue = DispatchQueue(label: "tokencapsule.scan", qos: .utility)
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        queue.async { [scanner] in
            scanner.poll()
            let now = Date()
            let week = now.addingTimeInterval(-7 * 86400)
            let today = Calendar.current.startOfDay(for: now)
            let snapshot = (scanner.turns, scanner.limits, scanner.claudeUsage(since: week),
                            scanner.claudeUsage(since: today), scanner.codexUsage(since: week), scanner.lastActivity)
            let deepseek = scanner.deepseekUsage(since: week)
            DispatchQueue.main.async {
                self.turns = snapshot.0; self.limits = snapshot.1; self.claudeWeek = snapshot.2
                self.claudeToday = snapshot.3; self.codexWeek = snapshot.4; self.lastActivity = snapshot.5
                self.deepseekWeek = deepseek
                self.loaded = true
            }
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.2fM", Double(n) / 1_000_000)
        case 10_000...: return String(format: "%.0fk", Double(n) / 1000)
        case 1000...: return String(format: "%.1fk", Double(n) / 1000)
        default: return "\(n)"
        }
    }
    static func duration(_ ms: Double) -> String {
        let s = Int((ms / 1000).rounded())
        if s < 60 { return "\(s)초" }
        if s < 3600 { return "\(s / 60)분 \(s % 60)초" }
        return "\(s / 3600)시간 \((s % 3600) / 60)분"
    }
    static func speed(_ v: Double?) -> String { v.map { String(format: "%.0f t/s", $0) } ?? "—" }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }
    static func reset(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "초기화됨" }
        if s < 3600 { return "\(s / 60)분 후 초기화" }
        if s < 86400 { return "\(s / 3600)시간 \((s % 3600) / 60)분 후 초기화" }
        return "\(s / 86400)일 \((s % 86400) / 3600)시간 후 초기화"
    }
}

extension Source {
    var color: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.36, green: 0.62, blue: 0.98)
        case .deepseek: return Color(red: 0.55, green: 0.42, blue: 0.98)
        }
    }
}

// MARK: - Views

enum PanelMode { case capsule, detail, recent }

final class PanelState: ObservableObject {
    @Published var mode: PanelMode = .capsule
}

/// Latest turn per model (or only the latest turn), shared by the popover and the floating capsule.
struct TurnRowsView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings

    /// The latest overall, plus (per-source mode) the latest turn of every other model
    /// used in the last 15 minutes, newest first.
    static func shown(_ store: Store, _ settings: Settings) -> [Turn] {
        guard let latest = store.turns.first else { return [] }
        guard settings.perSource else { return [latest] }
        let recent = Date().addingTimeInterval(-15 * 60)
        return Source.allCases.compactMap { s in store.turns.first { $0.source == s } }
            .filter { $0.id == latest.id || $0.end >= recent }
            .sorted { $0.end > $1.end }
    }

    var body: some View {
        let turns = Self.shown(store, settings)
        VStack(alignment: .leading, spacing: 6) {
            if turns.isEmpty {
                HStack(spacing: 10) {
                    Circle().fill(Color.gray).frame(width: 8, height: 8)
                    Text(store.loaded ? "최근 7일 기록 없음" : "기록 읽는 중…").font(.system(size: 12))
                }
            }
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, t in
                if index > 0 { Divider().opacity(0.5) }
                turnRow(t, nameWidth: turns.count > 1 ? 62 : nil)
            }
        }
    }

    private func turnRow(_ t: Turn, nameWidth: CGFloat?) -> some View {
        HStack(spacing: 10) {
            Circle().fill(t.source.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.source.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.source.color)
                        .frame(width: nameWidth, alignment: .leading)
                    Text(Fmt.tokens(t.usage.total)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    Text("토큰").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(Fmt.duration(t.durationMs)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                if settings.showModelSpeed || settings.showGenerationSpeed {
                    HStack(spacing: 10) {
                        if let w = nameWidth { Color.clear.frame(width: w, height: 1) }
                        if settings.showModelSpeed { speedLabel("모델", t.modelSpeed) }
                        if settings.showGenerationSpeed { speedLabel("생성", t.generationSpeed) }
                    }
                }
            }
        }
    }

    private func speedLabel(_ name: String, _ v: Double?) -> some View {
        HStack(spacing: 3) {
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(Fmt.speed(v)).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}

/// Optional floating capsule (click: detail, Ctrl+hover: weekly and recent).
struct CapsuleView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings
    @ObservedObject var state: PanelState

    var body: some View {
        let multi = TurnRowsView.shown(store, settings).count > 1
        VStack(alignment: .leading, spacing: 8) {
            TurnRowsView(store: store, settings: settings)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: multi ? 16 : 22))
                .overlay(RoundedRectangle(cornerRadius: multi ? 16 : 22).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { state.mode = state.mode == .detail ? .capsule : .detail } }
                .help("클릭: 마지막 턴 자세히 · Ctrl을 누른 채 올리기: 최근 기록·주간 사용량")
            if state.mode == .detail, let t = store.turns.first { DetailView(turn: t).transition(.opacity) }
            if state.mode == .recent { RecentView(store: store).transition(.opacity) }
        }
        .padding(8)
        .fixedSize()
    }
}

/// Panel opened from the menu-bar icon.
struct PopoverView: View {
    enum Tab: Hashable { case turn, week }
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings
    @State var tab: Tab = .turn
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TokenCapsule").font(.system(size: 13, weight: .bold))
                Spacer()
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(4).contentShape(Rectangle()).onTapGesture(perform: openSettings).help("설정")
            }
            TurnRowsView(store: store, settings: settings)
                .padding(12)
                .frame(width: 300, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            // Drawn in SwiftUI (not NSSegmentedControl) so it also renders offscreen.
            HStack(spacing: 2) {
                segment("이번 턴", .turn)
                segment("주간·기록", .week)
            }
            .padding(2)
            .frame(width: 300)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            if tab == .turn {
                if let t = store.turns.first { DetailView(turn: t) }
                else { Text("아직 기록이 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary) }
            } else {
                RecentView(store: store)
            }
        }
        .padding(12)
        .fixedSize()
    }

    private func segment(_ title: String, _ value: Tab) -> some View {
        Text(title)
            .font(.system(size: 12, weight: tab == value ? .semibold : .regular))
            .frame(maxWidth: .infinity).padding(.vertical, 4)
            .background(tab == value ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { tab = value }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(12)
            .frame(width: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

struct Row: View {
    let label: String; let value: String
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
    }
}

struct DetailView: View {
    let turn: Turn
    var body: some View {
        Card {
            HStack {
                Text("이번 턴").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(turn.source.rawValue) · \(Fmt.clock(turn.end))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let m = turn.model { Text(m).font(.system(size: 11)).foregroundStyle(.secondary) }
            Divider()
            Row(label: "입력(새로)", value: Fmt.tokens(turn.usage.fresh))
            Row(label: "입력(캐시 읽기)", value: Fmt.tokens(turn.usage.cacheRead))
            if turn.usage.cacheWrite > 0 { Row(label: "입력(캐시 쓰기)", value: Fmt.tokens(turn.usage.cacheWrite)) }
            Row(label: "출력", value: Fmt.tokens(turn.usage.output))
            if turn.usage.reasoning > 0 { Row(label: "  그중 생각", value: Fmt.tokens(turn.usage.reasoning)) }
            Row(label: "합계", value: Fmt.tokens(turn.usage.total))
            Divider()
            Row(label: "걸린 시간", value: Fmt.duration(turn.durationMs))
            if let f = turn.ttftMs { Row(label: "첫 토큰까지", value: Fmt.duration(f)) }
            Row(label: "도구 실행", value: Fmt.duration(turn.toolMs))
            Row(label: "모델 속도(도구 제외)", value: Fmt.speed(turn.modelSpeed))
            Row(label: "생성 속도(첫 토큰 대기 제외)", value: Fmt.speed(turn.generationSpeed))
            if turn.source == .claude {
                Text("Claude 시간은 응답이 기록된 시각 기준이라 첫 토큰·속도는 추정값입니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct RecentView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Card {
                Text("주간 사용량").font(.system(size: 13, weight: .bold))
                if let l = store.limits {
                    if let p = l.primary { LimitBar(title: "Codex \(p.windowMinutes / 60)시간", window: p) }
                    if let s = l.secondary { LimitBar(title: "Codex 주간", window: s) }
                    Text("Codex 기록 기준 · \(Fmt.ago(l.observedAt)) 갱신\(l.plan.map { " · \($0)" } ?? "")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("Codex 한도 기록 없음").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                Row(label: "Claude 최근 7일", value: "\(Fmt.tokens(store.claudeWeek.total)) (출력 \(Fmt.tokens(store.claudeWeek.output)))")
                Row(label: "Claude 오늘", value: "\(Fmt.tokens(store.claudeToday.total)) (출력 \(Fmt.tokens(store.claudeToday.output)))")
                Row(label: "Codex 최근 7일", value: "\(Fmt.tokens(store.codexWeek.total)) (출력 \(Fmt.tokens(store.codexWeek.output)))")
                Row(label: "DeepSeek 최근 7일", value: "\(Fmt.tokens(store.deepseekWeek.total)) (출력 \(Fmt.tokens(store.deepseekWeek.output)))")
                Text("Claude·DeepSeek는 로그에 한도 비율이 없어 토큰 합계만 표시합니다.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Card {
                Text("최근 턴").font(.system(size: 13, weight: .bold))
                if store.turns.isEmpty { Text("기록 없음").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(store.turns.prefix(8)) { t in
                    HStack(spacing: 8) {
                        Circle().fill(t.source.color).frame(width: 6, height: 6)
                        Text(Fmt.clock(t.end)).foregroundStyle(.secondary)
                        Text(Fmt.tokens(t.usage.total)).frame(width: 52, alignment: .trailing)
                        Text(Fmt.duration(t.durationMs)).frame(width: 66, alignment: .trailing).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.speed(t.modelSpeed))
                    }
                    .font(.system(size: 11)).monospacedDigit()
                }
            }
        }
    }
}

struct LimitBar: View {
    let title: String; let window: RateWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(String(format: "%.0f%% 사용", window.usedPercent)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(window.usedPercent >= 80 ? Color.orange : Source.codex.color)
                        .frame(width: g.size.width * min(1, max(0, window.usedPercent / 100)))
                }
            }.frame(height: 5)
            Text(Fmt.reset(window.resetsAt)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class OverlayController {
    let store: Store
    let settings: Settings
    let state = PanelState()
    let panel: OverlayPanel
    private var hosting: NSHostingView<CapsuleView>!
    private var hoverTimer: Timer?

    init(store: Store, settings: Settings) {
        self.store = store; self.settings = settings
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        hosting = NSHostingView(rootView: CapsuleView(store: store, settings: settings, state: state))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        placeInitially()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let f = self?.panel.frame else { return }
            UserDefaults.standard.set([f.minX, f.maxY], forKey: "panelTopLeft")
        }
        // Keep the top-left corner fixed while the content grows or shrinks.
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: hosting, queue: .main) { [weak self] _ in
            self?.fitToContent()
        }
        hosting.postsFrameChangedNotifications = true
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func placeInitially() {
        let size = hosting.fittingSize
        if let saved = UserDefaults.standard.array(forKey: "panelTopLeft") as? [Double], saved.count == 2,
           NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: saved[0] + 10, y: saved[1] - 10)) }) {
            panel.setFrame(NSRect(x: saved[0], y: saved[1] - size.height, width: size.width, height: size.height), display: true)
        } else {
            resetPosition()
        }
    }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let size = hosting.fittingSize
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.maxY - size.height - 6, width: size.width, height: size.height), display: true)
        UserDefaults.standard.set([panel.frame.minX, panel.frame.maxY], forKey: "panelTopLeft")
    }

    private func fitToContent() {
        let size = hosting.fittingSize
        let top = panel.frame.maxY
        if abs(size.width - panel.frame.width) > 0.5 || abs(size.height - panel.frame.height) > 0.5 {
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        }
    }

    private func tick() {
        updateVisibility()
        guard panel.isVisible else { return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        let ctrl = NSEvent.modifierFlags.contains(.control)
        if inside && ctrl, state.mode != .recent {
            withAnimation(.easeOut(duration: 0.15)) { state.mode = .recent }
        } else if state.mode == .recent && !(inside && ctrl) {
            withAnimation(.easeOut(duration: 0.15)) { state.mode = .capsule }
        }
        fitToContent()
    }

    private func updateVisibility() {
        let show: Bool
        if !settings.floating { show = false }
        else if settings.showMode == .always { show = true }
        else {
            let ids: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex", "com.qoder.ide"]
            let appOpen = NSWorkspace.shared.runningApplications.contains { ids.contains($0.bundleIdentifier ?? "") }
            let recent = store.lastActivity.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
            show = appOpen || recent
        }
        if show && !panel.isVisible { panel.orderFrontRegardless() }
        if !show && panel.isVisible { panel.orderOut(nil) }
    }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let settings = Settings()
    var overlay: OverlayController!
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let settingsMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        overlay = OverlayController(store: store, settings: settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "TokenCapsule")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        settingsMenu.delegate = self
        let host = NSHostingController(rootView: PopoverView(store: store, settings: settings) { [weak self] in self?.showSettings() })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateTitle() }
    }

    /// Left click: panel. Right click (or Ctrl-click): settings menu.
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showSettings(); return }
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showSettings() {
        popover.performClose(nil)
        statusItem.menu = settingsMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func updateTitle() {
        guard let t = store.turns.first else { statusItem.button?.title = ""; return }
        statusItem.button?.title = " " + Fmt.tokens(t.usage.total)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let t = store.turns.first {
            info(menu, "마지막 턴: \(t.source.rawValue) \(Fmt.tokens(t.usage.total)) 토큰 · \(Fmt.duration(t.durationMs)) · \(Fmt.ago(t.end))")
        } else {
            info(menu, store.loaded ? "최근 7일 기록 없음" : "기록 읽는 중…")
        }
        if let s = store.limits?.secondary { info(menu, String(format: "Codex 주간 %.0f%% 사용 · %@", s.usedPercent, Fmt.reset(s.resetsAt))) }
        if let p = store.limits?.primary { info(menu, String(format: "Codex %d시간 %.0f%% 사용", p.windowMinutes / 60, p.usedPercent)) }
        info(menu, "Claude 최근 7일 \(Fmt.tokens(store.claudeWeek.total)) 토큰")
        info(menu, "DeepSeek(Qoder) 최근 7일 \(Fmt.tokens(store.deepseekWeek.total)) 토큰")
        menu.addItem(.separator())

        let float = add(menu, "화면 위 캡슐 띄우기", #selector(toggleFloating)); float.state = settings.floating ? .on : .off
        if settings.floating {
            let always = add(menu, "    항상 표시", #selector(setAlways)); always.state = settings.showMode == .always ? .on : .off
            let active = add(menu, "    Claude·Codex·Qoder 사용 중일 때만", #selector(setActive)); active.state = settings.showMode == .whenActive ? .on : .off
            add(menu, "    캡슐 위치 초기화", #selector(resetPosition))
        }
        menu.addItem(.separator())
        let per = add(menu, "모델별로 보기 (최근 15분)", #selector(setPerSource)); per.state = settings.perSource ? .on : .off
        let single = add(menu, "최근 턴 하나만 보기", #selector(setSingle)); single.state = settings.perSource ? .off : .on
        menu.addItem(.separator())
        let m = add(menu, "모델 속도 줄 표시", #selector(toggleModel)); m.state = settings.showModelSpeed ? .on : .off
        let g = add(menu, "생성 속도 줄 표시", #selector(toggleGen)); g.state = settings.showGenerationSpeed ? .on : .off
        menu.addItem(.separator())
        let login = add(menu, "로그인 시 자동 실행", #selector(toggleLogin)); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add(menu, "지금 새로 읽기", #selector(refresh))
        menu.addItem(.separator())
        info(menu, "아이콘 클릭: 패널 열기 · 우클릭: 이 설정")
        add(menu, "TokenCapsule 종료", #selector(quit)).keyEquivalent = "q"
    }

    private func info(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }

    @objc func toggleFloating() { settings.floating.toggle() }
    @objc func setAlways() { settings.showMode = .always }
    @objc func setActive() { settings.showMode = .whenActive }
    @objc func toggleModel() { settings.showModelSpeed.toggle() }
    @objc func setPerSource() { settings.perSource = true }
    @objc func setSingle() { settings.perSource = false }
    @objc func toggleGen() { settings.showGenerationSpeed.toggle() }
    @objc func resetPosition() { overlay.resetPosition() }
    @objc func refresh() { store.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(); alert.messageText = "자동 실행 설정 실패"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
}

