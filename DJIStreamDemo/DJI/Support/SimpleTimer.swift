import Foundation

final class SimpleTimer {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { stop() }

    func startSingleShot(timeout: Double, handler: @escaping () -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler(handler: handler)
        t.activate()
        timer = t
    }

    func startPeriodic(interval: Double,
                       initial: Double? = nil,
                       handler: @escaping () -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + (initial ?? interval), repeating: interval)
        t.setEventHandler(handler: handler)
        t.activate()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
