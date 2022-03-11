//
//  MyHelper.swift
//
//  Created by Claes Hallberg on 7/6/20.
//  Copyright © 2020 Claes Hallberg. All rights reserved.
//  Licence: MIT

import Foundation

/*----------------------------------------------------------------------------
 Load file (fileName: name.extension) return it in Data type
 Stored in App main bundle
----------------------------------------------------------------------------*/
func getBinFileToData(fileName: String, fileEnding: String) throws -> Data? {
    guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: fileEnding) else { return nil }
    do {
        let fileData = try Data(contentsOf: fileURL)
        return Data(fileData)
    } catch {
        print("Error loading file: \(error)")
        return nil
    }
}

