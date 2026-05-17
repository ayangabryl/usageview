import Foundation

/// Runs `kiro-cli chat --no-interactive /usage` and parses quota output (CodexBar-compatible).
enum KiroCLIUsageProbe {
    struct Snapshot: Sendable {
        var planName: String
        var creditsUsed: Double
        var creditsTotal: Double
        var creditsPercent: Double
        var resetsAt: Date?
    }

    static func isCLIAvailable() -> Bool {
        resolveBinary() != nil
    }

    static func fetchUsage() async -> Snapshot? {
        guard let binary = resolveBinary() else { return nil }

        do {
            let output = try await runUsageCommand(binary: binary)
            return parse(output: output)
        } catch {
            return nil
        }
    }

    private static func resolveBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/kiro-cli", "/usr/local/bin/kiro-cli"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["kiro-cli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private static func runUsageCommand(binary: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["chat", "--no-interactive", "/usage"]
                process.standardInput = FileHandle.nullDevice

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                var env = ProcessInfo.processInfo.environment
                env["TERM"] = "xterm-256color"
                process.environment = env

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let deadline = Date().addingTimeInterval(12)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                }

                let out = String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let err = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let combined = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? err : out
                continuation.resume(returning: combined)
            }
        }
    }

    private static func parse(output: String) -> Snapshot? {
        let text = stripANSI(output)
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("kiro-cli login") {
            return nil
        }

        var planName = "Kiro"
        if let match = text.range(of: #"\|\s*(KIRO\s+\w+)"#, options: .regularExpression) {
            planName = String(text[match])
                .replacingOccurrences(of: "|", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        var creditsPercent: Double = 0
        var creditsUsed: Double = 0
        var creditsTotal: Double = 50

        if let percentMatch = text.range(of: #"█+\s*(\d+)%"#, options: .regularExpression) {
            let chunk = String(text[percentMatch])
            if let num = chunk.range(of: #"\d+"#, options: .regularExpression) {
                creditsPercent = Double(String(chunk[num])) ?? 0
            }
        }

        let creditsPattern = #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#
        if let creditsMatch = text.range(of: creditsPattern, options: .regularExpression) {
            let chunk = String(text[creditsMatch])
            let numbers = chunk.matches(of: /(\d+\.?\d*)/)
            if numbers.count >= 2 {
                creditsUsed = Double(String(numbers[0].output.1)) ?? 0
                creditsTotal = Double(String(numbers[1].output.1)) ?? 50
            }
        }
        if creditsPercent == 0, creditsTotal > 0 {
            creditsPercent = (creditsUsed / creditsTotal) * 100
        }

        guard creditsPercent > 0 || creditsUsed > 0 else { return nil }

        var resetsAt: Date?
        if let resetMatch = text.range(
            of: #"resets?\s+on\s+(\d{4}-\d{2}-\d{2})"#,
            options: .regularExpression
        ) {
            let chunk = String(text[resetMatch])
            if let dateStr = chunk.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                resetsAt = formatter.date(from: String(chunk[dateStr]))
            }
        }

        return Snapshot(
            planName: planName,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsPercent: creditsPercent,
            resetsAt: resetsAt
        )
    }

    private static func stripANSI(_ text: String) -> String {
        let pattern = #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}
