import CoreBluetooth
import Darwin
import Foundation

@objc public enum DJIStreamState: Int {
    case idle
    case discovering
    case connecting
    case checkingIfPaired
    case pairing
    case cleaningUp
    case preparingStream
    case settingUpWifi
    case wifiSetupFailed
    case configuring
    case startingStream
    case streaming
    case stoppingStream

    static func from(_ state: DjiDeviceState) -> DJIStreamState {
        switch state {
        case .idle:              return .idle
        case .discovering:       return .discovering
        case .connecting:        return .connecting
        case .checkingIfPaired:  return .checkingIfPaired
        case .pairing:           return .pairing
        case .cleaningUp:        return .cleaningUp
        case .preparingStream:   return .preparingStream
        case .settingUpWifi:     return .settingUpWifi
        case .wifiSetupFailed:   return .wifiSetupFailed
        case .configuring:       return .configuring
        case .startingStream:    return .startingStream
        case .streaming:         return .streaming
        case .stoppingStream:    return .stoppingStream
        }
    }

    public var description: String {
        switch self {
        case .idle:             return "idle"
        case .discovering:      return "discovering"
        case .connecting:       return "connecting"
        case .checkingIfPaired: return "checkingIfPaired"
        case .pairing:          return "pairing"
        case .cleaningUp:       return "cleaningUp"
        case .preparingStream:  return "preparingStream"
        case .settingUpWifi:    return "settingUpWifi"
        case .wifiSetupFailed:  return "wifiSetupFailed"
        case .configuring:      return "configuring"
        case .startingStream:   return "startingStream"
        case .streaming:        return "streaming"
        case .stoppingStream:   return "stoppingStream"
        }
    }
}

@objc public enum DJIStreamResolution: Int {
    case r480p
    case r720p
    case r1080p

    fileprivate var swiftValue: SettingsDjiDeviceResolution {
        switch self {
        case .r480p:  return .r480p
        case .r720p:  return .r720p
        case .r1080p: return .r1080p
        }
    }
}

@objc public enum DJIStreamImageStabilization: Int {
    case off
    case rockSteady
    case rockSteadyPlus
    case horizonBalancing
    case horizonSteady

    fileprivate var swiftValue: SettingsDjiDeviceImageStabilization {
        switch self {
        case .off:              return .off
        case .rockSteady:       return .rockSteady
        case .rockSteadyPlus:   return .rockSteadyPlus
        case .horizonBalancing: return .horizonBalancing
        case .horizonSteady:    return .horizonSteady
        }
    }
}

@objc public class DJIDiscoveredPeripheral: NSObject {
    @objc public let peripheralId: String
    @objc public let name: String
    @objc public let modelName: String

    fileprivate init(peripheralId: String, name: String, modelName: String) {
        self.peripheralId = peripheralId
        self.name = name
        self.modelName = modelName
        super.init()
    }
}

@objc public protocol DJIStreamControllerDelegate: AnyObject {
    @objc optional func djiStreamController(_ controller: DJIStreamController,
                                            didDiscover peripheral: DJIDiscoveredPeripheral)
    @objc optional func djiStreamController(_ controller: DJIStreamController,
                                            didChangeState state: DJIStreamState,
                                            stateName: String)
}

/// Thin ObjC-facing facade over DjiDeviceScanner + DjiDevice.
/// Usage from ObjC: `[[DJIStreamController shared] startScan]`, etc.
@objc public final class DJIStreamController: NSObject {
    @objc public static let shared = DJIStreamController()

    @objc public weak var delegate: DJIStreamControllerDelegate?

    private let scanner = DjiDeviceScanner.shared
    private let device = DjiDevice()
    private var discoveredByUUID: [String: DjiDiscoveredDevice] = [:]

    override init() {
        super.init()
        scanner.delegate = self
        device.delegate = self
    }

    // MARK: - Scanning

    @objc public func startScan() {
        discoveredByUUID.removeAll()
        scanner.startScanningForDevices()
    }

    @objc public func stopScan() {
        scanner.stopScanningForDevices()
    }

    @objc public func discoveredPeripherals() -> [DJIDiscoveredPeripheral] {
        return scanner.discoveredDevices.map {
            DJIDiscoveredPeripheral(peripheralId: $0.peripheral.identifier.uuidString,
                                    name: $0.peripheral.name ?? "Unknown",
                                    modelName: $0.model.rawValue)
        }
    }

    // MARK: - Streaming

    /// Starts a live stream on the given peripheral.
    /// The peripheral must have been reported via `djiStreamController:didDiscover:`.
    @objc public func startLiveStream(peripheralId: String,
                                      wifiSsid: String,
                                      wifiPassword: String,
                                      rtmpUrl: String,
                                      resolution: DJIStreamResolution,
                                      fps: Int,
                                      bitrate: UInt32,
                                      imageStabilization: DJIStreamImageStabilization) -> Bool {
        guard let uuid = UUID(uuidString: peripheralId),
              let entry = discoveredByUUID[peripheralId] else {
            logger.info("dji-controller: Unknown peripheral \(peripheralId)")
            return false
        }
        stopScan()
        device.startLiveStream(wifiSsid: wifiSsid,
                               wifiPassword: wifiPassword,
                               rtmpUrl: rtmpUrl,
                               resolution: resolution.swiftValue,
                               fps: fps,
                               bitrate: bitrate,
                               imageStabilization: imageStabilization.swiftValue,
                               deviceId: uuid,
                               model: entry.model)
        return true
    }

    @objc public func stopLiveStream() {
        device.stopLiveStream()
    }

    @objc public func batteryPercentage() -> NSNumber? {
        guard let p = device.getBatteryPercentage() else { return nil }
        return NSNumber(value: p)
    }

    // MARK: - LAN helper

    /// Returns the iPhone's current IPv4 address on Wi-Fi (`en0`) or,
    /// when running Personal Hotspot, on the hotspot bridge interface.
    /// Returns nil if neither is active.
    @objc public static func currentLanIPv4() -> String? {
        var fallback: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let head = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            let required = Int32(IFF_UP) | Int32(IFF_RUNNING)
            guard (flags & required) == required else { continue }
            guard (flags & Int32(IFF_LOOPBACK)) == 0 else { continue }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" {
                return ip
            }
            if name.hasPrefix("bridge"), fallback == nil {
                fallback = ip
            }
        }
        return fallback
    }

    /// Convenience: builds an RTMP URL pointing at the local device,
    /// e.g. `rtmp://192.168.1.10:1935/live/<streamKey>`. Returns nil if
    /// no LAN interface is up.
    @objc public static func localRtmpUrl(streamKey: String) -> String? {
        guard let ip = currentLanIPv4() else { return nil }
        let key = streamKey.isEmpty ? "dji" : streamKey
        return "rtmp://\(ip):1935/live/\(key)"
    }
}

extension DJIStreamController: DjiDeviceScannerDelegate {
    func djiScannerDidDiscover(_ device: DjiDiscoveredDevice) {
        let id = device.peripheral.identifier.uuidString
        discoveredByUUID[id] = device
        let payload = DJIDiscoveredPeripheral(peripheralId: id,
                                              name: device.peripheral.name ?? "Unknown",
                                              modelName: device.model.rawValue)
        delegate?.djiStreamController?(self, didDiscover: payload)
    }
}

extension DJIStreamController: DjiDeviceDelegate {
    func djiDeviceStreamingState(_: DjiDevice, state: DjiDeviceState) {
        let mapped = DJIStreamState.from(state)
        delegate?.djiStreamController?(self,
                                       didChangeState: mapped,
                                       stateName: mapped.description)
    }
}
