// Renders the overlay views to PNG.
//   render <outdir>        uses your local logs
//   render <outdir> demo   uses made-up demo data only (for README screenshots)
import AppKit
import SwiftUI

@MainActor func render<V: View>(_ v: V, _ name: String, dark: Bool, out: String) {
    let r = ImageRenderer(content: v.environment(\.colorScheme, dark ? .dark : .light)
        .padding(20).background(dark ? Color(white: 0.12) : Color(white: 0.93)))
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let demo = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "demo"
let store = Store()
let settings = Settings()
let now = Date()

func turn(_ id: String, _ s: Source, ago: Double, fresh: Int, cache: Int, out o: Int, reasoning: Int = 0,
          dur: Double, ttft: Double?, tool: Double, model: String) -> Turn {
    Turn(id: id, source: s, start: now.addingTimeInterval(-ago - dur / 1000), end: now.addingTimeInterval(-ago),
         usage: Usage(fresh: fresh, cacheRead: cache, cacheWrite: 0, output: o, reasoning: reasoning),
         durationMs: dur, ttftMs: ttft, toolMs: tool, model: model)
}

if demo {
    store.turns = [
        turn("d1", .claude, ago: 20, fresh: 3_400, cache: 412_000, out: 6_850, reasoning: 900, dur: 118_000, ttft: 3_100, tool: 31_000, model: "claude-model"),
        turn("d2", .codex, ago: 240, fresh: 18_200, cache: 215_000, out: 2_350, reasoning: 410, dur: 74_000, ttft: 2_400, tool: 9_000, model: "codex-model"),
        turn("d3", .deepseek, ago: 600, fresh: 1_200, cache: 3_000, out: 800, dur: 45_000, ttft: nil, tool: 15_000, model: "DeepSeek-Flash"),
        turn("d4", .claude, ago: 1_900, fresh: 900, cache: 188_000, out: 1_240, dur: 22_000, ttft: 2_800, tool: 4_000, model: "claude-model"),
        turn("d5", .codex, ago: 3_600, fresh: 9_800, cache: 96_000, out: 640, dur: 15_400, ttft: 3_000, tool: 6_500, model: "codex-model"),
        turn("d6", .claude, ago: 5_400, fresh: 4_100, cache: 1_920_000, out: 21_400, dur: 410_000, ttft: 3_600, tool: 160_000, model: "claude-model"),
        turn("d7", .deepseek, ago: 7_200, fresh: 2_600, cache: 8_000, out: 1_900, dur: 61_000, ttft: nil, tool: 22_000, model: "DeepSeek-Flash"),
        turn("d8", .codex, ago: 9_000, fresh: 5_200, cache: 44_000, out: 310, dur: 6_100, ttft: 2_100, tool: 0, model: "codex-model"),
    ]
    store.limits = CodexLimits(primary: RateWindow(usedPercent: 34, windowMinutes: 300, resetsAt: now.addingTimeInterval(9_800)),
                               secondary: RateWindow(usedPercent: 21, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(430_000)),
                               plan: "plus", observedAt: now.addingTimeInterval(-60))
    store.claudeWeek = Usage(fresh: 120_000, cacheRead: 41_800_000, cacheWrite: 900_000, output: 312_000, reasoning: 0)
    store.claudeToday = Usage(fresh: 18_000, cacheRead: 6_400_000, cacheWrite: 120_000, output: 46_000, reasoning: 0)
    store.codexWeek = Usage(fresh: 410_000, cacheRead: 12_300_000, cacheWrite: 0, output: 88_000, reasoning: 0)
    store.deepseekWeek = Usage(fresh: 38_000, cacheRead: 95_000, cacheWrite: 0, output: 21_000, reasoning: 0)
} else {
    let s = LogScanner(); s.poll()
    store.turns = s.turns; store.limits = s.limits
    store.claudeWeek = s.claudeUsage(since: now.addingTimeInterval(-7 * 86400))
    store.claudeToday = s.claudeUsage(since: Calendar.current.startOfDay(for: now))
    store.codexWeek = s.codexUsage(since: now.addingTimeInterval(-7 * 86400))
    store.deepseekWeek = s.deepseekUsage(since: now.addingTimeInterval(-7 * 86400))
}
store.loaded = true

MainActor.assumeIsolated {
    for (mode, name) in [(PanelMode.capsule, "capsule"), (.detail, "detail"), (.recent, "recent")] {
        let st = PanelState(); st.mode = mode
        render(CapsuleView(store: store, settings: settings, state: st), name + "-dark", dark: true, out: out)
        render(CapsuleView(store: store, settings: settings, state: st), name + "-light", dark: false, out: out)
    }
}
