import Foundation
let s = LogScanner()
let t0 = Date(); s.poll(); let dt = Date().timeIntervalSince(t0)
print(String(format: "initial scan %.2fs, turns %d", dt, s.turns.count))
for t in s.turns.prefix(8) {
    print(t.source.rawValue, t.end, "total", t.usage.total, "in", t.usage.input, "out", t.usage.output, "dur", Int(t.durationMs), "ttft", t.ttftMs.map{Int($0)} ?? -1, "tool", Int(t.toolMs), "model/s", t.modelSpeed.map{Int($0)} ?? -1, "gen/s", t.generationSpeed.map{Int($0)} ?? -1)
}
if let l = s.limits { print("codex limits", l.primary?.usedPercent ?? -1, l.primary?.windowMinutes ?? -1, l.secondary?.usedPercent ?? -1, l.secondary?.resetsAt ?? Date.distantPast, l.plan ?? "") }
print("claude 7d", s.claudeUsage(since: Date().addingTimeInterval(-7*86400)).total, "codex 7d", s.codexUsage(since: Date().addingTimeInterval(-7*86400)).total)
let t1 = Date(); s.poll(); print(String(format: "incremental poll %.3fs", Date().timeIntervalSince(t1)))
