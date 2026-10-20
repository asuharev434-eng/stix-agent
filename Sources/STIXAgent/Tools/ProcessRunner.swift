import Foundation
import Darwin

struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
}

final class ProcessRunner: @unchecked Sendable {
    init() {}
    func run(command: String, directory: String?, timeout: TimeInterval = 120, environment: [String: String] = [:]) async throws -> ProcessResult {
        guard timeout.isFinite, timeout > 0 else { throw AgentError.message("Некорректный таймаут") }
        try CredentialEnvironment.validate(environment: environment)
        let state = RunState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                try Self.execute(arguments: ["/bin/zsh", "-lc", command], directory: directory, timeout: timeout, state: state, injectedEnvironment: environment)
            }.value
        }, onCancel: { state.cancel() })
    }
    func runExecutable(_ executable: String, arguments: [String], directory: String?, timeout: TimeInterval = 120, environment: [String:String] = [:],
                       maxOutputBytes: Int = 120_000,
                       onOutput: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> ProcessResult {
        guard executable.hasPrefix("/"), !executable.contains("\0"), arguments.count <= 100, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64000 }), timeout.isFinite, timeout > 0,
              (1...4_000_000).contains(maxOutputBytes) else { throw AgentError.message("Недопустимые аргументы процесса") }
        try CredentialEnvironment.validate(environment: environment)
        let state = RunState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached { try Self.execute(arguments: [executable] + arguments, directory: directory, timeout: timeout, state: state, injectedEnvironment: environment, maxOutputBytes: maxOutputBytes, onOutput: onOutput) }.value
        }, onCancel: { state.cancel() })
    }
    private static func execute(arguments commandArguments: [String], directory: String?, timeout: TimeInterval, state: RunState, injectedEnvironment: [String: String], maxOutputBytes: Int = 120_000,
                                onOutput: @escaping @Sendable (Data) -> Void = { _ in }) throws -> ProcessResult {
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
        let arguments = commandArguments.map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        var argv = arguments + [nil]
        let safeNames: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL", "TERM"]
        var childEnvironment = ProcessInfo.processInfo.environment.filter { safeNames.contains($0.key) }
        childEnvironment.merge(injectedEnvironment) { _, new in new }
        let environment = childEnvironment.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, commandArguments[0], &actions, &attributes, &argv, &envp)
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
                let remaining = max(0, maxOutputBytes - collected.count)
                if remaining > 0 { collected.append(contentsOf: buffer.prefix(min(count, remaining))) }
                onOutput(Data(buffer.prefix(count)))
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
        return ProcessResult(output: String(text.prefix(maxOutputBytes)), exitCode: exitCode, timedOut: timedOut)
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
