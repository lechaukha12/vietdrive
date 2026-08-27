import Combine
import CoreBluetooth
import Foundation
import UIKit

enum BluetoothBridgeState: Equatable {
    case off
    case unavailable
    case advertising
    case connected

    var label: String {
        switch self {
        case .off: "Đã tắt"
        case .unavailable: "Không khả dụng"
        case .advertising: "Đang chờ box"
        case .connected: "Đã kết nối"
        }
    }
}

/// BLE peripheral exposed by the iPhone for a companion ESP32 display.
/// Messages use an 8-byte little-endian chunk header:
/// [version, kind, sequence(2), chunkIndex(2), chunkCount(2)] + payload.
final class BluetoothBridgeService: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "7E4A0001-7A54-4D52-4956-455652495645")
    static let telemetryUUID = CBUUID(string: "7E4A0002-7A54-4D52-4956-455652495645")
    static let frameUUID = CBUUID(string: "7E4A0003-7A54-4D52-4956-455652495645")
    static let commandUUID = CBUUID(string: "7E4A0004-7A54-4D52-4956-455652495645")

    @Published private(set) var state: BluetoothBridgeState = .off
    @Published private(set) var subscribers = 0

    private var manager: CBPeripheralManager?
    private var telemetryCharacteristic: CBMutableCharacteristic?
    private var frameCharacteristic: CBMutableCharacteristic?
    private var commandCharacteristic: CBMutableCharacteristic?
    private var shouldAdvertise = false
    private var sequence: UInt16 = 0
    private var negotiatedMTU = 20
    private var outgoingPackets: [(kind: UInt8, characteristic: CBMutableCharacteristic, data: Data)] = []
    private var latestTelemetry = Data()
    private var latestFrame = Data()

    var isEnabled: Bool { shouldAdvertise }
    var canSendFrames: Bool { subscribers > 0 }

    func setEnabled(_ enabled: Bool) {
        shouldAdvertise = enabled
        if enabled {
            if manager == nil {
                manager = CBPeripheralManager(
                    delegate: self,
                    queue: .main,
                    options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
                )
            } else if manager?.state == .poweredOn {
                configureAndAdvertise()
            }
        } else {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            outgoingPackets.removeAll()
            subscribers = 0
            state = .off
        }
    }

    func publish(snapshot: DriveSnapshot) {
        guard let encoded = try? JSONEncoder().encode(DeviceTelemetry(snapshot: snapshot)) else { return }
        latestTelemetry = encoded
        enqueue(kind: 0x01, data: encoded, characteristic: telemetryCharacteristic)
    }

    func publish(frame image: UIImage) {
        guard canSendFrames, let jpeg = image.jpegData(compressionQuality: 0.62) else { return }
        latestFrame = jpeg
        enqueue(kind: 0x02, data: jpeg, characteristic: frameCharacteristic)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if shouldAdvertise { configureAndAdvertise() }
        case .poweredOff:
            state = shouldAdvertise ? .unavailable : .off
        case .unsupported, .unauthorized:
            state = .unavailable
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, shouldAdvertise else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "VietDrive"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        state = error == nil ? .advertising : .unavailable
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscribers += 1
        negotiatedMTU = max(20, central.maximumUpdateValueLength)
        state = .connected
        if !latestTelemetry.isEmpty {
            enqueue(kind: 0x01, data: latestTelemetry, characteristic: telemetryCharacteristic)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { negotiatedMTU = 20 }
        state = subscribers > 0 ? .connected : .advertising
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.telemetryUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        request.value = latestTelemetry
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.commandUUID {
            if request.value?.first == 0x01, !latestFrame.isEmpty {
                enqueue(kind: 0x02, data: latestFrame, characteristic: frameCharacteristic)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPackets()
    }

    private func configureAndAdvertise() {
        guard let manager, manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        manager.removeAllServices()

        telemetryCharacteristic = CBMutableCharacteristic(
            type: Self.telemetryUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        frameCharacteristic = CBMutableCharacteristic(
            type: Self.frameUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        commandCharacteristic = CBMutableCharacteristic(
            type: Self.commandUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [telemetryCharacteristic, frameCharacteristic, commandCharacteristic].compactMap { $0 }
        manager.add(service)
    }

    private func enqueue(kind: UInt8, data: Data, characteristic: CBMutableCharacteristic?) {
        guard shouldAdvertise, subscribers > 0, let characteristic else { return }

        // Never allow stale frames or telemetry to grow an unbounded BLE queue.
        if kind == 0x02, outgoingPackets.contains(where: { $0.kind == 0x02 }) {
            return
        }
        outgoingPackets.removeAll { $0.kind == kind && kind == 0x01 }

        sequence &+= 1
        let mtu = negotiatedMTU
        let payloadSize = max(12, mtu - 8)
        let count = UInt16(max(1, Int(ceil(Double(data.count) / Double(payloadSize)))))

        for index in 0..<Int(count) {
            let lower = index * payloadSize
            let upper = min(data.count, lower + payloadSize)
            var packet = Data([1, kind])
            packet.appendLittleEndian(sequence)
            packet.appendLittleEndian(UInt16(index))
            packet.appendLittleEndian(count)
            if lower < upper { packet.append(data[lower..<upper]) }
            let queued = (kind: kind, characteristic: characteristic, data: packet)
            if kind == 0x01 {
                outgoingPackets.insert(queued, at: 0)
            } else {
                outgoingPackets.append(queued)
            }
        }
        flushPackets()
    }

    private func flushPackets() {
        guard let manager else { return }
        while let packet = outgoingPackets.first {
            guard manager.updateValue(
                packet.data,
                for: packet.characteristic,
                onSubscribedCentrals: nil
            ) else { return }
            outgoingPackets.removeFirst()
        }
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value & 0xff00) >> 8))
    }
}
