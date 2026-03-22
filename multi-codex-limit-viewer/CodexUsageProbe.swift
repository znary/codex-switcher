//
//  CodexUsageProbe.swift
//  multi-codex-limit-viewer
//

import Foundation

private final class ContinuationResumeState: @unchecked Sendable {
    nonisolated(unsafe) var didResume = false

    nonisolated init() {}
}

struct CodexExecutableResolver: Sendable {
    nonisolated func resolve(log: ((String) -> Void)? = nil) throws -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let overriddenPath = environment["CODEX_BINARY_PATH"] {
            log?("Trying CODEX_BINARY_PATH: \(overriddenPath)")
        }

        if let overriddenPath = environment["CODEX_BINARY_PATH"], isExecutable(at: overriddenPath) {
            log?("Resolved codex from CODEX_BINARY_PATH: \(overriddenPath)")
            return URL(fileURLWithPath: overriddenPath)
        }

        let environmentPath = environment["PATH"] ?? ""
        if environmentPath.isEmpty {
            log?("PATH is empty while resolving codex.")
        } else {
            log?("Trying codex from PATH.")
        }

        for directory in environmentPath.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if isExecutable(at: candidate.path) {
                log?("Resolved codex from PATH: \(candidate.path)")
                return candidate
            }
        }

        let commonCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Users/\(NSUserName())/.local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ] + nvmCandidates()

        for candidate in commonCandidates where isExecutable(at: candidate) {
            log?("Resolved codex from fallback path: \(candidate)")
            return URL(fileURLWithPath: candidate)
        }

        let shellResult = try runShellResolution(log: log)
        guard isExecutable(at: shellResult) else {
            log?("Failed to resolve codex after checking PATH, fallback paths, and shell lookup.")
            throw ProbeError.codexBinaryMissing
        }

        log?("Resolved codex from shell lookup: \(shellResult)")
        return URL(fileURLWithPath: shellResult)
    }

    nonisolated private func runShellResolution(log: ((String) -> Void)? = nil) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        log?("Shell lookup exit status: \(process.terminationStatus)")
        if !errorOutput.isEmpty {
            log?("Shell lookup stderr: \(errorOutput)")
        }
        if output.isEmpty {
            log?("Shell lookup returned no codex path.")
        }

        return output
    }

    nonisolated private func nvmCandidates() -> [String] {
        let nvmVersionsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)

        let versionDirectories = (try? FileManager.default.contentsOfDirectory(
            at: nvmVersionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return versionDirectories.map { versionURL in
            versionURL.appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex")
                .path
        }
    }

    nonisolated private func isExecutable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

actor CodexLoginFlow {
    private var activeProcess: Process?

    func login(
        executableURL: URL,
        codexHomeURL: URL,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["login"]
        process.environment = mergedEnvironment(codexHomeURL: codexHomeURL)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        activeProcess = process
        log?("Launching codex login. executable=\(executableURL.path) codexHome=\(codexHomeURL.path)")

        defer {
            if activeProcess === process {
                activeProcess = nil
            }
        }

        do {
            let exitStatus: Int32 = try await withTaskCancellationHandler(operation: {
                try await withTimeout(seconds: 300) {
                    try await withCheckedThrowingContinuation { continuation in
                        let lock = NSLock()
                        let resumeState = ContinuationResumeState()

                        @Sendable func resume(_ result: Result<Int32, Error>) {
                            lock.lock()
                            defer { lock.unlock() }

                            guard !resumeState.didResume else {
                                return
                            }
                            resumeState.didResume = true

                            switch result {
                            case .success(let status):
                                continuation.resume(returning: status)
                            case .failure(let error):
                                continuation.resume(throwing: error)
                            }
                        }

                        process.terminationHandler = { finishedProcess in
                            resume(.success(finishedProcess.terminationStatus))
                        }

                        do {
                            try process.run()
                        } catch {
                            resume(.failure(error))
                        }
                    }
                }
            }, onCancel: {
                Task {
                    await self.cancelActiveLogin()
                }
            })

            let stdout = readPipe(stdoutPipe)
            let stderr = readPipe(stderrPipe)

            if !stdout.isEmpty {
                log?("codex login stdout: \(stdout)")
            }
            if !stderr.isEmpty {
                log?("codex login stderr: \(stderr)")
            }

            guard exitStatus == 0 else {
                throw ProbeError.commandFailed(
                    stderr.isEmpty ? "codex login exited with status \(exitStatus)." : stderr
                )
            }

            let authURL = codexHomeURL.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: authURL.path) else {
                throw ProbeError.invalidResponse("codex login finished but no auth.json was created.")
            }
        } catch is CancellationError {
            terminateIfRunning(process)
            throw CancellationError()
        } catch ProbeError.timedOut {
            terminateIfRunning(process)
            throw ProbeError.loginTimedOut
        } catch {
            terminateIfRunning(process)
            throw error
        }
    }

    func cancelActiveLogin() {
        guard let activeProcess else {
            return
        }

        if self.activeProcess === activeProcess {
            self.activeProcess = nil
        }
        terminateIfRunning(activeProcess)
    }

    nonisolated private func mergedEnvironment(codexHomeURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        return environment
    }

    nonisolated private func terminateIfRunning(_ process: Process) {
        guard process.isRunning else {
            return
        }

        process.terminate()

        if process.isRunning {
            process.interrupt()
        }
    }

    nonisolated private func readPipe(_ pipe: Pipe) -> String {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CodexUsageProbe: Sendable {
    nonisolated func fetchSnapshot(
        executableURL: URL,
        codexHomeURL: URL,
        workspaceID: String?,
        log: ((String) -> Void)? = nil
    ) async throws -> ProbeResult {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments(for: workspaceID)
        process.environment = mergedEnvironment(codexHomeURL: codexHomeURL)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        log?("Launching codex probe. executable=\(executableURL.path) workspace=\(workspaceID ?? "default") codexHome=\(codexHomeURL.path)")
        try process.run()

        let stderrTask = Task.detached(priority: .utility) {
            let data = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        let responseTask = Task.detached(priority: .userInitiated) { [stdinPipe, stdoutPipe] in
            try Self.writeJSONLine(
                [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "multi-codex-limit-viewer",
                            "title": "Multi Codex Limit Viewer",
                            "version": "1.0"
                        ],
                        "capabilities": [
                            "experimentalApi": true
                        ]
                    ]
                ],
                to: stdinPipe.fileHandleForWriting
            )

            var accountResult: [String: Any]?
            var rateLimitResult: [String: Any]?

            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8) else {
                    continue
                }

                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let payload else {
                    continue
                }

                if let id = payload["id"] as? Int, id == 1 {
                    try Self.writeJSONLine(
                        [
                            "jsonrpc": "2.0",
                            "method": "initialized"
                        ],
                        to: stdinPipe.fileHandleForWriting
                    )

                    try Self.writeJSONLine(
                        [
                            "jsonrpc": "2.0",
                            "id": 2,
                            "method": "account/read",
                            "params": [
                                "refreshToken": false
                            ]
                        ],
                        to: stdinPipe.fileHandleForWriting
                    )

                    try Self.writeJSONLine(
                        [
                            "jsonrpc": "2.0",
                            "id": 3,
                            "method": "account/rateLimits/read"
                        ],
                        to: stdinPipe.fileHandleForWriting
                    )
                    continue
                }

                if let id = payload["id"] as? Int, let result = payload["result"] as? [String: Any] {
                    if id == 2 {
                        accountResult = result
                    } else if id == 3 {
                        rateLimitResult = result
                    }
                }

                if let accountResult, let rateLimitResult {
                    return try Self.parseResult(account: accountResult, rateLimits: rateLimitResult)
                }
            }

            throw ProbeError.connectionClosed
        }

        do {
            let probeResult = try await withTimeout(seconds: 8) {
                try await responseTask.value
            }
            if process.isRunning {
                process.terminate()
            }
            _ = try? await stderrTask.value
            log?("Probe succeeded. email=\(probeResult.email) meters=\(probeResult.snapshot.meters.count)")
            return probeResult
        } catch {
            if process.isRunning {
                process.terminate()
            }
            let stderr = (try? await stderrTask.value) ?? ""
            if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log?("Probe stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                throw ProbeError.commandFailed(stderr)
            }
            log?("Probe failed: \(error.localizedDescription)")
            throw error
        }
    }

    nonisolated private func arguments(for workspaceID: String?) -> [String] {
        var arguments: [String] = ["-s", "read-only", "-a", "never"]

        if let workspaceID, !workspaceID.isEmpty {
            arguments.append(contentsOf: ["-c", "forced_chatgpt_workspace_id=\"\(workspaceID)\""])
        }

        arguments.append("app-server")
        return arguments
    }

    nonisolated private func mergedEnvironment(codexHomeURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        return environment
    }

    nonisolated private static func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    nonisolated private static func parseResult(
        account: [String: Any],
        rateLimits: [String: Any]
    ) throws -> ProbeResult {
        guard
            let accountPayload = account["account"] as? [String: Any],
            let email = accountPayload["email"] as? String
        else {
            throw ProbeError.invalidResponse("Missing account email.")
        }

        let rawPlan = accountPayload["planType"] as? String
        let rateLimitPayload = (
            ((rateLimits["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
            ?? (rateLimits["rateLimits"] as? [String: Any])
        )

        guard let rateLimitPayload else {
            throw ProbeError.invalidResponse("Missing rate limit payload.")
        }

        let meters = [
            parseMeter(id: "primary", payload: rateLimitPayload["primary"] as? [String: Any]),
            parseMeter(id: "secondary", payload: rateLimitPayload["secondary"] as? [String: Any])
        ]
        .compactMap { $0 }
        .sorted { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }

        guard !meters.isEmpty else {
            throw ProbeError.invalidResponse("Rate limit payload did not contain any windows.")
        }

        return ProbeResult(
            email: email,
            plan: PlanBadge(rawPlan: (rateLimitPayload["planType"] as? String) ?? rawPlan),
            workspaces: parseWorkspaces(from: accountPayload),
            snapshot: UsageSnapshot(
                capturedAt: Date(),
                meters: meters,
                plan: PlanBadge(rawPlan: (rateLimitPayload["planType"] as? String) ?? rawPlan)
            )
        )
    }

    nonisolated private static func parseMeter(id: String, payload: [String: Any]?) -> UsageMeter? {
        guard let payload, let usedPercent = number(from: payload["usedPercent"]) else {
            return nil
        }

        let durationMinutes = Int(number(from: payload["windowDurationMins"]) ?? 0)
        let resetsAtSeconds = number(from: payload["resetsAt"])
        return UsageMeter(
            id: id,
            title: title(for: durationMinutes),
            usedPercent: usedPercent,
            windowDurationMinutes: durationMinutes == 0 ? nil : durationMinutes,
            resetsAt: resetsAtSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    nonisolated private static func parseWorkspaces(from accountPayload: [String: Any]) -> [StoredWorkspace]? {
        let rawWorkspaces = (
            accountPayload["organizations"] as? [[String: Any]]
            ?? accountPayload["workspaces"] as? [[String: Any]]
            ?? (accountPayload["workspaceInfo"] as? [String: Any])?["organizations"] as? [[String: Any]]
            ?? (accountPayload["workspaceInfo"] as? [String: Any])?["workspaces"] as? [[String: Any]]
        )

        guard let rawWorkspaces else {
            return nil
        }

        let workspaces = rawWorkspaces.compactMap(parseWorkspace)
        guard !workspaces.isEmpty else {
            return nil
        }

        return workspaces.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault && !$1.isDefault
            }
            return $0.menuLabel.localizedCaseInsensitiveCompare($1.menuLabel) == .orderedAscending
        }
    }

    nonisolated private static func parseWorkspace(from payload: [String: Any]) -> StoredWorkspace? {
        guard
            let id = (payload["id"] as? String) ?? (payload["workspaceId"] as? String),
            !id.isEmpty
        else {
            return nil
        }

        let title = ((payload["title"] as? String) ?? (payload["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let role = payload["role"] as? String
        let isDefault = boolean(from: payload["isDefault"]) ?? boolean(from: payload["is_default"]) ?? false
        let kind: WorkspaceKind

        if let rawKind = (payload["kind"] as? String)?.lowercased(),
           let parsedKind = WorkspaceKind(rawValue: rawKind) {
            kind = parsedKind
        } else {
            kind = WorkspaceKind(title: title)
        }

        return StoredWorkspace(
            id: id,
            title: title.isEmpty ? kind.displayTitle : title,
            kind: kind,
            role: role,
            isDefault: isDefault
        )
    }

    nonisolated private static func title(for durationMinutes: Int) -> String {
        switch durationMinutes {
        case 300:
            return "5 Hours"
        case 1_440:
            return "Daily"
        case 10_080:
            return "Weekly"
        default:
            if durationMinutes > 0 {
                return "\(durationMinutes)m"
            }
            return "Usage"
        }
    }

    nonisolated private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        default:
            return nil
        }
    }

    nonisolated private static func boolean(from value: Any?) -> Bool? {
        switch value {
        case let boolean as Bool:
            return boolean
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return NSString(string: string).boolValue
        default:
            return nil
        }
    }
}

enum ProbeError: LocalizedError, Sendable {
    case codexBinaryMissing
    case invalidResponse(String)
    case connectionClosed
    case commandFailed(String)
    case timedOut
    case loginTimedOut

    var errorDescription: String? {
        switch self {
        case .codexBinaryMissing:
            return "Could not resolve the codex executable. Set CODEX_BINARY_PATH or add codex to PATH."
        case .invalidResponse(let message):
            return message
        case .connectionClosed:
            return "codex app-server closed before returning usage data."
        case .commandFailed(let stderr):
            return stderr
        case .timedOut:
            return "Timed out while waiting for codex usage data."
        case .loginTimedOut:
            return "Timed out while waiting for codex browser login to finish."
        }
    }
}

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ProbeError.timedOut
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
