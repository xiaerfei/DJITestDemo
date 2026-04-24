import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import UIKit

@objc public protocol RTMPIngestControllerDelegate: AnyObject {
    @objc optional func rtmpIngestDidStartPublish(streamKey: String)
    @objc optional func rtmpIngestDidStopPublish(streamKey: String, reason: String)
}

/// Thin ObjC-facing wrapper around `RtmpServer` that drives a `PreviewView`.
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

    /// Maximum frames held in the jitter buffer before the oldest is dropped.
    /// Larger values absorb more network/decode jitter; real smoothness comes from
    /// the `latency` (ms) PTS offset fed to AVSampleBufferDisplayLayer.
    /// Set before calling start(). Default: 3.
    @objc public var frameQueueSize: Int = 3

    private let preview: PreviewView
    private var server: RtmpServer?
    private var frameQueue: SmoothFrameQueue?
    private var isFirstFrameAfterAttach = true

    override init() {
        let pv = PreviewView()
        preview = pv
        previewView = pv
        super.init()
        pv.videoGravity = .resizeAspect
    }

    /// Starts the RTMP ingest server listening on `port`, accepting the given
    /// `streamKey`. Safe to call multiple times; will reset any prior session.
    @objc public func start(port: UInt16, streamKey: String) {
        stop()
        let streams = [SettingsRtmpServerStream(streamKey: streamKey, latency: latency)]
        let settings = SettingsRtmpServer(port: port, streams: streams, noDelay: noDelay)
        let s = RtmpServer(settings: settings, delegate: self)
        server = s
        isFirstFrameAfterAttach = true
        let q = SmoothFrameQueue(size: frameQueueSize)
        q.onFrame = { [weak self] frame in
            self?.preview.enqueue(frame, isFirstAfterAttach: false)
        }
        q.start()
        frameQueue = q
        s.start()
        logger.info("rtmp-ingest: Listening on \(port) for key '\(streamKey)' queueSize=\(frameQueueSize)")
    }

    @objc public func stop() {
        server?.stop()
        server = nil
        frameQueue?.stop()
        frameQueue = nil
        DispatchQueue.main.async { [weak self] in
            self?.preview.layer.flushAndRemoveImage()
        }
    }

    @objc public func isRunning() -> Bool {
        return server != nil
    }
}

extension RTMPIngestController: RtmpServerDelegate {
    func rtmpServerOnPublishStart(streamKey: String) {
        logger.info("rtmp-ingest: Publish started for '\(streamKey)'")
        isFirstFrameAfterAttach = true
        delegate?.rtmpIngestDidStartPublish?(streamKey: streamKey)
    }

    func rtmpServerOnPublishStop(streamKey: String, reason: String) {
        logger.info("rtmp-ingest: Publish stopped '\(streamKey)' (\(reason))")
        delegate?.rtmpIngestDidStopPublish?(streamKey: streamKey, reason: reason)
    }

    func rtmpServerOnVideoBuffer(cameraId _: UUID, _ sampleBuffer: CMSampleBuffer) {
        if isFirstFrameAfterAttach {
            isFirstFrameAfterAttach = false
            DispatchQueue.main.async { [weak self] in
                self?.preview.layer.flushAndRemoveImage()
            }
        }
        frameQueue?.enqueue(sampleBuffer)
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

// MARK: - SmoothFrameQueue

/// Buffers decoded CMSampleBuffers and drains them at the stream's actual frame rate.
///
/// Two key behaviors:
///   1. Fill-first: waits until `targetSize` frames are queued before outputting anything.
///      This is what creates the configurable latency offset.
///   2. Rate-limiting: CADisplayLink fires at 60 Hz but we only output one frame per
///      estimated frame interval (~33 ms at 30 fps). Without this the 60 Hz drain
///      empties the queue faster than 30 fps fills it, so the buffer never builds up.
final class SmoothFrameQueue {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private var frames: [CMSampleBuffer] = []
    private let targetSize: Int
    private let lock = NSLock()
    private var displayLink: CADisplayLink?

    // Rate-limiting state
    private var lastOutputWallTime: Double = 0
    private var avgFrameDuration: Double = 1.0 / 30.0   // seed at 30 fps, adapts live
    private var lastFramePts: Double = -1

    init(size: Int) {
        targetSize = max(1, size)
        frames.reserveCapacity(targetSize + 10)
    }

    func start() {
        lastOutputWallTime = 0
        lastFramePts = -1
        avgFrameDuration = 1.0 / 30.0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        frames.append(sampleBuffer)
        // Safety cap: if consumer stalls for any reason, drop oldest to bound memory.
        if frames.count > targetSize + 30 {
            frames.removeFirst()
        }
        lock.unlock()
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.lock()

        // Output as soon as a frame is available — no fill-first gate.
        // Smoothness comes from the layer's PTS scheduling, not a pre-fill wait.
        guard !frames.isEmpty else {
            lock.unlock()
            return
        }

        // Rate-limit: prevent the 60 Hz display link from draining faster than frames arrive.
        let wallNow = link.timestamp
        guard wallNow - lastOutputWallTime >= avgFrameDuration * 0.9 else {
            lock.unlock()
            return
        }

        let frame = frames.removeFirst()

        // Adapt frame duration from consecutive PTS values (handles 25/30/60 fps).
        let pts = frame.presentationTimeStamp.seconds
        if lastFramePts > 0 {
            let diff = pts - lastFramePts
            if diff > 0.005 && diff < 1.0 {
                avgFrameDuration = avgFrameDuration * 0.9 + diff * 0.1
            }
        }
        lastFramePts = pts
        lastOutputWallTime = wallNow

        lock.unlock()
        onFrame?(frame)
    }
}
