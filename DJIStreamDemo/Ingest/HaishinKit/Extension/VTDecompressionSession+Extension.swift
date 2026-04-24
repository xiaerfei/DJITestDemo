import Foundation
import VideoToolbox

extension VTDecompressionSession {
    static let defaultDecodeFlags: VTDecodeFrameFlags = [
        ._EnableAsynchronousDecompression,
        // _EnableTemporalProcessing removed: DJI live streams have no B-frames,
        // and this flag buffers frames for reorder which adds latency.
    ]

    @inline(__always)
    func decodeFrame(_ sampleBuffer: CMSampleBuffer,
                     outputHandler: @escaping VTDecompressionOutputHandler) -> OSStatus
    {
        var flagsOut: VTDecodeInfoFlags = []
        return VTDecompressionSessionDecodeFrame(
            self,
            sampleBuffer: sampleBuffer,
            flags: Self.defaultDecodeFlags,
            infoFlagsOut: &flagsOut,
            outputHandler: outputHandler
        )
    }

    func invalidate() {
        VTDecompressionSessionInvalidate(self)
    }
}
