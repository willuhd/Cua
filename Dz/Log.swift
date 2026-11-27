import Foundation

// MARK: – logging (no disk, just stderr/console)
func clog(_ s: String) { NSLog("cua: %@", s) }
func intVal(_ v: Any?) -> Int {
    if let i = v as? Int { return i }
    if let i = v as? Int32 { return Int(i) }
    if let n = v as? NSNumber { return n.intValue }
    return 0
}

