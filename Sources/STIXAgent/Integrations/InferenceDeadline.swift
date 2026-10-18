import Foundation

/// Monotonic deadlines include model loading, semantic stream stalls and endless
/// token streams. SSE keep-alive bytes do not reset the progress deadline.
final class InferenceDeadline: @unchecked Sendable {
    struct Limits: Sendable {
        var firstProgress: TimeInterval = 120
        var stalledProgress: TimeInterval = 60
        var total: TimeInterval = 360
    }
    private let lock = NSLock()
    private let started: TimeInterval
    private var lastProgress: TimeInterval?
    private var failure: String?
    let limits: Limits
    init(limits: Limits = .init(), now: TimeInterval = ProcessInfo.processInfo.systemUptime) { self.limits = limits; started = now }
    func progress(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lock.lock(); defer { lock.unlock() }; lastProgress = now }
    func expired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let failure { return failure }
        if now - started >= limits.total { failure = "Достигнут общий тайм-аут ответа локальной модели. История и выполненные действия сохранены." }
        else if let lastProgress, now - lastProgress >= limits.stalledProgress { failure = "Локальная модель перестала выдавать новые данные. Задачу можно продолжить из сохранённой истории." }
        else if lastProgress == nil, now - started >= limits.firstProgress { failure = "Локальная модель не начала ответ за отведённое время. Проверьте загрузку модели и продолжите задачу." }
        return failure
    }
}
