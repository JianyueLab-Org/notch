//
//  Wire.swift
//  NotchNotch agent plugin
//
//  The plugin side of the NotchNotch plugin protocol (apiVersion 1).
//

import Foundation

enum Wire {
    static func line(_ message: OutgoingMessage) -> Data {
        var object: [String: Any]
        switch message {
        case let .update(id, state, label, pid, cwd, alert):
            object = ["type": "session.update", "id": id, "state": state.rawValue, "label": label, "pid": pid, "alert": alert]
            if let cwd { object["cwd"] = cwd }
        case let .end(id, alert):
            object = ["type": "session.end", "id": id, "alert": alert]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    static func pollInterval(fromConfigLine line: String) -> Double? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["type"] as? String == "config",
              let values = object["values"] as? [String: Any],
              let interval = values["pollInterval"] as? Double,
              interval >= 1 else { return nil }
        return interval
    }
}
