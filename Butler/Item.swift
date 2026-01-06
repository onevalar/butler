//
//  Item.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
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
