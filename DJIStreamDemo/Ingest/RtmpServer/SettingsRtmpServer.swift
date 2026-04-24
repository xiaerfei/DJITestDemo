// Minimal SettingsRtmpServer — just the fields the RTMP server reads.
// The full Moblin version is a Codable/Observable SwiftUI model that we
// don't need here.

import Foundation

final class SettingsRtmpServerStream {
    let id: UUID
    var streamKey: String
    /// Target latency in milliseconds.
    var latency: Int32

    init(streamKey: String, latency: Int32 = 2000, id: UUID = UUID()) {
        self.id = id
        self.streamKey = streamKey
        self.latency = latency
    }

    func latencySeconds() -> Double {
        return Double(latency) / 1000.0
    }
}

final class SettingsRtmpServer {
    var port: UInt16
    var streams: [SettingsRtmpServerStream]
    var noDelay: Bool

    init(port: UInt16 = 1935, streams: [SettingsRtmpServerStream] = [], noDelay: Bool = true) {
        self.port = port
        self.streams = streams
        self.noDelay = noDelay
    }
}
