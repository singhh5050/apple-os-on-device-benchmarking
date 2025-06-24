//  apple-os-on-device-benchmarking.swift
//  LLM‑Benchmark‑Demo  ➜ multi‑prompt, multi‑trial benchmarking with progress, outputs & bar charts

import SwiftUI
import Charts
import FoundationModels
import Combine
import OSLog
import Darwin

// MARK: –– Prompt specification
enum Difficulty: String, CaseIterable, Identifiable { case easy, medium, hard ; var id: String { rawValue }
    var order: Int { switch self { case .easy: 0; case .medium: 1; case .hard: 2 } }
}
enum TaskType { case reasoning, generative }

struct PromptSpec: Identifiable, Hashable {
    let id = UUID()
    let difficulty: Difficulty
    let type: TaskType
    let text: String
}

// MARK: –– Prompt bank
private let PROMPT_BANK: [PromptSpec] = [
    // ── REASONING
    .init(difficulty: .easy,   type: .reasoning,  text: "If a recipe needs 2 cups of sugar for one cake, how much for 5 cakes?"),
    .init(difficulty: .medium, type: .reasoning, text: """
        Alice flips a fair coin twice; Bob flips a fair coin three times. Who has the higher probability of getting at least two heads? Calculate both probabilities.
        """),
    .init(difficulty: .hard,   type: .reasoning,  text: """
            Design an O(n log n) algorithm to find the longest increasing subsequence in an array of n integers. \
            Provide pseudocode, a concise proof sketch of its complexity, \
            and outline how you’d parallelise it across two CPU cores.
            """),
    // ── GENERATIVE
    .init(difficulty: .easy,   type: .generative, text: "Write a two-sentence tweet summarising the benefits of daily meditation."),
    .init(difficulty: .medium, type: .generative, text: """
            Compose a 100-word marketing blurb for a new solar-powered backpack that charges your devices on the go.
            """),
    .init(difficulty: .hard,   type: .generative, text: """
            Draft a rigorous grant‐proposal synopsis on catalytic conversion of agricultural waste into biodegradable, high-performance polymers. Structure it into five sections:

            Background & Significance
            Situate this work within current ecological‐materials research and pinpoint the specific gap it fills.

            Hypotheses
            State two or three sharply defined, testable propositions grounded in recent findings.

            Experimental Design & Methods
            Summarize your catalytic pathways, degradation assays, and key analytical techniques (e.g., NMR, GC-MS).

            Preliminary Data & Feasibility
            Present any pilot results or literature precedents validating your approach.

            Impacts & Budget
            Outline scalability, regulatory hurdles, societal benefits, and a succinct line-item budget.

            Include three APA-style scholarly references.
            """)
]

// MARK: –– Benchmark result for a single run
struct BenchmarkResult: Identifiable {
    let id = UUID()
    let prompt: PromptSpec
    let generated: String
    let tokenCount: Int
    let ttftMs: Double
    let latencyMs: Double
    var tps: Double { latencyMs > 0 ? Double(tokenCount) / (latencyMs / 1_000) : 0 }
}

// MARK: –– Prompt that failed + error that bubbled up
struct FailedRun: Identifiable {
    let id = UUID()
    let prompt: PromptSpec
    let message: String        // error.localizedDescription
}

// MARK: –– Statistics helpers
struct Stats { let mean: Double; let sd: Double }
private func stats(_ values: [Double]) -> Stats {
    guard !values.isEmpty else { return .init(mean: 0, sd: 0) }
    let m = values.reduce(0, +) / Double(values.count)
    let varSum = values.reduce(0) { $0 + pow($1 - m, 2) }
    return .init(mean: m, sd: sqrt(varSum / Double(values.count)))
}

struct AggregatedMetrics: Identifiable {
    let id = UUID()
    let prompt: PromptSpec
    let tokens: Stats
    let ttft: Stats
    let latency: Stats
    let tps: Stats
    let sampleOutput: String
}

// MARK: –– Runner
@MainActor
final class BenchmarkRunner: ObservableObject {
    @Published var aggregates: [AggregatedMetrics] = []
    @Published var progress: Double = 0
    @Published var isRunning = false
    @Published var errorMsg: String? = nil
    @Published var csvURL: URL? = nil
    @Published var failureURL: URL? = nil
    @Published var coldStartMode = false
    @Published var failures: [FailedRun] = []
    
    private var session = LanguageModelSession()
    private let log = OSLog(subsystem: "com.harsh.benchmark", category: "Prompt")
    
    private func clearDiskCache() {
        for url in FileManager.default
                    .urls(for: .cachesDirectory, in: .userDomainMask) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    

    func runAll(trials: Int) async {
        // ── Early-exit / reset
        if !coldStartMode { clearDiskCache() }
        guard !isRunning else { return }
        isRunning = true
        errorMsg  = nil
        aggregates = []
        progress   = 0
        csvURL     = nil
        failureURL = nil
        
        // ── Warm-up run (only once, warm mode)
        if !coldStartMode {
            clearDiskCache()
            session = LanguageModelSession()
            _ = try? await runSingle(prompt: PROMPT_BANK[0])
        }
        
        // ── Book-keeping
        let totalRuns = Double(trials * PROMPT_BANK.count)
        var completedRuns = 0.0
        var runLog: [BenchmarkResult] = []
        
        // ── Failure buckets live OUTSIDE the do{ } so we can use them later
        var firstPassFailures: [FailedRun] = []
        var stillFailed:      [FailedRun] = []
        
        do {
            var buckets: [PromptSpec: [BenchmarkResult]] = [:]
            
            // ── 1️⃣ first sweep
            for _ in 0..<trials {
                for prompt in PROMPT_BANK {
                    if coldStartMode { clearDiskCache() }
                    session = LanguageModelSession()
                    do {
                        let r = try await runSingle(prompt: prompt)
                        buckets[prompt, default: []].append(r)
                        runLog.append(r)
                    } catch {
                        firstPassFailures.append(
                            FailedRun(prompt: prompt,
                                      message: error.localizedDescription)
                        )
                    }
                    completedRuns += 1
                    progress = completedRuns / totalRuns
                    _ = try? await Task.sleep(for: .seconds(0.5))
                }
            }
            
            // ── 2️⃣ retry once
            for failure in firstPassFailures {
                session = LanguageModelSession()
                do {
                    let r = try await runSingle(prompt: failure.prompt)
                    buckets[failure.prompt, default: []].append(r)
                } catch {
                    stillFailed.append(
                        FailedRun(prompt: failure.prompt,
                                  message: error.localizedDescription)
                    )
                }
            }
            
            // ── Aggregate successes
            aggregates = buckets.compactMap { spec, results in
                guard !results.isEmpty else { return nil }
                return AggregatedMetrics(
                    prompt: spec,
                    tokens: stats(results.map { Double($0.tokenCount) }),
                    ttft:   stats(results.map { $0.ttftMs }),
                    latency:stats(results.map { $0.latencyMs }),
                    tps:    stats(results.map { $0.tps }),
                    sampleOutput: results.first!.generated
                )
            }
            .sorted {
                $0.prompt.difficulty.order != $1.prompt.difficulty.order ?
                $0.prompt.difficulty.order < $1.prompt.difficulty.order :
                ($0.prompt.type == .reasoning ? 0 : 1) < ($1.prompt.type == .reasoning ? 0 : 1)
            }
            
            // ── Build main CSV
            var csv = "prompt,difficulty,type,tokens,ttftMs,latencyMs,tps\n"
            for r in runLog {
                let p = r.prompt
                csv += "\"\(p.text.replacingOccurrences(of:"\"",with:"\"\""))\","
                + "\(p.difficulty.rawValue),"
                + (p.type == .reasoning ? "reasoning" : "generative") + ","
                + "\(r.tokenCount),"
                + String(format: "%.1f", r.ttftMs) + ","
                + String(format: "%.1f", r.latencyMs) + ","
                + String(format: "%.2f", r.tps) + "\n"
            }
            
            // ── Write both CSVs
            if let docs = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first {
                let outURL = docs.appendingPathComponent("benchmark_results.csv")
                do {
                    try csv.write(to: outURL, atomically: true, encoding: .utf8)
                    
                    // ---- Dump failures CSV
                    let allFailures = firstPassFailures + stillFailed   // local list
                    if !allFailures.isEmpty {
                        var fcsv = "prompt,difficulty,error\n"
                        for f in allFailures {
                            let p = f.prompt
                            fcsv += "\"\(p.text.replacingOccurrences(of:"\"",with:"\"\""))\","
                            + "\(p.difficulty.rawValue),"
                            + "\"\(f.message.replacingOccurrences(of:"\"",with:"\"\""))\"\n"
                        }
                        let failURL = docs.appendingPathComponent("benchmark_failures.csv")
                        try fcsv.write(to: failURL, atomically: true, encoding: .utf8)
                        self.failureURL = failURL                     // ✅ expose to UI
                    } else {
                        self.failureURL = nil
                    }
                    
                    csvURL = outURL
                    os_log("CSV saved at %{public}s", log: log, type: .info, outURL.path)
                } catch {
                    errorMsg = "CSV export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: –– single-prompt run
    private func runSingle(prompt: PromptSpec) async throws -> BenchmarkResult {
        os_signpost(.begin, log: log, name: "LLM Prompt", "%{public}s", prompt.text)

        var tokenCount = 0
        var generated = ""
        let start = Date(); var firstTokenTime: Date? = nil

        let stream = session.streamResponse(to: prompt.text)
        for try await chunk in stream {
            tokenCount += 1
            generated = chunk
            if firstTokenTime == nil { firstTokenTime = Date() }
        }

        let end = Date()
        let latencyMs = end.timeIntervalSince(start) * 1_000
        let ttftMs = (firstTokenTime ?? end).timeIntervalSince(start) * 1_000

        os_signpost(.end, log: log, name: "LLM Prompt")
        return BenchmarkResult(prompt: prompt,
                               generated: generated,
                               tokenCount: tokenCount,
                               ttftMs: ttftMs,
                               latencyMs: latencyMs)
    }
}

// MARK: –– UI
struct ContentView: View {
    @StateObject private var runner = BenchmarkRunner()
    @State private var trials = 3

    // Descriptor for each metric chart
    private let chartMetrics: [(title: String, keyPath: KeyPath<AggregatedMetrics, Stats>)] = [
        ("Latency (ms)", \.latency),
        ("Tokens",       \.tokens),
        ("TTFT (ms)",    \.ttft),
        ("TPS",          \.tps)
    ]

    var body: some View {
        NavigationStack {
            Form {
                // Controls
                Section("Settings") {
                    Toggle("Cold-start every prompt", isOn: $runner.coldStartMode)
                    Stepper("Trials per prompt: \(trials)", value: $trials, in: 1...10)
                    Button("Run Benchmarks") { Task { await runner.runAll(trials: trials) } }
                        .disabled(runner.isRunning)
                }

                // Progress indicator
                if runner.isRunning {
                    Section("Progress") {
                        ProgressView(value: runner.progress)
                    }
                }

                // Results per prompt
                ForEach(runner.aggregates) { agg in
                    Section(header:
                        Text("\(agg.prompt.difficulty.rawValue.capitalized) – " +
                             (agg.prompt.type == .reasoning ? "Reasoning" : "Generative"))
                    ) {
                        Text(agg.prompt.text)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)

                        metric("Tokens", agg.tokens)
                        metric("TTFT (ms)", agg.ttft)
                        metric("Latency (ms)", agg.latency)
                        metric("TPS", agg.tps)

                        DisclosureGroup("Sample Output") {
                            ScrollView {
                                Text(agg.sampleOutput)
                                    .font(.system(.footnote, design: .monospaced))
                            }
                        }
                    }
                }

                // Loop through all metrics to draw bar charts
                if !runner.aggregates.isEmpty {
                    ForEach(chartMetrics, id: \.title) { metricDesc in
                        Section("\(metricDesc.title) – mean ± sd") {
                            Chart {
                                ForEach(runner.aggregates) { agg in
                                    let stats = agg[keyPath: metricDesc.keyPath]
                                    let label = agg.prompt.difficulty.rawValue.capitalized +
                                                (agg.prompt.type == .reasoning ? "-R" : "-G")

                                    BarMark(
                                        x: .value("Prompt", label),
                                        y: .value(metricDesc.title, stats.mean)
                                    )
                                    .annotation(position: .top) {
                                        Text(
                                          String(
                                            format: metricDesc.title == "TPS" ? "%.1f" : "%.0f",
                                            stats.mean
                                          )
                                        )
                                        .font(.caption2)
                                    }
                                    // error‐bar whisker
                                    RuleMark(
                                        x: .value("Prompt", label),
                                        yStart: .value(metricDesc.title, stats.mean - stats.sd),
                                        yEnd:   .value(metricDesc.title, stats.mean + stats.sd)
                                    )
                                }
                            }
                            .frame(height: 200)
                        }
                    }
                }
                
                if !runner.failures.isEmpty {
                                    Section("Failed Prompts") {
                                        ForEach(runner.failures) { f in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(f.prompt.text)
                                                    .font(.footnote)
                                                Text("❌ \(f.message)")
                                                    .font(.caption)
                                                    .foregroundColor(.red)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                }
                
                // Export button
                if let url = runner.csvURL {
                    Section("Export") {
                        ShareLink(item: url,
                                  preview: SharePreview("benchmark_results.csv",
                                                        image: Image(systemName: "square.and.arrow.up")))
                    }
                }
                
                // Export failures CSV
                if let failURL = runner.failureURL {
                  Section("Export Failures") {
                    ShareLink(item: failURL,
                              preview: SharePreview("benchmark_failures.csv",
                                                    image: Image(systemName: "exclamationmark.triangle")))
                  }
                }

                // Error message
                if let e = runner.errorMsg {
                    Section("Error") { Text("❌ " + e) }
                }
            }
            .overlay {  // spinning overlay while benchmarks run
                if runner.isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .navigationTitle("LLM Benchmarks")
        }
    }

    // Helper to render a mean ± sd row
    @ViewBuilder
    private func metric(_ label: String, _ stats: Stats) -> some View {
        let value = String(format: "%.1f ± %.1f", stats.mean, stats.sd)
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }
}


// MARK: –– App entry point
@main
struct LLM_Benchmark_DemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
