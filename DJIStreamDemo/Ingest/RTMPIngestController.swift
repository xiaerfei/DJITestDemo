import CoreMedia
import Foundation
import UIKit

@objc public protocol RTMPIngestControllerDelegate: AnyObject {
    @objc optional func rtmpIngestDidStartPublish(streamKey: String)
    @objc optional func rtmpIngestDidStopPublish(streamKey: String, reason: String)
}

/// Thin ObjC-facing wrapper around `RtmpServer` that drives a `MetalPreviewView`.
///
/// Metal rendering eliminates AVSampleBufferDisplayLayer's PTS-driven buffering.
/// The latest decoded CVPixelBuffer is rendered immediately on every display
/// refresh — no queue, no PTS wait, no frame accumulation.
@objc public final class RTMPIngestController: NSObject {
    @objc public static let shared = RTMPIngestController()

    @objc public weak var delegate: RTMPIngestControllerDelegate?

    /// The preview surface. Add this view to your layout to display decoded video.
    @objc public let previewView: UIView

    /// Buffer latency in milliseconds added to each frame's presentation timestamp.
    /// 0 = display as soon as decoded (lowest latency). Default: 0.
    @objc public var latency: Int32 = 0

    /// Whether to set TCP_NODELAY on the ingest socket (disables Nagle's algorithm).
    /// Keep ON for lowest latency. Default: true.
    @objc public var noDelay: Bool = true

    /// Kept for ObjC API compatibility. No longer used — Metal renders the latest
    /// frame directly without any intermediate queue.
    @objc public var frameQueueSize: Int = 3

    private let preview: MetalPreviewView
    private var server: RtmpServer?

    override init() {
        let pv = MetalPreviewView(frame: .zero, device: nil)
        preview = pv
        previewView = pv
        super.init()
    }

    /// Starts the RTMP ingest server listening on `port`, accepting the given
    /// `streamKey`. Safe to call multiple times; will reset any prior session.
    @objc public func start(port: UInt16, streamKey: String) {
        stop()
        let streams = [SettingsRtmpServerStream(streamKey: streamKey, latency: latency)]
        let settings = SettingsRtmpServer(port: port, streams: streams, noDelay: noDelay)
        let s = RtmpServer(settings: settings, delegate: self)
        server = s
        s.start()
        logger.info("rtmp-ingest: Listening on \(port) for key '\(streamKey)' (Metal renderer)")
    }

    @objc public func stop() {
        server?.stop()
        server = nil
        preview.clearFrame()
    }

    @objc public func isRunning() -> Bool {
        return server != nil
    }
}

extension RTMPIngestController: RtmpServerDelegate {
    func rtmpServerOnPublishStart(streamKey: String) {
        logger.info("rtmp-ingest: Publish started for '\(streamKey)'")
        delegate?.rtmpIngestDidStartPublish?(streamKey: streamKey)
    }

    func rtmpServerOnPublishStop(streamKey: String, reason: String) {
        logger.info("rtmp-ingest: Publish stopped '\(streamKey)' (\(reason))")
        delegate?.rtmpIngestDidStopPublish?(streamKey: streamKey, reason: reason)
    }

    func rtmpServerOnVideoBuffer(cameraId _: UUID, _ sampleBuffer: CMSampleBuffer) {
        // Extract CVPixelBuffer and hand it directly to Metal — ignore PTS entirely.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        preview.updateFrame(pixelBuffer)
    }

    func rtmpServerOnVideoImageBuffer(cameraId _: UUID, _ imageBuffer: CVImageBuffer) {
        // Zero-copy path from VideoDecoder — deliver directly to Metal
        preview.updateFrame(imageBuffer)
    }

    func rtmpServerOnAudioBuffer(cameraId _: UUID, _: CMSampleBuffer) {
        // Audio playback is out of scope for this demo.
    }

    func rtmpServerSetTargetLatencies(cameraId _: UUID,
                                      _: Double,
                                      _: Double) {
        // Latency sync is out of scope for this demo.
    }
}
