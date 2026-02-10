//
//  Item.swift
//  Reddot
//
//  Created by zhangyuanyuan on 2026/2/10.
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
