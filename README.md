# Arduino-ESP32-NimBLE-OTA-iOS-SwiftUI
ESP32 OTA with SwiftUI over BLE using NimBLE

Arduino example (ESP32 core 1.06) for BLE OTA on a ESP32 using an iOS app

This is an demo on how to upload firmware (.bin file) from an iOS app to an ESP32.

The BLE stack is changed to NimBLE (using ver 1.3.1) for substantially lower memory footprint.

The app will auto connect to the ESP32 when it discovers the BLE service UUID of the ESP32 BLE device. It will also re-connect in situation when the ESP32 BLE device comes out of range and later returns in range.

Flash the ESP32 device with the .ino file via Arduino IDE and run the App in Xcode (tested on 12.3 for minimum iOS 14.0) on a real device (iPhone, iPad. Does not work on a simulator as they lack physical Bluetooth).

After starting the app, press "send .bin to ESP32 over OTA" to start the OTA file transfer. Watch the "Upload progress percentage" going from 0 to 100%. Once the upload is done the ESP32 waits 1 second and thereafter restarts.

Ported to Arduino code and based on chegewara example for ESP-IDF: https://github.com/chegewara/esp32-OTA-over-BLE
Bluetooth class (BLEConnection) in BluetootheLE.swift inspired by: purpln https://github.com/purpln/bluetooth and Chris Hulbert http://www.splinter.com.au/2019/05/18/ios-swift-bluetooth-le/
