import Foundation
import CoreBluetooth

/// Turns the iPhone into a BLE peripheral. Motion is sampled at 100 Hz and swing metrics are
/// computed on the phone; ONLY the finalized 20-byte impact packet is notified to subscribers,
/// so no 100 Hz raw stream ever hits iOS's BLE throttling.
///
/// Packet layout (little endian, 20 bytes - fits the default 23 byte ATT MTU):
///  0      UInt8   protocol version (1)
///  1      UInt8   club id (0 Driver ... 7 Putter)
///  2-3    UInt16  sequence number
///  4-5    UInt16  clubhead speed, mph x 10
///  6-7    UInt16  ball speed, mph x 10
///  8-9    Int16   launch angle, degrees x 10
///  10-11  Int16   azimuth (left -, right +), degrees x 10
///  12-13  UInt16  peak acceleration, g x 100
///  14-15  UInt16  spin, rpm
///  16-19  UInt32  timestamp, milliseconds since device boot
final class BluetoothServerManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    static let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-567812345678")
    static let characteristicUUID = CBUUID(string: "87654321-4321-6789-4321-678943218765")
    static let advertisedName = "GolfSim Controller"

    @Published private(set) var stateDescription = "Off"
    @Published private(set) var isAdvertising = false
    @Published private(set) var subscriberCount = 0
    @Published private(set) var packetsSent = 0
    @Published private(set) var lastPayloadHex = ""

    private var peripheral: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var wantsRunning = false
    private var pending: [Data] = []
    private var lastPayload = Data()
    private var sequence: UInt16 = 0

    // MARK: Control

    func start() {
        wantsRunning = true
        if peripheral == nil {
            peripheral = CBPeripheralManager(delegate: self, queue: nil, options: nil)
        } else if peripheral?.state == .poweredOn {
            setUpServiceIfNeeded()
        }
    }

    func stop() {
        wantsRunning = false
        peripheral?.stopAdvertising()
        if serviceAdded {
            peripheral?.removeAllServices()
            serviceAdded = false
            characteristic = nil
        }
        pending.removeAll()
        isAdvertising = false
        subscriberCount = 0
        stateDescription = "Off"
    }

    /// Streams the finalized impact packet. Called once per swing.
    func sendImpact(_ metrics: SwingMetrics) {
        sequence &+= 1
        let data = Self.encode(metrics, sequence: sequence)
        lastPayload = data
        lastPayloadHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let characteristic = characteristic, let peripheral = peripheral, subscriberCount > 0 else { return }
        if peripheral.updateValue(data, for: characteristic, onSubscribedCentrals: nil) {
            packetsSent += 1
        } else {
            pending.append(data)
        }
    }

    // MARK: Encoding

    static func encode(_ m: SwingMetrics, sequence: UInt16) -> Data {
        var d = Data()
        func u8(_ v: UInt8) { d.append(v) }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func i16(_ v: Int16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func clampU16(_ x: Double) -> UInt16 { UInt16(max(0, min(65535, x.rounded()))) }
        func clampI16(_ x: Double) -> Int16 { Int16(max(-32768, min(32767, x.rounded()))) }

        u8(1)
        u8(UInt8(max(0, min(255, m.clubID))))
        u16(sequence)
        u16(clampU16(m.clubheadSpeedMPH * 10))
        u16(clampU16(m.ballSpeedMPH * 10))
        i16(clampI16(m.launchAngleDeg * 10))
        i16(clampI16(m.azimuthDeg * 10))
        u16(clampU16(m.peakAccelerationG * 100))
        u16(clampU16(m.spinRPM))
        let ms = UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000))
        u32(ms)
        return d
    }

    // MARK: Service setup

    private func setUpServiceIfNeeded() {
        guard let peripheral = peripheral, !serviceAdded else {
            startAdvertisingIfPossible()
            return
        }
        let characteristic = CBMutableCharacteristic(type: Self.characteristicUUID,
                                                     properties: [.notify, .read],
                                                     value: nil,
                                                     permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        self.characteristic = characteristic
        peripheral.add(service)
        serviceAdded = true
    }

    private func startAdvertisingIfPossible() {
        guard wantsRunning, let peripheral = peripheral, peripheral.state == .poweredOn,
              serviceAdded, !peripheral.isAdvertising else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: Self.advertisedName
        ])
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            stateDescription = "Bluetooth ready"
            if wantsRunning { setUpServiceIfNeeded() }
        case .poweredOff: stateDescription = "Bluetooth is off"; isAdvertising = false
        case .unauthorized: stateDescription = "Bluetooth permission denied"
        case .unsupported: stateDescription = "BLE peripheral not supported"
        case .resetting: stateDescription = "Bluetooth resetting"
        case .unknown: stateDescription = "Bluetooth unknown"
        @unknown default: stateDescription = "Bluetooth unavailable"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            stateDescription = "Service error: \(error.localizedDescription)"
            serviceAdded = false
            return
        }
        startAdvertisingIfPossible()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            stateDescription = "Advertising error: \(error.localizedDescription)"
            isAdvertising = false
        } else {
            isAdvertising = true
            stateDescription = subscriberCount > 0 ? "Connected" : "Advertising - waiting for display"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscriberCount += 1
        stateDescription = "Connected"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscriberCount = max(0, subscriberCount - 1)
        stateDescription = subscriberCount > 0 ? "Connected" : "Advertising - waiting for display"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.characteristicUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        if request.offset > lastPayload.count {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = lastPayload.subdata(in: request.offset..<lastPayload.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let characteristic = characteristic else { return }
        while let next = pending.first {
            if peripheral.updateValue(next, for: characteristic, onSubscribedCentrals: nil) {
                pending.removeFirst()
                packetsSent += 1
            } else {
                break
            }
        }
    }
}
