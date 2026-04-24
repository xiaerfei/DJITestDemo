// Compatibility extensions required by the ported Moblin code.
// ByteReader / ByteWriter themselves live in Ingest/HaishinKit/Util/.

import AVFoundation
import CoreMedia
import Foundation

// Global pixel format used by VideoDecoder's output attributes.
var pixelFormatType: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

// Flv extended-video-header sentinel (used by RTMP client protocol newer frames).
let extendedVideoHeader: UInt8 = 0b1000_0000

extension AVAudioPCMBuffer {
    final func makeSampleBuffer(_ presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        _ = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: Int(frameLength),
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return nil }
        _ = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        )
        return sampleBuffer
    }
}

extension CMSampleBuffer {
    static func create(_ imageBuffer: CVImageBuffer,
                       _ formatDescription: CMVideoFormatDescription,
                       _ duration: CMTime,
                       _ presentationTimeStamp: CMTime,
                       _ decodeTimeStamp: CMTime) -> CMSampleBuffer? {
        var sampleTiming = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &sampleTiming,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    func setIsSync(_ value: Bool) {
        setAttachmentValue(for: kCMSampleAttachmentKey_NotSync, value: !value)
    }

    private func setAttachmentValue(for key: CFString, value: Bool) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else { return }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
        )
    }

    func setAttachmentDisplayImmediately() {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else { return }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

extension String: @retroactive Error {}

extension String {
    var utf8Data: Data { Data(utf8) }

    static func fromUtf8(data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            fatalError("Not UTF-8")
        }
        return text
    }
}

extension UnsignedInteger {
    func isBitSet(index: Int) -> Bool {
        return ((self >> index) & 1) == 1
    }
}

extension ExpressibleByIntegerLiteral {
    var data: Data {
        var value = self
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init(data: Data) {
        let diff: Int = MemoryLayout<Self>.size - data.count
        if diff > 0 {
            var buffer = Data(repeating: 0, count: diff)
            buffer.append(data)
            self = buffer.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: Self.self).pointee }
            return
        }
        self = data.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: Self.self).pointee }
    }
}

func currentPresentationTimeStamp() -> CMTime {
    return CMClockGetTime(CMClockGetHostTimeClock())
}

extension UnsafeRawBufferPointer {
    func readUInt16(offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32(offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}

extension UnsafeMutableRawBufferPointer {
    func writeUInt16(_ value: UInt16, offset: Int) {
        self[offset + 0] = UInt8((value >> 8) & 0xFF)
        self[offset + 1] = UInt8(value & 0xFF)
    }

    func writeUInt32(_ value: UInt32, offset: Int) {
        self[offset + 0] = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}

extension Data {
    func hexString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }

    static func random(length: Int) -> Data {
        return Data((0 ..< length).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) })
    }

    func getUInt16Be(offset: Int = 0) -> UInt16 {
        return withUnsafeBytes {
            $0.load(fromByteOffset: offset, as: UInt16.self)
        }.bigEndian
    }

    func getUInt32Be(offset: Int = 0) -> UInt32 {
        return withUnsafeBytes {
            $0.load(fromByteOffset: offset, as: UInt32.self)
        }.bigEndian
    }

    func getThreeBytesBe(offset: Int = 0) -> UInt32 {
        return UInt32(self[offset]) << 16
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2])
    }

    func getFourBytesBe(offset: Int = 0) -> UInt32 {
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func getFourBytesLe(offset: Int = 0) -> UInt32 {
        return UInt32(self[offset + 3]) << 24
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 0])
    }

    func getInt64Be(offset: Int = 0) -> Int64 {
        return Int64(UInt64(getFourBytesBe(offset: offset)) << 32
            | UInt64(getFourBytesBe(offset: offset + 4)))
    }

    mutating func setUInt16Be(value: UInt16, offset: Int = 0) {
        withUnsafeMutableBytes { $0.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self) }
    }

    mutating func setUInt32Be(value: UInt32, offset: Int = 0) {
        withUnsafeMutableBytes { $0.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self) }
    }

    func makeBlockBuffer(advancedBy: Int = 0) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard advancedBy < count else { return nil }
        let length = count - advancedBy
        return withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CMBlockBuffer? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: length,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: length,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr, let blockBuffer else { return nil }
            guard CMBlockBufferReplaceDataBytes(
                with: baseAddress.advanced(by: advancedBy),
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            ) == noErr else { return nil }
            return blockBuffer
        }
    }

    init(hexString: String) throws {
        guard hexString.count.isMultiple(of: 2) else {
            throw "Not multiple of 2"
        }
        var bytes = Data()
        var index = hexString.startIndex
        for _ in stride(from: 0, to: hexString.count, by: 2) {
            var value = String(hexString[index])
            index = hexString.index(after: index)
            value += String(hexString[index])
            index = hexString.index(after: index)
            guard let v = UInt8(value, radix: 16) else {
                throw "Invalid radix 16 data \(value)"
            }
            bytes.append(v)
        }
        self.init(bytes)
    }
}
