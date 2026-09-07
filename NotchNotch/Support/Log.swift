//
//  Log.swift
//  NotchNotch
//
//  Centralised os.Logger instances. Prefer these over print(): they are cheap
//  enough to leave in shipping builds, and `log stream --predicate
//  'subsystem == "co.jianyuelab.NotchNotch"'` gives you the whole picture without
//  attaching a debugger — which matters a lot for an overlay whose bugs only show
//  up when you are *not* looking at Xcode.
//

import Foundation
import OSLog

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "co.jianyuelab.NotchNotch"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let geometry  = Logger(subsystem: subsystem, category: "geometry")
    static let window    = Logger(subsystem: subsystem, category: "window")
    static let hover     = Logger(subsystem: subsystem, category: "hover")
    static let state     = Logger(subsystem: subsystem, category: "state")
    static let privateAPI = Logger(subsystem: subsystem, category: "private-api")
    static let media     = Logger(subsystem: subsystem, category: "media")
}
