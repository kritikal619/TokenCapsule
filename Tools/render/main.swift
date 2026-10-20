import AppKit
import SwiftUI
@MainActor func render<V: View>(_ v: V, _ name: String, dark: Bool) {
    let r = ImageRenderer(content: v.environment(\.colorScheme, dark ? .dark : .light).padding(20).background(dark ? Color(white: 0.12) : Color(white: 0.93)))
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png"))
    }
}
let store = Store(); let settings = Settings()
let s = LogScanner(); s.poll()
store.turns = s.turns; store.limits = s.limits; store.loaded = true
store.claudeWeek = s.claudeUsage(since: Date().addingTimeInterval(-7*86400)); store.codexWeek = s.codexUsage(since: Date().addingTimeInterval(-7*86400))
store.claudeToday = s.claudeUsage(since: Calendar.current.startOfDay(for: Date()))
if CommandLine.arguments.count > 2 {
    let now = Date()
    let sample = Turn(id: "sample-deepseek", source: .deepseek, start: now.addingTimeInterval(-45), end: now.addingTimeInterval(-30),
                      usage: Usage(fresh: 1200, cacheRead: 3000, cacheWrite: 0, output: 800, reasoning: 0), durationMs: 45000, ttftMs: nil, toolMs: 15000, model: "DeepSeek-Flash")
    store.turns = ([sample] + store.turns.map { t in Turn(id: t.id, source: t.source, start: t.start, end: t.source == .codex ? now.addingTimeInterval(-300) : t.end, usage: t.usage, durationMs: t.durationMs, ttftMs: t.ttftMs, toolMs: t.toolMs, model: t.model) }).sorted { $0.end > $1.end }
}
MainActor.assumeIsolated {
for (mode, name) in [(PanelMode.capsule, "capsule"), (.detail, "detail"), (.recent, "recent")] {
    let st = PanelState(); st.mode = mode
    render(CapsuleView(store: store, settings: settings, state: st), name + "-dark", dark: true)
    render(CapsuleView(store: store, settings: settings, state: st), name + "-light", dark: false)
}
}
