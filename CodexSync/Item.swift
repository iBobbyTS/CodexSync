//
//  Item.swift
//  CodexSync
//
//  Created by iBobby on 2026-06-01.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
