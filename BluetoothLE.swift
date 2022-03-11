//
//  BluetoothLE.swift
//
//  Inspired by: purpln https://github.com/purpln/bluetooth and Chris Hulbert http://www.splinter.com.au/2019/05/18/ios-swift-bluetooth-le/
//  Created by Claes Hallberg on 1/12/22.
//  Licence: MIT

import CoreBluetooth

private let peripheralIdDefaultsKey = "MyBluetoothManagerPeripheralId"
private let myDesiredServiceId = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")  //Used for auto connect and re connect to this Service UIID only
private let myDesiredCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130003")
private let statusCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130003")  //ESP32 pTxCharacteristic ESP send (notifying)
private let otaCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130005")//ESP32 pOtaCharacteristic  ESP write

private let outOfRangeHeuristics: Set<CBError.Code> = [.unknown, .connectionTimeout, .peripheralDisconnected, .connectionFailed]

// Class definition
class BLEConnection:NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate{
    
    var manager: CBCentralManager!
    var statusCharacteristic: CBCharacteristic?
    var otaCharacteristic: CBCharacteristic?
    
    var state = StateBLE.poweredOff
    
    enum StateBLE {
        case poweredOff
        case restoringConnectingPeripheral(CBPeripheral)
        case restoringConnectedPeripheral(CBPeripheral)
        case disconnected
        case scanning(Countdown)
        case connecting(CBPeripheral, Countdown)
        case discoveringServices(CBPeripheral, Countdown)
        case discoveringCharacteristics(CBPeripheral, Countdown)
        case connected(CBPeripheral)
        case outOfRange(CBPeripheral)
        
        var peripheral: CBPeripheral? {
            switch self {
            case .poweredOff: return nil
            case .restoringConnectingPeripheral(let p): return p
            case .restoringConnectedPeripheral(let p): return p
            case .disconnected: return nil
            case .scanning: return nil
            case .connecting(let p, _): return p
            case .discoveringServices(let p, _): return p
            case .discoveringCharacteristics(let p, _): return p
            case .connected(let p): return p
            case .outOfRange(let p): return p
            }
        }
    }
    
    //Used by contentView.swift
    @Published var name = ""
    @Published var connected = false
    @Published var transferProgress : Double = 0.0
    @Published var chunkCount = 2 // number of chunks to be sent before peripheral needs to accknowledge.
    @Published var elapsedTime = 0.0
    @Published var kBPerSecond = 0.0
    
    
    //transfer varibles
    var dataToSend = Data()
    var dataBuffer = Data()
    var chunkSize = 0
    var dataLength = 0
    var transferOngoing = true
    var sentBytes = 0
    var packageCounter = 0
    var startTime = 0.0
    var stopTime = 0.0
    var firstAcknowledgeFromESP32 = false
        
    //Initiate CentralManager
    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .none)
        manager.delegate = self
    }
    
    // Callback from CentralManager when State updates (on, off, etc)
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("\(Date()) CM DidUpdateState")
        switch manager.state {
        case .unknown:
            print("\(Date()) Unknown")
        case .resetting:
            print("\(Date()) Resetting")
        case .unsupported:
            print("\(Date()) Unsupported")
        case .unauthorized:
            print("\(Date()) Bluetooth disabled for this app, pls enable it in settings")
        case .poweredOff:
            print("\(Date()) Turn on bluetooth")
        case .poweredOn:
            print("\(Date()) Everything is ok :-) ")
            if case .poweredOff = state {
                // Firstly, try to reconnect:
                // 1. Any peripheralsID stored in UserDefaults?
                if let peripheralIdStr = UserDefaults.standard.object(forKey: peripheralIdDefaultsKey) as? String,
                   // 2. Yes, so convert the String to a UUID type
                   let peripheralId = UUID(uuidString: peripheralIdStr),
                   // 3. Compare with UUID's already in the manager
                   let previouslyConnected = manager
                    .retrievePeripherals(withIdentifiers: [peripheralId])
                    .first {
                    // 4. If ok then connect
                    print("\(Date()) CM DidUpdateState: connect from userDefaults")
                    connect(peripheral: previouslyConnected)
                    // Next, try for ones that are connected to the system:
                }
            }
            print("\(Date()) End of .poweredOn")
        @unknown default:
            print("\(Date()) fatal error")
        }
    }
    
    // Discovery (scanning) and handling of BLE devices in range
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard case .scanning = state else { return }
        name = String(peripheral.name ?? "unknown")
        print("\(Date()) \(name) is found")
        print("\(Date()) CM DidDiscover")
        manager.stopScan()
        connect(peripheral: peripheral)
    }
    
    // Connection established handler
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("\(Date()) CM DidConnect")
        
        transferOngoing = false
        
        // Clear the data that we may already have
        dataToSend.removeAll(keepingCapacity: false)
        
        // Make sure we get the discovery callbacks
        peripheral.delegate = self
        
        if peripheral.myDesiredCharacteristic == nil {
            discoverServices(peripheral: peripheral)
        } else {
            setConnected(peripheral: peripheral)
        }
    }
    
    // Connection failed
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("\(Date()) CM DidFailToConnect")
        state = .disconnected
    }
    
    // Disconnection (out of range, ...)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        transferOngoing = false
        print("\(Date()) CM DidDisconnectPeripheral")
        print("\(Date()) \(peripheral.name ?? "unknown") disconnected")
        // Did our currently-connected peripheral just disconnect?
        if state.peripheral?.identifier == peripheral.identifier {
            name = ""
            connected = false
            // IME the error codes encountered are:
            // 0 = rebooting the peripheral.
            // 6 = out of range.
            if let error = error, (error as NSError).domain == CBErrorDomain,
               let code = CBError.Code(rawValue: (error as NSError).code),
               outOfRangeHeuristics.contains(code) {
                // Try reconnect without setting a timeout in the state machine.
                // With CB, it's like saying 'please reconnect me at any point
                // in the future if this peripheral comes back into range'.
                print("\(Date()) connect: try reconnect when back in range")
                manager.connect(peripheral, options: nil)
                state = .outOfRange(peripheral)
            } else {
                // Likely a deliberate unpairing.
                state = .disconnected
            }
        }
    }

    //-----------------------------------------
    // Peripheral callbacks
    //-----------------------------------------
  
    // Discover BLE device service(s)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print("\(Date()) PH didDiscoverServices")
        // Ignore services discovered late.
        guard case .discoveringServices = state else {
            return
        }
        if let error = error {
            print("\(Date()) Failed to discover services: \(error)")
            disconnect()
            return
        }
        guard peripheral.myDesiredService != nil else {
            print("\(Date()) Desired service missing")
            disconnect()
            return
        }
        // All fine so far, go to next step
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
         
    }
    // Discover BLE device Service charachteristics
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("\(Date()) PH didDiscoverCharacteristicsFor")
        
        if let error = error {
            print("\(Date()) Failed to discover characteristics: \(error)")
            disconnect()
            return
        }
        
        guard peripheral.myDesiredCharacteristic != nil else {
            print("\(Date()) Desired characteristic missing")
            disconnect()
            return
        }
        
        guard let characteristics = service.characteristics else {
            return
        }
        
        
        for characteristic in characteristics{
            switch characteristic.uuid {
            
            case statusCharacteristicId:
                statusCharacteristic = characteristic
                print("\(Date()) receive status from: \(statusCharacteristic!.uuid as Any)")
                peripheral.setNotifyValue(true, for: characteristic)
            
            case otaCharacteristicId:
                otaCharacteristic = characteristic
                print("\(Date()) send OTA firmware to: \(otaCharacteristic!.uuid as Any)")
                peripheral.setNotifyValue(false, for: characteristic)
                    
            default:
                print("\(Date()) unknown")
            }
        }
        setConnected(peripheral: peripheral)
    }
    // The BLE peripheral device sent some notify data. Deal with it!
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        //print("\(Date()) PH didUpdateValueFor")
        if let error = error {
            print(error)
            return
        }
        if let data = characteristic.value{
            // deal with incoming data
            // First check if the incoming data is one byte length?
            // if so it's the peripheral acknowledging and telling
            // us to send another batch of data
            if data.count == 1 {
                if !firstAcknowledgeFromESP32 {
                    firstAcknowledgeFromESP32 = true
                    startTime = CFAbsoluteTimeGetCurrent()
                }
                //print("\(Date()) -X-")
                if transferOngoing {
                    packageCounter = 0
                    writeDataToPeriheral(characteristic: otaCharacteristic!)
                }
            }
        }
    }
    
    // Called when .withResponse is used.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?){
        print("\(Date()) PH didWriteValueFor")
        if let error = error {
            print("\(Date()) Error writing to characteristic: \(error)")
            return
        }
    }
    
    // Callback indicating peripheral notifying state
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?){
        print("\(Date()) PH didUpdateNotificationStateFor")
        print("\(Date()) PH \(characteristic)")
        if error == nil {
            print("\(Date()) Notification Set OK, isNotifying: \(characteristic.isNotifying)")
            if !characteristic.isNotifying {
                print("\(Date()) isNotifying is false, set to true again!")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
    
    /*-------------------------------------------------------------------------
     Functions
     -------------------------------------------------------------------------*/
    // Scanning for device with a specific Service UUID (myDesiredServiceId)
    func startScanning(){
        print("\(Date()) FUNC StartScanning")
        guard manager.state == .poweredOn else {
            print("\(Date()) Cannot scan, BT is not powered on")
            return
        }
        manager.scanForPeripherals(withServices: [myDesiredServiceId], options: nil)
        state = .scanning(Countdown(seconds: 10, closure: {
            self.manager.stopScan()
            self.state = .disconnected
            print("\(Date()) Scan timed out")
        }))
    }
    
    // Disconnect by user request
    func disconnect(forget: Bool = false) {
        print("\(Date()) FUNC Disconnect")
        if let peripheral = state.peripheral {
            manager.cancelPeripheralConnection(peripheral)
        }
        if forget {
            UserDefaults.standard.removeObject(forKey: peripheralIdDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        state = .disconnected
        connected = false
        transferOngoing = false
    }
    
    // Connect to the device from the scanning
    func connect(peripheral: CBPeripheral){
        print("\(Date()) FUNC Connect")
        if connected {
            manager.cancelPeripheralConnection(peripheral)
        }else{
            // Connect!
            print("\(Date()) connect: connect inside func connect()")
            manager.connect(peripheral, options: nil)
            name = String(peripheral.name ?? "unknown")
            print("\(Date()) \(name) is found")
            state = .connecting(peripheral, Countdown(seconds: 10, closure: {
                self.manager.cancelPeripheralConnection(self.state.peripheral!)
                self.state = .disconnected
                self.connected = false
                print("\(Date()) Connect timed out")
            }))
        }
    }
    
    // Discover Services of a device
    func discoverServices(peripheral: CBPeripheral) {
        print("\(Date()) FUNC DiscoverServices")
        peripheral.delegate = self
        peripheral.discoverServices([myDesiredServiceId])
        state = .discoveringServices(peripheral, Countdown(seconds: 10, closure: {
            self.disconnect()
            print("\(Date()) Could not discover services")
        }))
    }
    
    // Discover Characteristics of a Services
    func discoverCharacteristics(peripheral: CBPeripheral) {
        print("\(Date()) FUNC DiscoverCharacteristics")
        guard let myDesiredService = peripheral.myDesiredService else {
            self.disconnect()
            return
        }
        peripheral.discoverCharacteristics([myDesiredCharacteristicId], for: myDesiredService)
        state = .discoveringCharacteristics(peripheral,
                                            Countdown(seconds: 10,
                                                      closure: {
                                                        self.disconnect()
                                                        print("\(Date()) Could not discover characteristics")
                                                      }))
    }
    
    func setConnected(peripheral: CBPeripheral) {
        print("\(Date()) FUNC SetConnected")
        print("\(Date()) Max write value with response: \(peripheral.maximumWriteValueLength(for: .withResponse))")
        print("\(Date()) Max write value without response: \(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        guard let myDesiredCharacteristic = peripheral.myDesiredCharacteristic
        else {
            print("\(Date()) Missing characteristic")
            disconnect()
            return
        }
        
        // Remember the ID for startup reconnecting.
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: peripheralIdDefaultsKey)
        UserDefaults.standard.synchronize()
        
        peripheral.setNotifyValue(true, for: myDesiredCharacteristic)
        state = .connected(peripheral)
        connected = true
        name = String(peripheral.name ?? "unknown")
    }
    
    
    // Peripheral callback when its ready to receive more data without response
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if transferOngoing && packageCounter < chunkCount {
                writeDataToPeriheral(characteristic: otaCharacteristic!)
        }
    }
    
    func sendFile(filename: String, fileEnding: String) {
        print("\(Date()) FUNC SendFile")
        
        // 1. Get the data from the file(name) and copy data to dataBUffer
        guard let data: Data = try? getBinFileToData(fileName: filename, fileEnding: fileEnding) else {
            print("\(Date()) failed to open file")
            return
        }
        dataBuffer = data
        dataLength = dataBuffer.count
        transferOngoing = true
        packageCounter = 0
        // Send the first chunk
        elapsedTime = 0.0
        sentBytes = 0
        firstAcknowledgeFromESP32 = false
        startTime = CFAbsoluteTimeGetCurrent()
        writeDataToPeriheral(characteristic: otaCharacteristic!)
    }
    
    
    func writeDataToPeriheral(characteristic: CBCharacteristic) {
        
        // 1. Get the peripheral and it's transfer characteristic
        guard let discoveredPeripheral = state.peripheral else {return}
        // ATT MTU - 3 bytes
        chunkSize = discoveredPeripheral.maximumWriteValueLength (for: .withoutResponse) - 3
        // Get the data range
        var range:Range<Data.Index>
        // 2. Loop through and send each chunk to the BLE device
        // check to see if number of iterations completed and peripheral can accept more data
        // package counter allow only "chunkCount" of data to be sent per time.
        while transferOngoing && discoveredPeripheral.canSendWriteWithoutResponse && packageCounter < chunkCount {

            // 3. Create a range based on the length of data to return
            range = (0..<min(chunkSize, dataBuffer.count))
            
            // 4. Get a subcopy copy of data
            let subData = dataBuffer.subdata(in: range)
            
            // 5. Send data chunk to BLE peripheral, send EOF when buffer is empty.
            
            if !dataBuffer.isEmpty {
                discoveredPeripheral.writeValue(subData, for: characteristic, type: .withoutResponse)
                packageCounter += 1
                //print(" Packages: \(packageCounter) bytes: \(subData.count)")
            } else {
                transferOngoing = false
            }
            
            if discoveredPeripheral.canSendWriteWithoutResponse {
                print("BLE peripheral ready?: \(discoveredPeripheral.canSendWriteWithoutResponse)")
            }
            
            // 6. Remove already sent data from buffer
            dataBuffer.removeSubrange(range)
            
            // 7. calculate and print the transfer progress in %
            transferProgress = (1 - (Double(dataBuffer.count) / Double(dataLength))) * 100
            print("file transfer: \(transferProgress)%")
            sentBytes = sentBytes + chunkSize
            elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
            let kbPs = Double(sentBytes) / elapsedTime
            kBPerSecond = kbPs / 1000
        }
    }
}


extension CBPeripheral {
    // Helper to find the service we're interested in.
    var myDesiredService: CBService? {
        guard let services = services else { return nil }
        return services.first { $0.uuid == myDesiredServiceId }
    }
    // Helper to find the characteristic we're interested in.
    var myDesiredCharacteristic: CBCharacteristic? {
        guard let characteristics = myDesiredService?.characteristics else {
            return nil
        }
        return characteristics.first { $0.uuid == myDesiredCharacteristicId }
    }
}

class Countdown {
    let timer: Timer
    init(seconds: TimeInterval, closure: @escaping () -> ()) {
        timer = Timer.scheduledTimer(withTimeInterval: seconds,
                                     repeats: false, block: { _ in
                                        closure()
                                     })
    }
    deinit {
        timer.invalidate()
    }
}
