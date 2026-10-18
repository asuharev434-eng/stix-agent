import Foundation
import Darwin

struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
}

final class ProcessRunner: @unchecked Sendable {
    init() {}
    func run(command: String, directory: String?, timeout: TimeInterval = 120) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0 else { throw AgentError.message("Некорректный таймаут") }
        let state = RunState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                try Self.execute(command: command, directory: directory, timeout: timeout, state: state)
            }.value
        }, onCancel: { state.cancel() })
    }
    private static func execute(command: String, directory: String?, timeout: TimeInterval, state: RunState) throws -> ProcessResult {
        if state.cancelled { throw CancellationError() }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { close(descriptors[0]); if descriptors[1] >= 0 { close(descriptors[1]) } }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        if let directory {
            guard FileManager.default.fileExists(atPath: directory) else { throw AgentError.message("Рабочий каталог не найден") }
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/bin/zsh", "-lc", command].map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        var argv = arguments + [nil]
        let environment = ProcessInfo.processInfo.environment.filter { name, _ in
            name.range(of: "(?i)(key|token|secret|password|credential)", options: .regularExpression) == nil
        }.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, &envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        close(descriptors[1])
        descriptors[1] = -1
        // Nonblocking reads keep cancellation responsive even if descendants retain stdout.
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var collected = Data(), status: Int32 = 0
        var timedOut = false, finished = false
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            while true {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                if count <= 0 { break }
                let remaining = max(0, 120_000 - collected.count)
                if remaining > 0 { collected.append(contentsOf: buffer.prefix(min(count, remaining))) }
            }
        }
        while !finished {
            drain()
            if state.cancelled || Date() >= deadline {
                timedOut = !state.cancelled
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                finished = true
            } else {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { finished = true }
                else if waited == -1 && errno != EINTR { kill(-pid, SIGKILL); throw POSIXError(.ECHILD) }
                else { usleep(10_000) }
            }
        }
        // Clean up background descendants that could otherwise outlive the tool call.
        kill(-pid, SIGKILL)
        drain()
        if state.cancelled { throw CancellationError() }
        let exitCode: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
        let text = String(decoding: collected, as: UTF8.self)
        return ProcessResult(output: String(text.prefix(30_000)), exitCode: exitCode, timedOut: timedOut)
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
