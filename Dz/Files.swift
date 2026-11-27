//
//  Files.swift
//  dz
//
//  Remote file access for the other Mac's agents.
//
//  Everything is relative to one shared folder and nothing may escape it: a
//  path is resolved, then checked against the root, so ".." cannot walk out.
//  That check is the whole security model of this file and it is deliberately
//  the first thing each operation does.
//

import Foundation

enum Files {
    struct Entry {
        var path: String
        var directory: Bool
        var bytes: Int
        var modified: Date
    }

    enum Failure: Error, CustomStringConvertible {
        case noRoot
        case escaped(String)
        case missing(String)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .noRoot: return "no folder is shared yet; set one in the Remote tab"
            case .escaped(let p): return "path escapes the shared folder: " + p
            case .missing(let p): return "no such file: " + p
            case .tooLarge(let n): return "file is larger than the transfer limit: " + String(n) + " bytes"
            }
        }
    }

    static let maxReadBytes = 32 * 1024 * 1024

    static var root: URL? {
        guard let folder = MCPServer.shareFolder, !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func resolve(_ relative: String) throws -> URL {
        guard let root else { throw Failure.noRoot }
        let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw Failure.escaped(relative)
        }
        return candidate
    }

    /// Paths are reported relative to the root so a caller never has to know
    /// where the folder lives on the other machine.
    static func display(_ url: URL) -> String {
        guard let root else { return url.path }
        var path = url.path
        if path.hasPrefix(root.path) { path = String(path.dropFirst(root.path.count)) }
        return path.isEmpty ? "/" : path
    }

    static func list(_ relative: String) throws -> [Entry] {
        let target = try resolve(relative)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw Failure.missing(relative)
        }
        guard isDirectory.boolValue else { throw Failure.missing(relative) }
        let children = (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? []
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { child in
            let attributes = (try? fm.attributesOfItem(atPath: child.path)) ?? [:]
            var childDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: child.path, isDirectory: &childDirectory)
            return Entry(path: display(child),
                         directory: childDirectory.boolValue,
                         bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                         modified: attributes[.modificationDate] as? Date ?? Date())
        }
    }

    static func read(_ relative: String) throws -> Data {
        let target = try resolve(relative)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: target.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxReadBytes else { throw Failure.tooLarge(size) }
        guard let data = try? Data(contentsOf: target) else { throw Failure.missing(relative) }
        return data
    }

    static func write(_ relative: String, data: Data) throws {
        let target = try resolve(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target)
    }

    static func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: try resolve(relative), withIntermediateDirectories: true)
    }

    static func remove(_ relative: String) throws {
        let target = try resolve(relative)
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.missing(relative) }
        try FileManager.default.removeItem(at: target)
    }

    static func stat(_ relative: String) throws -> Entry {
        let target = try resolve(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw Failure.missing(relative)
        }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: target.path)) ?? [:]
        return Entry(path: display(target), directory: isDirectory.boolValue,
                     bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                     modified: attributes[.modificationDate] as? Date ?? Date())
    }
}
