# Arduino-ESP32-NimBLE-OTA-iOS-SwiftUI

_NOTE! if you are experience problems with uncomplete uploads and error messages please see solution in issue #3_

ESP32 OTA with SwiftUI over BLE using NimBLE

Arduino example (ESP32 core 1.06) for BLE OTA on a ESP32 using an iOS app

This is an demo on how to upload firmware (.bin file) from an iOS app to an ESP32.

Using NimBLE stack (using ver 1.3.1) for substantially lower memory footprint.
![Simulator Screen Shot - iPhone 12 - 2022-03-12 at 09 12 20](https://user-images.githubusercontent.com/10321738/158010035-edb0e682-6b7b-4eec-89e5-b711f492a2dc.png)

iOS app shows upload transfer speed and elapsed time. Possible to set number of data chunks per write cycle to test optimal number of chunks before handshake signal needed from ESP32.

The app will auto connect to the ESP32 when it discovers the BLE service UUID of the ESP32 BLE device. It will also re-connect in situation when the ESP32 BLE device comes out of range and later returns in range.

Flash the ESP32 device with the .ino file via Arduino IDE and run the App in Xcode (tested on 12.3 for minimum iOS 14.0) on a real device (iPhone, iPad. Simulator does not work).

After starting the app, press "send .bin to ESP32 over OTA" to start the OTA file transfer. Watch the "Upload progress percentage" going from 0 to 100%. Once the upload is done the ESP32 waits 1 second and thereafter restarts.

Ported to Arduino code and based on chegewara example for ESP-IDF: https://github.com/chegewara/esp32-OTA-over-BLE
Bluetooth class (BLEConnection) in BluetootheLE.swift inspired by: purpln https://github.com/purpln/bluetooth and Chris Hulbert http://www.splinter.com.au/2019/05/18/ios-swift-bluetooth-le/
