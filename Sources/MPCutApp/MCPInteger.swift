import CoreFoundation
import Foundation

/// Bridge JSON integers without rounding through Double or accepting a JSON boolean.
func mcpInteger(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number as? Int
}
