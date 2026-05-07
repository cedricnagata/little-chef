//
//  TimerWidgetBundle.swift
//  TimerWidget
//
//  Created by Cedric Nagata on 5/7/26.
//

import WidgetKit
import SwiftUI

@main
struct TimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerWidget()
        TimerWidgetControl()
    }
}
