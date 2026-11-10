//
//  StrictJSON.swift
//  NotchNotch
//
//  JSONSerialization hands numbers and booleans back as NSNumber, which
//  bridges `true` to 1 and `1` to true. These read a value with its JSON type
//  intact. Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated enum StrictJSON {

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Integers only: JSON booleans and fractions are rejected.
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }
}
