import Foundation

private func reflect8(_ v: UInt8) -> UInt8 {
    var x = v
    x = ((x & 0xF0) >> 4) | ((x & 0x0F) << 4)
    x = ((x & 0xCC) >> 2) | ((x & 0x33) << 2)
    x = ((x & 0xAA) >> 1) | ((x & 0x55) << 1)
    return x
}

private func reflect16(_ v: UInt16) -> UInt16 {
    var x = v
    x = ((x & 0xFF00) >> 8) | ((x & 0x00FF) << 8)
    x = ((x & 0xF0F0) >> 4) | ((x & 0x0F0F) << 4)
    x = ((x & 0xCCCC) >> 2) | ((x & 0x3333) << 2)
    x = ((x & 0xAAAA) >> 1) | ((x & 0x5555) << 1)
    return x
}

func djiCrc8(data: Data) -> UInt8 {
    let poly: UInt8 = 0x31
    var crc: UInt8 = 0xEE
    for b in data {
        crc ^= reflect8(b)
        for _ in 0 ..< 8 {
            if (crc & 0x80) != 0 {
                crc = (crc << 1) ^ poly
            } else {
                crc <<= 1
            }
        }
    }
    return reflect8(crc)
}

func djiCrc16(data: Data) -> UInt16 {
    let poly: UInt16 = 0x1021
    var crc: UInt16 = 0x496C
    for b in data {
        crc ^= UInt16(reflect8(b)) << 8
        for _ in 0 ..< 8 {
            if (crc & 0x8000) != 0 {
                crc = (crc << 1) ^ poly
            } else {
                crc <<= 1
            }
        }
    }
    return reflect16(crc)
}
