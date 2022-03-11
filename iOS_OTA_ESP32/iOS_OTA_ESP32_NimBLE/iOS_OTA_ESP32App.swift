//
//  iOS_OTA_ESP32App.swift
//  iOS_OTA_ESP32
//
//  Created by Claes Hallberg on 1/25/21.
//

import SwiftUI

@main
struct iOS_OTA_ESP32App: App {
    var ble  = BLEConnection()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
        }
    }
}

