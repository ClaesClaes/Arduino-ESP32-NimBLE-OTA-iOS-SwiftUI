//
//  BluetoothLE.swift
//  ScintBLE
//
//  Created by Claes Hallberg on 1/15/21.
//

import CoreBluetooth
import Combine
import SwiftUI
import Foundation
import AudioToolbox

private let restoreIdKey = "MyBluetoothManager" //Needed?
private let peripheralIdDefaultsKey = "MyBluetoothManagerPeripheralId"
private let myDesiredServiceId = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")
private let myDesiredCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130003")

private let commandCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130002") //ESP32 pRxCharacteristic ESP receive
private let statusCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130003")  //ESP32 pTxCharacteristic ESP send (notifying)
private let transferCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130004")//ESP32 pTransferCharacteristic  ESP receive
private let otaCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130005")//ESP32 pOtaCharacteristic  ESP receive
private let readCharacteristicId = CBUUID(string: "62EC0272-3EC5-11EB-B378-0242AC130006")

private let outOfRangeHeuristics: Set<CBError.Code> = [.unknown, .connectionTimeout, .peripheralDisconnected, .connectionFailed]

// Class definition
class BLEConnection:NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate{
    
    @ObservedObject var cmdstat    : CmdStat
    @ObservedObject var settings   : UserSettings
    
    @ObservedObject var fileBufferForSending  = FilesAndCrc()
    
    var hapticManager = HapticManager()
    
    var manager : CBCentralManager!
    //var peripheral: CBPeripheral!
    var myPeripheral : CBPeripheral!
    
    var readCharacteristic: CBCharacteristic?
    var writeCharacteristic: CBCharacteristic?
    var statusCharacteristic: CBCharacteristic?
    var transferCharacteristic: CBCharacteristic?
    var otaCharacteristic: CBCharacteristic?
    /// The 'state machine' for remembering where we're up to.
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
    
    //private var timer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()
    @Published var fileTransferOngoing = false {
        didSet {
            do {
                if !fileTransferOngoing {
                    print("\(Date()) filetransfer flag was set to FALSE")
                    // 1. Now see if transferbuffer is empty or not
                    // 2. If empty do nothing
                    // 3. If NOT empty, go ahead and sent another file.
                }
            }
        }
    }
    @Published var transferSuccessful = false
    @Published var silentTransfer = false
    @Published var showToast = false
    @Published var message: String = ""
    
    //@Published var defaults = AppDefaults()
    @Published var name = ""
    @Published var scanning = false
    @Published var connected = false
    @Published var bleIsOff = false
    
    @Published var transferProgress : Double = 0.0
    
    //transfer varibles
    var dataToSend = Data()
    var dataBuffer = Data()
    var chunkSize = 0
    var dataLength = 0
    var OTAtransfer = false
    var fileEmpty = false
    var packageCounter = 0
    var timer:Timer?
    var projectionTimer : Timer?
    var projectionTimerStarted : Bool = false
    
    //Initiate CentralManager
//    override init() {
    /*override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .none)
        //manager = CBCentralManager(delegate: self, queue: nil, options:
        //                            [CBCentralManagerOptionShowPowerAlertKey: true,
        //                            CBCentralManagerOptionRestoreIdentifierKey: restoreIdKey,])
        manager.delegate = self
    }*/
    
    init(status: CmdStat, settings: UserSettings) {
        self.cmdstat = status
        self.settings = settings
        super.init()
        manager = CBCentralManager(delegate: self, queue: .none)
        manager.delegate = self
    }
    
    // Callback from CentralManager when StateBLE updates (on, off, etc)
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("\(Date()) CM DidUpdateState")
        switch manager.state {
        case .unknown:
            print("\(Date()) BLE .unknown")
        case .resetting:
            print("\(Date()) BLE .resetting")
        case .unsupported:
            print("\(Date()) BLE .unsupported")
        case .unauthorized:
            print("\(Date()) BLE Bluetooth disabled for this app, pls enable it in settings")
        case .poweredOff:
            print("\(Date()) BLE turn on bluetooth")
            bleIsOff = true
        case .poweredOn:
            print("\(Date()) BLE everything is ok")
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
                } else if let systemConnected = manager
                            .retrieveConnectedPeripherals(withServices:
                                                            [myDesiredServiceId]).first {
                    print("\(Date()) CM DidUpdateState: connect from System connected")
                    connect(peripheral: systemConnected)
                } else {
                    // Not an error, simply the case that they've never paired
                    // before, or they did a manual unpair:
                    print("\(Date()) CM DidUpdateState: unpaired")
                    state = .disconnected
                    startScanning()
                }
            }
            
            // Did CoreBluetooth wake us up with a peripheral that was connecting?
            if case .restoringConnectingPeripheral(let peripheral) = state {
                print("\(Date()) CM DidUpdateState: connect from wakeup")
                connect(peripheral: peripheral)
            }
            
            // CoreBluetooth woke us with a 'connected' peripheral, but we had
            // to wait until 'poweredOn' state:
            if case .restoringConnectedPeripheral(let peripheral) = state {
                //Check if my Characteristic  was already stored in the peripheral given by "willRestoreState
                print("\(Date()) CM DidUpdateState: connect from wake up connected")
                if peripheral.myDesiredCharacteristic == nil {
                    print("\(Date()) CM DidUpdateState: connect from wake up connected - discover services etc")
                    discoverServices(peripheral: peripheral)
                } else {
                    //Service and Charachteristics already stored in the peripheral, no need to discover
                    // just
                    print("\(Date()) CM DidUpdateState: connect from wake up connected -  no need to discover")
                    setConnected(peripheral: peripheral)
                }
            }
            //Start scanning here!
            //startScanning()
            print("End of .poweredOn")
        @unknown default:
            print("◦ fatal")
        }
    }
    
    // Discovery (scanning) and handling of BLE devices in range
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard case .scanning = state else { return }
        scanning = true
        name = String(peripheral.name ?? "unknown")
        print("\(name) is found")
        print("\(Date()) CM DidDiscover")
        manager.stopScan()
        connect(peripheral: peripheral)
    }
    
    // Connection established handler
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("\(Date()) CM DidConnect")
        fileTransferOngoing = false
    
        // Clear the data that we may already have
        dataToSend.removeAll(keepingCapacity: false)
        
        // Make sure we get the discovery callbacks
        peripheral.delegate = self
        
        if peripheral.myDesiredCharacteristic == nil {
            //peripheral.discoverServices(nil)
            discoverServices(peripheral: peripheral)
        } else {
            setConnected(peripheral: peripheral)
        }
    }
    
    // Connection failed
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("\(Date()) CM DidFailToConnect")
        state = .disconnected
        cleanup()
    }
    
    // Disconnection (out of range, ...)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        fileTransferOngoing = false
        print("\(Date()) CM DidDisconnectPeripheral")
        print("◦ \(peripheral.name ?? "unknown") disconnected")
        
        cmdstat.statusFrequent.playing = false
        self.cmdstat.statusSeldom.downloading = false
        fileTransferOngoing = false
        self.stopProjectionTimer()
        self.showToast = true
        self.message = "No connection!"
        self.hapticSad()
        
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
                print("◦ connect: try reconnect when back in range")
                manager.connect(peripheral, options: nil)
                state = .outOfRange(peripheral)
            } else {
                // Likely a deliberate unpairing.
                state = .disconnected
            }
        }
    }
    /*
    // TODO try to remove the below function to silence CoreBluetooth warning at startup.
    // Apple says: This is the first method invoked when your app is relaunched
    // into the background to complete some Bluetooth-related task.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        print("\(Date()) CM WillRestoreState")
        let peripherals: [CBPeripheral] = dict[
            CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        if peripherals.count > 1 {
            print("Warning: willRestoreState called with >1 connection")
        }
        // We have a peripheral supplied, but we can't touch it until
        // `central.state == .poweredOn`, so we store it in the state
        // machine enum for later use.
        if let peripheral = peripherals.first {
            switch peripheral.state {
            case .connecting: // I've only seen this happen when
                // re-launching attached to Xcode.
                state = .restoringConnectingPeripheral(peripheral)
            case .connected: // Store for connection / requesting
                // notifications when BT starts.
                state = .restoringConnectedPeripheral(peripheral)
            default: break
            }
        }
    }
    */
    
    /*-------------------------------------------------------------------------------------------------------
            PERIPHERAL CALLBACK FUNCTIONS
    -------------------------------------------------------------------------------------------------------*/
    
    // Discover BLE device service(s)
    //@MY_BLE_ALSO
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print("\(Date()) PH didDiscoverServices")
        // Ignore services discovered late.
        guard case .discoveringServices = state else {
            return
        }
        if let error = error {
            print("Failed to discover services: \(error)")
            disconnect()
            return
        }
        guard peripheral.myDesiredService != nil else {
            print("Desired service missing")
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
        // Ignore characteristics arriving late.
        //guard case .discoveringCharacteristics = state else { return }
         
        if let error = error {
            print("Failed to discover characteristics: \(error)")
            disconnect()
            return
        }
        
        guard peripheral.myDesiredCharacteristic != nil else {
            print("Desired characteristic missing")
            disconnect()
            return
        }
        
        guard let characteristics = service.characteristics else {
            return
        }
        
        for characteristic in characteristics{
            switch characteristic.uuid {
            case readCharacteristicId:
                readCharacteristic = characteristic
                //print("◦ read from: \(readCharacteristic?.uuid as Any)")
                
            case commandCharacteristicId:
                writeCharacteristic = characteristic
                //print("◦ write to: \(writeCharacteristic!.uuid as Any)")
                
            case statusCharacteristicId:
                statusCharacteristic = characteristic
                //print("◦ notify from: \(statusCharacteristic!.uuid as Any)")
                peripheral.setNotifyValue(true, for: characteristic)

            case transferCharacteristicId:
                transferCharacteristic = characteristic
                //print("◦ transfer to: \(transferCharacteristic!.uuid as Any)")
                peripheral.setNotifyValue(false, for: characteristic)
                
            case otaCharacteristicId:
                otaCharacteristic = characteristic
                //print("◦ OTA firmware to: \(otaCharacteristic!.uuid as Any)")
                peripheral.setNotifyValue(false, for: characteristic)
                
            default:
                print("◦ unknown")
            }
        }
        // Ready to go!
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
            // First check if the incoming data is one byte length?
            // if so it's the peripheral acknowledging and telling
            // us to send another batch of data
            if data.count == 1 {
                print("\(Date()) -X-")
                if fileTransferOngoing {
                    packageCounter = 0
                    if OTAtransfer {
                        writeDataToPeripheral(characteristic: otaCharacteristic!)
                    } else {
                        writeDataToPeripheral(characteristic: transferCharacteristic!)
                    }
                }
            }
            // data.count is more than 1 byte
            // deal with incoming status information (JSON)
            let stringData = String(decoding: data, as: UTF8.self)
            let jsonDecoder = JSONDecoder()
            do {
                // This data lets the appknow static peripheral device information
                if stringData.contains("m02") {
                    let parsedJSON = try jsonDecoder.decode(StatusStatic.self, from: data)
                    DispatchQueue.main.async {
                        self.cmdstat.statusStatic = parsedJSON
                        
                        print("\(Date()) m02. FROM DEVICE----------------------------------")
                        print("model       : \(self.cmdstat.statusStatic.model)")
                        print("sn          : \(self.cmdstat.statusStatic.serialNumber)")
                        print("sw          : \(self.cmdstat.statusStatic.softwareVersion)")
                        print("MAC address : \(self.cmdstat.statusStatic.macAddress)")
                        print("USB power   : \(self.cmdstat.statusStatic.usbSourceAmpere)")
                        print("\(Date()) ---------------------------------------------------")
                        
                    }
                }
                // This data lets the app know seldom updated peripheral device information
                else if stringData.contains("m03") {
                    let parsedJSON = try jsonDecoder.decode(StatusSeldom.self, from: data)
                    DispatchQueue.main.async {
                        self.cmdstat.statusSeldom = parsedJSON
                        print("\(Date()) m03. FROM DEVICE----------------------------------")
                        print("eMMC status          : \(self.cmdstat.statusSeldom.eMmcOk)")
                        print("eMMC total size in MB: \(self.cmdstat.statusSeldom.eMmcTot)")
                        print("eMMC free size in MB : \(self.cmdstat.statusSeldom.eMmcFree)")
                        print("Downloading          : \(self.cmdstat.statusSeldom.downloading)")
                        print("Error BMP type       : \(self.cmdstat.statusSeldom.errorbmptype)")
                        print("Error file read      : \(self.cmdstat.statusSeldom.errorfileread)")
                        print("Error file type      : \(self.cmdstat.statusSeldom.errorfiletype)")
                        print("StripType            : \(self.cmdstat.statusSeldom.stripType)")
                        print("\(Date()) ---------------------------------------------------")
                    }
                    
                }
                // This data lets the app know frequently updated peripheral device information
                else if stringData.contains("m04") {
                    let parsedJSON = try jsonDecoder.decode(StatusFrequent.self, from: data)
                    DispatchQueue.main.async {
                        self.cmdstat.statusFrequent = parsedJSON
                        if self.cmdstat.statusFrequent.triggered {
                            if self.settings.main.hapticFeedbackCountdown {
                                self.hapticManager?.playStartStop()
                            }
                        }
                        if self.cmdstat.statusFrequent.done || self.cmdstat.statusFrequent.playing {
                            if self.settings.main.hapticFeedbackRun {
                                self.hapticManager?.playStartStop()
                            }
                        }
                        if self.cmdstat.statusFrequent.playing {
                            // 1. Set and start timer
                            
                            if !self.projectionTimerStarted {
                                print("\(Date()) Projection timeout (+5 sec): \(self.settings.main.projectionTime)")
                                self.projectionTimerStarted = true
                                self.startProjectionTimer(timeout: self.settings.main.projectionTime + 5)
                            }
                        }
                        if self.cmdstat.statusFrequent.done {
                            // 3. Stop projection timer
                            self.stopProjectionTimer()
                            self.projectionTimerStarted = false
                        }
                        /*
                        print("\(Date()) m04. FROM DEVICE----------------------------------")
                        print("Countdown : \(self.cmdstat.statusFrequent.countdown)")
                        print("Done      : \(self.cmdstat.statusFrequent.done)")
                        print("Image ok  : \(self.cmdstat.statusFrequent.imageisokok)")
                        print("Playing   : \(self.cmdstat.statusFrequent.playing)")
                        print("Stopped   : \(self.cmdstat.statusFrequent.stopped)")
                        print("Triggered : \(self.cmdstat.statusFrequent.triggered)")
                        print("\(Date()) ---------------------------------------------------")
                        */
                    }
                    
                }
                // This data lets the app know if a specific file is available and what CRC number it has
                else if stringData.contains("m08")
                {
                    let parsedJSON = try jsonDecoder.decode(AnyFileStatus.self, from: data)
                    DispatchQueue.main.async {
                        self.cmdstat.anyFileStatus = parsedJSON
                        print("\(Date()) m08. FROM DEVICE-----------------------")
                        print("\(Date()) Message ID     : \(self.cmdstat.anyFileStatus.m08)")
                        print("\(Date()) File name      : \(self.cmdstat.anyFileStatus.fileName)")
                        print("\(Date()) File extensiom : \(self.cmdstat.anyFileStatus.fileExtension)")
                        print("\(Date()) Available      : \(self.cmdstat.anyFileStatus.ok)")
                        print("\(Date()) CRC            : \(self.cmdstat.anyFileStatus.crc)")
                        self.sendFileFromBuffer()
                    }
                }
                // This data lets the app know the file transfer status
                else if stringData.contains("m09") {
                    let parsedJSON = try jsonDecoder.decode(FileTransferInfo.self, from: data)
                    DispatchQueue.main.async {
                        self.cmdstat.fileTransferInfo = parsedJSON
                        
                        
                        /*-----------------------------------------------
                        1. At this stage we get a reply from the server that
                           the transfer finnished (ok or not ok etc).
                           Check if the file transfered was a .bmp file
                           if so delete local bmp file. It's not needed anymore
                        -----------------------------------------------*/
                        /*
                        if self.cmdstat.fileTransferInfo.fileExtension == ".bmp" {
                            guard deleteFileIfItExist(subFolder: "image", fileName: self.cmdstat.fileTransferInfo.fileName, fileEnding: ".bmp") ?? false else {
                                print("failed to delete image bmp file")
                                return
                            }
                            guard deleteFileIfItExist(subFolder: "text", fileName: self.cmdstat.fileTransferInfo.fileName, fileEnding: ".bmp") ?? false else {
                                print("failed to delete text bmp file")
                                return
                            }
                        }
                        */
                        print("\(Date()) m09. FROM DEVICE-----------------------")
                       // print("\(Date()) Message ID: \(self.cmdstat.fileTransferInfo.m09)")
                        self.transferSuccessful = false
                        switch self.cmdstat.fileTransferInfo.transferResult {
                        case 0:
                            self.transferSuccessful = true
                            self.message = "Upload ok!"
                            if self.silentTransfer {
                                self.showToast = false
                            } else {
                                self.showToast = true
                            }
                            self.hapticHappy()
                            print("\(Date()) Transfer went fine")
                        case 1:
                            self.message = "Error: Failed to remove temporary storage file!"
                            self.showToast = true
                            self.hapticSad()
                            print("\(Date()) ****** Error: Failed to remove temporary storage file")
                        case 2:
                            self.message = "Error: Failed to write to eMMC!"
                            self.showToast = true
                            print("\(Date()) ****** Error: Failed to write to eMMC")
                            self.hapticSad()
                        case 3:
                            self.message = "Error: Downloaded file has wrong byte count. Packages missing!"
                            self.showToast = true
                            print("\(Date()) Error: Downloaded file has wrong byte count. Packages missing")
                            self.hapticSad()
                        case 4:
                            self.message = "Error: Failed to remove destination file!"
                            self.showToast = true
                            print("\(Date()) Error: Failed to remove destination file")
                            self.hapticSad()
                        case 5:
                            self.message = "Error: Failed to rename to destination file name!"
                            self.showToast = true
                            print("\(Date()) Error: Failed to rename to destination file name")
                            self.hapticSad()
                        case 6:
                            self.message = "Error: OTA boot partion corrupted!"
                            self.showToast = true
                            print("\(Date()) Error: OTA boot partion corrupted")
                            self.hapticSad()
                        case 7:
                            self.message = "Error: Failed to write start OTA handler!"
                            self.showToast = true
                            print("\(Date()) Error: Failed to write start OTA handler")
                            self.hapticSad()
                        case 8:
                            self.message = "Error: Failed to write buffer to OTA boot flash!"
                            self.showToast = true
                            print("\(Date()) Error: Failed to write buffer to OTA boot flash")
                            self.hapticSad()
                        case 9:
                            self.message = "Error: OTA end failed!"
                            self.showToast = true
                            print("\(Date()) Error: OTA end failed")
                            self.hapticSad()
                        case 10:
                            self.message = "Error: OTA boot partion settings error!"
                            self.showToast = true
                            print("\(Date()) Error: OTA boot partion settings error")
                            self.hapticSad()
                        case 11:
                            self.message = "Error: eMMC full (< 2 x file size)!"
                            self.showToast = true
                            print("\(Date()) Error: eMMC full (< 2 x file size)")
                            self.hapticSad()
                        default:
                            self.message = "Error: Unknown file transfer error!"
                            self.showToast = true
                            print("\(Date()) Unknown file transfer error")
                            self.hapticSad()
                        }
                    }
                }
                // This data lets the app know device parameter values
                else if stringData.contains("m14") {
                    let parsedJSON = try jsonDecoder.decode(Parmeter.self, from: data)
                    DispatchQueue.main.async {
                        self.cmdstat.parameter = parsedJSON
                        print("\(Date()) m14. FROM DEVICE-----------------------")
                        print("\(Date()) Parameter   : \(self.cmdstat.parameter.m14)")
                        print("\(Date()) Name        : \(self.cmdstat.parameter.name)")
                        print("\(Date()) Value       : \(self.cmdstat.parameter.value)")
                    }
                }
            } catch {
                print(error)
            }
        }
    }
    
    @objc func projectionTimeOut() {
        cmdstat.statusFrequent.playing = false
        print("\(Date()) Timeout Triggered")
        stopProjectionTimer()
        self.showToast = true
        self.message = "Projection timed out. Check LED controller!"
        self.hapticSad()
    }
    func stopProjectionTimer() {
        self.projectionTimer?.invalidate()
        //self.projectionTimer?.upstream.connect().cancel()
        projectionTimerStarted = false
        projectionTimer = nil
    }
    
    func startProjectionTimer(timeout: Double) {
        self.projectionTimer = Timer.scheduledTimer(timeInterval: timeout, target: self, selector: #selector(projectionTimeOut), userInfo: nil, repeats: false)
        
    }
    
    func hapticHappy() {
        if self.settings.main.hapticFeedbackUpload {
            self.hapticManager?.playStartStop()
            //AudioServicesPlayAlertSoundWithCompletion(SystemSoundID(kSystemSoundID_Vibrate)) { return }
        }
    }
    func hapticSad() {
        if self.settings.main.hapticFeedbackError {
            AudioServicesPlayAlertSoundWithCompletion(SystemSoundID(kSystemSoundID_Vibrate)) { return }
        }
    }
    
    // Called when .withResponse is used.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        print("\(Date()) PH didWriteValueFor")
        if let error = error {
            print("Error writing to characteristic: \(error)")
            return
        }
    }
    
    // Callback indicating peripheral notifying state
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        //print("\(Date()) PH didUpdateNotificationStateFor")
        //print("\(Date()) PH \(characteristic)")
        if error == nil {
            print("Notification Set OK, isNotifying: \(characteristic.isNotifying)")
            if !characteristic.isNotifying {
                print("isNotifying is false, set to true again!")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
    
    /*-------------------------------------------------------------------------
                                FUNCTIONS
     -------------------------------------------------------------------------*/

    /*-------------------------------------------------------------------------
     Send request to BLE periheral for status update
     -------------------------------------------------------------------------*/
    func askForStatus() {
        if connected && !self.cmdstat.statusSeldom.downloading {
            cmdstat.request.status = true
            cmdstat.request.crcList = false
            guard let encoded = try? JSONEncoder().encode(cmdstat.request) else {
                print("Failed to encode statusRequest")
                return
            }
            if !fileTransferOngoing{
                sendJsonBLE(messageData: encoded)
            }
        } else {
            return
        }
    }
    
    /*-------------------------------------------------------------------------
     Check leddevice.json availability
     -------------------------------------------------------------------------*/
    func checkLedDeviceJson() {
        
        // 1. send file/crc check to LED controller. ledcount not used for json files
        let crc = calculateCrc(folder: "", filename: "leddevice", fileEnding: ".json", ledcnt: 0)

        sendFileCheckToController(filename: "leddevice", fileExtension: ".json", crc: crc)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: {
            if !self.cmdstat.anyFileStatus.ok {
                self.sendFile(folder: "", filename: "leddevice", fileEnding: ".json", silent: true, completion: { (success) -> Void in
                    print(success)
                    print("leddevice.json was sent to controller")
                })
            }
        })
    }
    /*-------------------------------------------------------------------------
     Send file check request to LED controller
     -------------------------------------------------------------------------*/
    func sendFileCheckToController(filename: String, fileExtension: String, crc: UInt16) {
        
        //---------------------------------------
        // 1. Compose file check request
        //---------------------------------------
        cmdstat.anyFileStatus.m08           = 0
        cmdstat.anyFileStatus.fileName      = filename
        cmdstat.anyFileStatus.fileExtension = fileExtension
        cmdstat.anyFileStatus.crc           = crc
        cmdstat.anyFileStatus.ok            = false
        
        //---------------------------------------
        // 2. Encode json object
        //---------------------------------------
        guard let encoded = try? JSONEncoder().encode(cmdstat.anyFileStatus) else {
            print("Failed to encode systemCmd")
            return
        }
        
        //---------------------------------------
        // 3. Send json object over bluetooth
        //---------------------------------------
        if !fileTransferOngoing{
            sendJsonBLE(messageData: encoded)
        }
    }
    
    /*-------------------------------------------------------------------------
     TODO Who is calling this function?  Send resquest to BLE periheral for a
     list of filenames and crc numbers
     -------------------------------------------------------------------------*/
    func askForCrc() {
        if connected && !self.cmdstat.statusSeldom.downloading {
            cmdstat.request.status = false
            cmdstat.request.crcList = true
            guard let encoded = try? JSONEncoder().encode(cmdstat.request) else {
                print("Failed to encode statusRequest")
                return
            }
            if !fileTransferOngoing{
                sendJsonBLE(messageData: encoded)
            }
        } else {
            return
        }
    }
    
    // Scanning for device with a specific Service UUID (myDesiredServiceId)
    func startScanning() {
        print("\(Date()) FUNC StartScanning")
        scanning = true
        let impactHeavy = UIImpactFeedbackGenerator(style: .soft)
        impactHeavy.impactOccurred()
        guard manager.state == .poweredOn else {
            print("Cannot scan, BT is not powered on")
            scanning = false
            return
        }
        manager.scanForPeripherals(withServices: [myDesiredServiceId], options: nil)
        state = .scanning(Countdown(seconds: 10, closure: {
            self.scanning = false
            self.manager.stopScan()
            self.state = .disconnected
            print("Scan timed out")
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
        scanning = false
        fileTransferOngoing = false
    }
    
    // Connect to the device from the scanning
    func connect(peripheral: CBPeripheral){
        print("\(Date()) FUNC Connect")
        if connected {
            manager.cancelPeripheralConnection(peripheral)
        }else{
            // Connect!
            // Note: We're retaining the peripheral in the state enum because Apple
            // says: "Pending attempts are cancelled automatically upon
            // deallocation of peripheral"
            print("◦ connect: connect inside func connect()")
            manager.connect(peripheral, options: nil)
            name = String(peripheral.name ?? "unknown")
            print("\(name) is found")
            state = .connecting(peripheral, Countdown(seconds: 10, closure: {
                self.manager.cancelPeripheralConnection(self.state.peripheral!)
                self.state = .disconnected
                self.connected = false
                self.scanning = false
                print("Connect timed out")
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
            print("Could not discover services")
        }))
    }
    
    // Discover Characteristics of a Services
    func discoverCharacteristics(peripheral: CBPeripheral) {
        print("\(Date()) FUNC DiscoverCharacteristics")
        guard let myDesiredService = peripheral.myDesiredService else {
            self.disconnect()
            return
        }
        //peripheral.delegate = self
        peripheral.discoverCharacteristics([myDesiredCharacteristicId], for: myDesiredService)
        state = .discoveringCharacteristics(peripheral,
                                            Countdown(seconds: 10,
                                                      closure: {
                                                        self.disconnect()
                                                        print("Could not discover characteristics")
                                                      }))
    }
    
    func setConnected(peripheral: CBPeripheral) {
        print("\(Date()) FUNC SetConnected")
        print("Max write value with response: \(peripheral.maximumWriteValueLength(for: .withResponse))")
        print("Max write value without response: \(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        guard let myDesiredCharacteristic = peripheral.myDesiredCharacteristic
        else {
            print("Missing characteristic")
            disconnect()
            return
        }
        // Remember the ID for startup reconnecting.
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: peripheralIdDefaultsKey)
        UserDefaults.standard.synchronize()
        
        // Ask for notifications when the peripheral sends us data.
        // TODO another state waiting for this?
        //peripheral.delegate = MyPeripheralDelegate.shared
        //peripheral.delegate = self
        peripheral.setNotifyValue(true, for: myDesiredCharacteristic)
        state = .connected(peripheral)
        connected = true
        name = String(peripheral.name ?? "unknown")
        askForStatus()
        checkLedDeviceJson()
    }
    
    func send(_ value:[UInt8]){
        print("\(Date()) FUNC Send")
        if fileTransferOngoing {
            self.showToast = true
            self.message = "Uploading in progress please try again later"
            return
        }
        guard let characteristic = writeCharacteristic else{return}
        let data = Data(value)
        state.peripheral?.writeValue(data, for: characteristic, type: .withResponse)
    }
    
    func sendJsonBLE(messageData: Data){
        
        if cmdstat.statusFrequent.playing {
            self.showToast = true
            self.message = "LED projecting in progress. Please try again later"
            self.fileTransferOngoing = false
            return
        }
         
        print("\(Date()) FUNC SendJson")
        //print(writeCharacteristic!)
        
        guard let characteristic = writeCharacteristic else {
            self.fileTransferOngoing = false
            return
        }
        state.peripheral?.writeValue(messageData, for: characteristic, type: .withResponse)
    }
    
    // Peripheral callback when its ready to receive more data without response
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if fileTransferOngoing && packageCounter <= cmdstat.fileTransferInfo.bufferLoopTimes {
            if OTAtransfer {
                writeDataToPeripheral(characteristic: otaCharacteristic!)
            } else {
                writeDataToPeripheral(characteristic: transferCharacteristic!)
            }
        }
    }
    
    func method(arg: Bool, completion: (Bool) -> ()) {
        print("First line of code executed")
        // do stuff here to determine what you want to "send back".
        // we are just sending the Boolean value that was sent in "back"
        completion(arg)
    }
    
    func sendFile(folder: String, filename: String, fileEnding: String, silent: Bool, completion: @escaping (String) -> ()) {
        /*
        guard !fileTransferOngoing else {
            let temp = Files(id: 0, folder: folder, name: filename, type: fileEnding, crc: 0)
            fileBufferForSending.items.append(temp)
            //self.message = "Uploading in progress. Please try again later"
            //self.showToast = true
            completion("Error: Transfer Already In Progress")
            return
        }
        */
        silentTransfer = silent
        guard !cmdstat.statusFrequent.playing else {
            self.message = "LED display in progress. Please try again later"
            completion("Error: Projection In Progress")
            return
        }
        
        if fileEnding == ".bin" {
        // 1. Get the data from the file(name) and copy data to dataBUffer
            guard let data: Data = try? getBundleFileToData(fileName: filename, fileEnding: fileEnding) else {
                print("failed to open file in bundle")
                return
            }
            OTAtransfer = true
            dataBuffer = data
        } else {
            guard let data: Data = try? getDocumentFileToData(folder: folder, fileName: filename + fileEnding) else {
                print("failed to open file in document directory")
                return
            }
            OTAtransfer = false
            dataBuffer = data
        }
        
        // 2. File loaded into data object. Now send JSON info on upcomming file transfer
        fileEmpty = false
        dataLength = dataBuffer.count
        
        guard let discoveredPeripheral = state.peripheral else {return}
        
        cmdstat.fileTransferInfo.fileName = filename
        cmdstat.fileTransferInfo.fileExtension = fileEnding
        cmdstat.fileTransferInfo.fileSize = dataLength
        cmdstat.fileTransferInfo.transferResult = 99
        
        // (ATT MTU - 3 bytes)
        cmdstat.fileTransferInfo.chunkSize = discoveredPeripheral.maximumWriteValueLength (for: .withoutResponse) - 3
        
        if OTAtransfer {
            cmdstat.fileTransferInfo.bufferLoopTimes = 1//16
        } else {
            cmdstat.fileTransferInfo.bufferLoopTimes = 16//32//16//8
        }

        guard let encoded = try? JSONEncoder().encode(cmdstat.fileTransferInfo) else {
            print("Failed to encode cmd")
            return
        }
        
        // Send json with file transfer informatio (name, extension, datalength)
        print("file transfer information: \(encoded)")
        sendJsonBLE(messageData: encoded)
        
        // 3. Next Start actual data transmission after some time (300ms) to give the pheripheral time to receive all file information before the up/download start.
        packageCounter = 0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.cmdstat.fileTransferInfo.transferResult = 99
            self.transferSuccessful = false
            self.fileTransferOngoing = true
            if self.OTAtransfer {
                self.writeDataToPeripheral(characteristic: self.otaCharacteristic!)
                completion("first OTA writeDataToPeripheral function done")
            } else {
                self.writeDataToPeripheral(characteristic: self.transferCharacteristic!)
                completion("first File writeDataToPeripheral function done")
            }
        }
    }
    
    func writeDataToPeripheral(characteristic: CBCharacteristic) {
        
        // 1. Get the peripheral and it's transfer characteristic
        guard let discoveredPeripheral = state.peripheral else {return}
        
        // 2. Get the chunk size, create a range variable
        chunkSize = cmdstat.fileTransferInfo.chunkSize
        var range:Range<Data.Index>
        
        // 3. Loop through and send each chunk to the BLE device
        // check to see if number of iterations completed and peripheral can accept more data
        while fileTransferOngoing && discoveredPeripheral.canSendWriteWithoutResponse && packageCounter < cmdstat.fileTransferInfo.bufferLoopTimes {
            
            // 3.1. Create a range based on the length of data to return
            range = (0..<min(chunkSize, dataBuffer.count))
            
            // 3.2. Get a subcopy copy of data
            let subData = dataBuffer.subdata(in: range)
            stopTimer()
            startTimer()
            
            // 3.3. Send data chunk to BLE peripheral, send EOF when buffer is empty.
            if !dataBuffer.isEmpty {
                discoveredPeripheral.writeValue(subData, for: characteristic, type: .withoutResponse)
                packageCounter += 1
                print(" Packages: \(packageCounter) bytes: \(subData.count)")
            } else {
                fileEmpty = true
                OTAtransfer = false
                fileTransferOngoing = false
                stopTimer()
            }
            // 6. Remove already sent data from buffer
            dataBuffer.removeSubrange(range)
            
            // 7. calculate the transfer progress
            transferProgress = (1 - (Double(dataBuffer.count) / Double(dataLength))) * 100
        }
    }
    
    /*------------------------------------------------------------------
     Watchdog TimeOut for downloading, triggered if download stalled more
     than 2 seconds.
    ------------------------------------------------------------------*/
    @objc func uploadTimeOut() {
        fileEmpty = true
        OTAtransfer = false
        fileTransferOngoing = false
        transferSuccessful = false
        silentTransfer = false
        print("\(Date()) Timeout Triggered")
        stopTimer()
        self.message = "Upload failed, check the LED controller and try again!"
        if silentTransfer {
            self.showToast = false
        } else {
            self.showToast = true
        }
        self.hapticSad()
    }
    
    /*------------------------------------------------------------------
     Stop the watchdog TimeOut.
    ------------------------------------------------------------------*/
    func stopTimer() {
        self.timer?.invalidate()
        timer = nil
    }
    
    /*------------------------------------------------------------------
     Sart the watchdog TimeOut.
    ------------------------------------------------------------------*/
    func startTimer() {
        self.timer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(uploadTimeOut), userInfo: nil, repeats: true)
    }
    
    
    /*------------------------------------------------------------------
     Add a file to the transfer buffer.
    ------------------------------------------------------------------*/
    func addFileToSendBuffer(folder: String, filename: String, fileEnding: String, silent: Bool) {
        // 1. Make default FileItem
        var item = Files()
        
        // 2. Add folder, name, fileending and silent flag
        item.folder = folder
        item.name   = filename
        item.type   = fileEnding
        item.silent = silent
        
        // 3. Append item to colorItems and sort
        fileBufferForSending.items.append(item)
        print("Added \(filename) ")
        
    }
    /*------------------------------------------------------------------
     Send a file from the buffer.
    ------------------------------------------------------------------*/
    func sendFileFromBuffer() {
        //1. is file send ongoing?
        if fileTransferOngoing {return}
        //2. is file buffer empty?
        if fileBufferForSending.items.isEmpty {return}
        //3. Send one file via BLE
        sendFile(folder: fileBufferForSending.items[0].folder, filename: fileBufferForSending.items[0].name, fileEnding: fileBufferForSending.items[0].type, silent: fileBufferForSending.items[0].silent, completion: { (success) -> Void in
            print(success)
        })
        //2. Remove file from buffer
        print("Removed \(fileBufferForSending.items[0].name) ")
        fileBufferForSending.items.remove(at: 0)
        
    }
    
    /* TOD fix this...
     *  Call this when things either go wrong, or you're done with the connection.
     *  This cancels any subscriptions if there are any, or straight disconnects if not.
     *  (didUpdateNotificationStateForCharacteristic will cancel the connection if a subscription is involved)
     */
    private func cleanup() {
        // Don't do anything if we're not connected
        guard let discoveredPeripheral = state.peripheral,
            case .connected = discoveredPeripheral.state else { return }
        
        for service in (discoveredPeripheral.services ?? [] as [CBService]) {
            for characteristic in (service.characteristics ?? [] as [CBCharacteristic]) {
              /*  if characteristic.uuid == state.peripheral?.myDesiredService.characteristicUUID && characteristic.isNotifying {
                    // It is notifying, so unsubscribe
                    discoveredPeripheral.setNotifyValue(false, for: characteristic)
                }*/
            }
        }
        // If we've gotten this far, we're connected, but we're not subscribed, so we just disconnect
        manager.cancelPeripheralConnection(discoveredPeripheral)
    }
}

//@checked
extension CBPeripheral {
    /// Helper to find the service we're interested in.
    var myDesiredService: CBService? {
        guard let services = services else { return nil }
        return services.first { $0.uuid == myDesiredServiceId }
    }
    /// Helper to find the characteristic we're interested in.
    var myDesiredCharacteristic: CBCharacteristic? {
        guard let characteristics = myDesiredService?.characteristics else {
            return nil
        }
        //print(characteristics.first { $0.uuid == myDesiredCharacteristicId }!)
        return characteristics.first { $0.uuid == myDesiredCharacteristicId }
    }
}


extension Data {
    func hex() -> String{
        return map{
            String(format: "%02hhx", $0)
        }.joined()
    }
    func byte() -> String{
        return map{
            String(UInt32($0))
        }.joined()
    }
}



/// Read more: http://www.splinter.com.au/2019/03/28/timers-without-circular-references-with-pendulum
//@checked
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
