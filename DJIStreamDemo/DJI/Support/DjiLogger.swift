import Foundation

final class EasyLogger {
    var debugEnabled: Bool = true

    private func timestamp() -> String {
        Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    }

    func debug(_ message: String) {
        guard debugEnabled else { return }
        print("\(timestamp()) [D] \(message)")
    }

    func info(_ message: String) {
        print("\(timestamp()) [I] \(message)")
    }
}

let logger = EasyLogger()
