import Foundation

// Reads only numeric usage fields, ids and timestamps from local logs.
// Conversation text, tool inputs/outputs and agent messages are never read.

enum Source: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
    case deepseek = "DeepSeek"
}

struct Usage {
    var fresh = 0        // input tokens not served from cache
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0    // part of output

    var input: Int { fresh + cacheRead + cacheWrite }
    var total: Int { input + output }

    static func + (a: Usage, b: Usage) -> Usage {
        Usage(fresh: a.fresh + b.fresh, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
              output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }
}

struct Turn: Identifiable {
    let id: String
    let source: Source
    let start: Date
    let end: Date
    let usage: Usage
    let durationMs: Double
    let ttftMs: Double?
    let toolMs: Double
    let model: String?

    /// Output speed excluding tool run time.
    var modelSpeed: Double? { speed(durationMs - toolMs) }
    /// Output speed excluding the wait for the first token.
    var generationSpeed: Double? { ttftMs.flatMap { speed(durationMs - $0 - toolMs) } }

    private func speed(_ ms: Double) -> Double? {
        guard usage.output > 0, ms > 250 else { return nil }
        return Double(usage.output) / (ms / 1000)
    }
}

struct RateWindow {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

struct CodexLimits {
    let primary: RateWindow?
    let secondary: RateWindow?
    let plan: String?
    let observedAt: Date
}

// MARK: - Helpers

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
private func dbl(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

/// Incremental line reader: keeps an offset per file and returns only complete new lines.
final class LineTail {
    private var offset: UInt64 = 0
    private var remainder = Data()
    let url: URL
    init(url: URL) { self.url = url }

    func newLines() -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; remainder.removeAll() } // truncated or replaced
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(size - offset)) else { return [] }
        offset = size
        var data = remainder + chunk
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let line = data[data.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            data = data[data.index(after: nl)...]
        }
        remainder = Data(data)
        return lines
    }
}

private func contains(_ line: Data, _ needle: String) -> Bool {
    line.range(of: Data(needle.utf8)) != nil
}

// MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

/// Claude Code transcript format; Qoder CLI writes the same format under ~/.qoder/projects.
final class ClaudeFile {
    let tail: LineTail
    let isMainSession: Bool
    let source: Source
    private var msgUsage: [String: Usage] = [:]
    private var msgModel: [String: String] = [:]
    private var open: Builder?
    private var toolStarts: [String: Date] = [:]

    private struct Builder {
        var id: String
        var start: Date
        var firstReply: Date?
        var lastReply: Date?
        var messageIds: [String] = []
        var toolMs: Double = 0
        var ended = false
    }

    init(url: URL, isMainSession: Bool, source: Source = .claude) {
        tail = LineTail(url: url)
        self.isMainSession = isMainSession
        self.source = source
    }

    private var prefix: String { source == .claude ? "claude-" : "deepseek-" }

    /// Returns finished turns and usage samples (message id, timestamp, usage) for weekly totals.
    func poll() -> (turns: [Turn], samples: [(String, Date, Usage)]) {
        var turns: [Turn] = []
        var samples: [(String, Date, Usage)] = []
        for line in tail.newLines() {
            let isAssistant = contains(line, "\"type\":\"assistant\"")
            let isUser = contains(line, "\"type\":\"user\"")
            guard isAssistant || isUser,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let ts = parseDate(obj["timestamp"]) else { continue }
            let sidechain = (obj["isSidechain"] as? Bool) ?? false
            let message = obj["message"] as? [String: Any] ?? [:]
            let items = (message["content"] as? [[String: Any]]) ?? []

            if (obj["type"] as? String) == "assistant" {
                guard let mid = message["id"] as? String, let u = message["usage"] as? [String: Any] else { continue }
                var usage = Usage()
                usage.fresh = int(u["input_tokens"])
                usage.cacheRead = int(u["cache_read_input_tokens"])
                usage.cacheWrite = int(u["cache_creation_input_tokens"])
                usage.output = int(u["output_tokens"])
                usage.reasoning = int((u["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
                // A message is logged once per content block; keep the latest (largest) counts.
                if let prev = msgUsage[mid], prev.total >= usage.total { usage = prev }
                msgUsage[mid] = usage
                if let model = message["model"] as? String { msgModel[mid] = model }
                samples.append((mid, ts, usage))

                guard isMainSession, !sidechain, var b = open else { continue }
                if !b.messageIds.contains(mid) { b.messageIds.append(mid) }
                if b.firstReply == nil { b.firstReply = ts }
                b.lastReply = ts
                for item in items where (item["type"] as? String) == "tool_use" {
                    if let tid = item["id"] as? String { toolStarts[tid] = ts }
                }
                let stop = message["stop_reason"] as? String
                if let stop, stop != "tool_use", toolStarts.isEmpty { b.ended = true }
                open = b
                if b.ended, let t = finish() { turns.append(t) }
            } else {
                guard isMainSession, !sidechain, (obj["isMeta"] as? Bool) != true else { continue }
                let results = items.filter { ($0["type"] as? String) == "tool_result" }
                if !results.isEmpty {
                    for r in results {
                        if let tid = r["tool_use_id"] as? String, let s = toolStarts.removeValue(forKey: tid), var b = open {
                            b.toolMs += max(0, ts.timeIntervalSince(s) * 1000)
                            open = b
                        }
                    }
                    continue
                }
                // A real prompt starts a new turn.
                if let t = finish() { turns.append(t) }
                toolStarts.removeAll()
                let uid = (obj["uuid"] as? String) ?? UUID().uuidString
                open = Builder(id: prefix + uid, start: ts)
            }
        }
        return (turns, samples)
    }

    private func finish() -> Turn? {
        defer { open = nil }
        guard let b = open, let last = b.lastReply, !b.messageIds.isEmpty else { return nil }
        let usage = b.messageIds.compactMap { msgUsage[$0] }.reduce(Usage(), +)
        let duration = max(0, last.timeIntervalSince(b.start) * 1000)
        let ttft = b.firstReply.map { max(0, $0.timeIntervalSince(b.start) * 1000) }
        return Turn(id: b.id, source: source, start: b.start, end: last, usage: usage, durationMs: duration,
                    ttftMs: ttft, toolMs: min(b.toolMs, duration), model: b.messageIds.last.flatMap { msgModel[$0] })
    }
}

// MARK: - Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

final class CodexFile {
    let tail: LineTail
    private var turnStart: [String: Date] = [:]
    private var turnUsage: [String: Usage] = [:]
    private var turnTool: [String: Double] = [:]
    private var currentTurn: String?
    private var callStart: [String: Date] = [:]
    private var model: String?

    init(url: URL) { tail = LineTail(url: url) }

    func poll() -> (turns: [Turn], limits: CodexLimits?) {
        var turns: [Turn] = []
        var limits: CodexLimits?
        for line in tail.newLines() {
            guard contains(line, "task_started") || contains(line, "task_complete") || contains(line, "token_count")
                    || contains(line, "token_usage_record") || contains(line, "call_id") || contains(line, "turn_context"),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let ts = parseDate(obj["timestamp"]) else { continue }
            let type = obj["type"] as? String
            let p = obj["payload"] as? [String: Any] ?? [:]
            let ptype = p["type"] as? String

            if type == "turn_context", let m = p["model"] as? String { model = m; continue }
            if type == "token_usage_record", let tid = p["turn_id"] as? String,
               let u = p["turn_token_usage"] as? [String: Any] {
                turnUsage[tid] = codexUsage(u)
                continue
            }
            switch ptype {
            case "task_started":
                if let tid = p["turn_id"] as? String {
                    currentTurn = tid
                    turnStart[tid] = ts
                    callStart.removeAll()
                }
            case "token_count":
                if let r = p["rate_limits"] as? [String: Any] {
                    limits = CodexLimits(primary: window(r["primary"]), secondary: window(r["secondary"]),
                                         plan: r["plan_type"] as? String, observedAt: ts)
                }
                // Fallback when token_usage_record is absent: accumulate per-request usage.
                if let tid = currentTurn, let info = p["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any], !hasRecord(tid) {
                    turnUsage["fallback-" + tid] = (turnUsage["fallback-" + tid] ?? Usage()) + codexUsage(last)
                }
            case "function_call", "custom_tool_call", "local_shell_call":
                if let cid = p["call_id"] as? String { callStart[cid] = ts }
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                if let cid = p["call_id"] as? String, let s = callStart.removeValue(forKey: cid), let tid = currentTurn {
                    turnTool[tid, default: 0] += max(0, ts.timeIntervalSince(s) * 1000)
                }
            case "task_complete":
                guard let tid = p["turn_id"] as? String else { continue }
                let start = turnStart[tid] ?? ts
                let duration = dbl(p["duration_ms"]) ?? ts.timeIntervalSince(start) * 1000
                let usage = turnUsage[tid] ?? turnUsage["fallback-" + tid] ?? Usage()
                turns.append(Turn(id: "codex-" + tid, source: .codex, start: start, end: ts, usage: usage,
                                  durationMs: duration, ttftMs: dbl(p["time_to_first_token_ms"]),
                                  toolMs: min(turnTool[tid] ?? 0, duration), model: model))
                turnStart[tid] = nil; turnUsage[tid] = nil; turnUsage["fallback-" + tid] = nil; turnTool[tid] = nil
                if currentTurn == tid { currentTurn = nil }
            default:
                break
            }
        }
        return (turns, limits)
    }

    private func hasRecord(_ tid: String) -> Bool { turnUsage[tid] != nil }

    private func codexUsage(_ u: [String: Any]) -> Usage {
        let input = int(u["input_tokens"]), cached = int(u["cached_input_tokens"]), write = int(u["cache_write_input_tokens"])
        return Usage(fresh: max(0, input - cached - write), cacheRead: cached, cacheWrite: write,
                     output: int(u["output_tokens"]), reasoning: int(u["reasoning_output_tokens"]))
    }

    private func window(_ v: Any?) -> RateWindow? {
        guard let w = v as? [String: Any], let used = dbl(w["used_percent"]) else { return nil }
        let reset = dbl(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return RateWindow(usedPercent: used, windowMinutes: int(w["window_minutes"]), resetsAt: reset)
    }
}

// MARK: - Qoder DeepSeek worker (~/.codex/skills/qoder-delegate/usage.jsonl)

/// Numbers-only records appended by the qoder-delegate bridge, one per worker call.
final class QoderUsageFile {
    let tail: LineTail
    private var counter = 0
    init(url: URL) { tail = LineTail(url: url) }

    func poll() -> [Turn] {
        var turns: [Turn] = []
        for line in tail.newLines() {
            counter += 1
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let stamp = obj["timestamp"] as? String, let end = parseDate(stamp) else { continue }
            let u = obj["usage"] as? [String: Any] ?? [:]
            let usage = Usage(fresh: int(u["input_tokens"]), cacheRead: int(u["cache_read_input_tokens"]),
                              cacheWrite: int(u["cache_creation_input_tokens"]), output: int(u["output_tokens"]), reasoning: 0)
            // Calls that never reached the model (queued, cancelled) carry no tokens.
            guard usage.total > 0 else { continue }
            let duration = dbl(obj["duration_ms"]) ?? 0
            var tool: Double = 0
            if let api = dbl(obj["duration_api_ms"]), duration > 0 { tool = min(duration, max(0, duration - api)) }
            turns.append(Turn(id: "deepseek-worker-\(stamp)-\(counter)", source: .deepseek,
                              start: end.addingTimeInterval(-duration / 1000), end: end, usage: usage,
                              durationMs: duration, ttftMs: nil, toolMs: tool, model: obj["model"] as? String))
        }
        return turns
    }
}

// MARK: - Scanner

/// Watches both log trees. All work happens on its own serial queue.
final class LogScanner {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claude: [String: ClaudeFile] = [:]
    private var codex: [String: CodexFile] = [:]
    private var qoder: [String: ClaudeFile] = [:]
    private var qoderWorker: QoderUsageFile?
    private var claudeSamples: [String: (Date, Usage)] = [:]
    private var deepseekSamples: [String: (Date, Usage)] = [:]
    private(set) var turns: [Turn] = []
    private(set) var limits: CodexLimits?
    private(set) var lastActivity: Date?
    private let lookback: TimeInterval = 8 * 86400

    func poll() {
        let cutoff = Date().addingTimeInterval(-lookback)
        for url in files(under: home.appendingPathComponent(".claude/projects"), newerThan: cutoff) {
            let key = url.path
            if claude[key] == nil {
                // Subagent transcripts live in nested folders; count their tokens, not their turns.
                let depth = url.pathComponents.count - home.appendingPathComponent(".claude/projects").pathComponents.count
                claude[key] = ClaudeFile(url: url, isMainSession: depth == 2)
            }
        }
        let qoderRoot = home.appendingPathComponent(".qoder/projects")
        for url in files(under: qoderRoot, newerThan: cutoff) where qoder[url.path] == nil {
            let depth = url.pathComponents.count - qoderRoot.pathComponents.count
            qoder[url.path] = ClaudeFile(url: url, isMainSession: depth == 2, source: .deepseek)
        }
        let workerLog = home.appendingPathComponent(".codex/skills/qoder-delegate/usage.jsonl")
        if qoderWorker == nil, FileManager.default.fileExists(atPath: workerLog.path) { qoderWorker = QoderUsageFile(url: workerLog) }
        for url in files(under: home.appendingPathComponent(".codex/sessions"), newerThan: cutoff)
        where url.lastPathComponent.hasPrefix("rollout-") {
            if codex[url.path] == nil { codex[url.path] = CodexFile(url: url) }
        }
        var newTurns: [Turn] = []
        for file in claude.values {
            let r = file.poll()
            newTurns += r.turns
            for (mid, ts, usage) in r.samples { claudeSamples[mid] = (ts, usage) }
        }
        for file in qoder.values {
            let r = file.poll()
            newTurns += r.turns
            for (mid, ts, usage) in r.samples { deepseekSamples[mid] = (ts, usage) }
        }
        if let w = qoderWorker { newTurns += w.poll() }
        for file in codex.values {
            let r = file.poll()
            newTurns += r.turns
            if let l = r.limits, l.observedAt >= (limits?.observedAt ?? .distantPast) { limits = l }
        }
        if !newTurns.isEmpty {
            var byId = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for t in newTurns { byId[t.id] = t }
            turns = byId.values.filter { $0.end >= cutoff }.sorted { $0.end > $1.end }
            if let latest = turns.first?.end, latest > (lastActivity ?? .distantPast) { lastActivity = latest }
        }
        claudeSamples = claudeSamples.filter { $0.value.0 >= cutoff }
        deepseekSamples = deepseekSamples.filter { $0.value.0 >= cutoff }
    }

    func deepseekUsage(since: Date) -> Usage {
        let cli = deepseekSamples.values.filter { $0.0 >= since }.map(\.1).reduce(Usage(), +)
        let worker = turns.filter { $0.id.hasPrefix("deepseek-worker-") && $0.end >= since }.map(\.usage).reduce(Usage(), +)
        return cli + worker
    }

    func claudeUsage(since: Date) -> Usage {
        claudeSamples.values.filter { $0.0 >= since }.map(\.1).reduce(Usage(), +)
    }

    func codexUsage(since: Date) -> Usage {
        turns.filter { $0.source == .codex && $0.end >= since }.map(\.usage).reduce(Usage(), +)
    }

    private func files(under root: URL, newerThan cutoff: Date) -> [URL] {
        guard let it = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in it where url.pathExtension == "jsonl" {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if v?.isRegularFile == true, (v?.contentModificationDate ?? .distantPast) >= cutoff { out.append(url) }
        }
        return out
    }
}
