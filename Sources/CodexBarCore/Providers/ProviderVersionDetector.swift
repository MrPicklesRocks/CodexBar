import Foundation

public enum ProviderVersionDetector {
    public static func codexVersion() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = BinaryLocator.resolveCodexBinary(env: env, loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which("codex") else { return nil }
        let candidates = [
            ["--version"],
            ["version"],
            ["-v"],
        ]
        return Self.detectVersion(path: path, candidates: candidates)
    }

    public static func geminiVersion() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which("gemini") else { return nil }
        let candidates = [
            ["--version"],
            ["-v"],
        ]
        return Self.detectVersion(path: path, candidates: candidates)
    }

    private static func detectVersion(path: String, candidates: [[String]]) -> String? {
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        // Binary exists but version command output is noisy/unparseable.
        return "installed"
    }

    private static func run(path: String, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning, Date() < deadline {
            usleep(50000)
        }
        if proc.isRunning {
            proc.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning, Date() < killDeadline {
                usleep(20000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let combined = [stdoutText, stderrText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return Self.extractVersionLine(from: combined)
    }

    private static func extractVersionLine(from text: String) -> String? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        let semverPattern = #"\b\d+\.\d+\.\d+\b"#

        for line in lines {
            if line.range(of: semverPattern, options: .regularExpression) != nil {
                return line
            }
        }

        for line in lines where line.count <= 120 {
            if line.localizedCaseInsensitiveContains("version") {
                return line
            }
        }

        return nil
    }
}
