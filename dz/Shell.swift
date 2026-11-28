//
//  Shell.swift
//  dz
//
//  Remote terminal. Runs a command on this machine and returns what it said.
//
//  This is deliberately a command-and-output call rather than a live pty: an
//  agent driving a machine needs deterministic text back, not a terminal
//  emulator full of escape sequences. A session that stays open is a separate
//  feature and a much larger one.
//
//  Everything runs with a wall clock limit and a byte limit, because a command
//  that hangs or floods must not take the MCP server with it.
//

import Foundation

enum Shell {
    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var truncated: Bool
    }

    /// Output beyond this is clipped. An agent that needs more should narrow
    /// the command rather than be handed a megabyte.
    static let maxOutputBytes = 256 * 1024

    static func run(_ command: String, timeout: TimeInterval = 30, cwd: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l so the user's PATH and tool setup are present, which is the whole
        // point of running on their machine.
        process.arguments = ["-lc", command]
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // No stdin: a command that waits for input should fail rather than hang
        // until the timeout.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: String(describing: error),
                          timedOut: false, truncated: false)
        }

        var stdoutData = Data()
        var stderrData = Data()
        let collect = DispatchGroup()
        DispatchQueue.global().async(group: collect) {
            stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: collect) {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            // Give it a moment to die, then stop waiting for politeness.
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        _ = collect.wait(timeout: .now() + 2)

        let truncated = stdoutData.count > maxOutputBytes
        if truncated { stdoutData = stdoutData.prefix(maxOutputBytes) }
        if stderrData.count > maxOutputBytes { stderrData = stderrData.prefix(maxOutputBytes) }

        return Result(exitCode: timedOut ? -1 : process.terminationStatus,
                      stdout: String(decoding: stdoutData, as: UTF8.self),
                      stderr: String(decoding: stderrData, as: UTF8.self),
                      timedOut: timedOut,
                      truncated: truncated)
    }
}
