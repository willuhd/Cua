//
//  FEC.swift
//  dz
//
//  Packet-level erasure coding over GF(2^8).
//
//  Datagrams are the erasure unit, not bits: the frame header says how many
//  fragments there should be, so the receiver knows exactly which ones are
//  missing. That makes this an erasure code, far simpler and cheaper than an
//  error correcting one, because there is nothing to guess.
//
//  The ratio is fixed by settings.fecOverhead. Nothing here reacts to observed
//  loss: the user says how much redundancy to carry and that is what goes out.
//

import Foundation

/// Arithmetic in GF(256) modulo the AES polynomial, tables built once.
enum GF256 {
    static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 512)
        var x: UInt16 = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        for i in 255..<512 { table[i] = table[i - 255] }
        return table
    }()

    static let log: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        var x: UInt16 = 1
        for i in 0..<255 {
            table[Int(x)] = UInt8(i)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        return table
    }()

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    static func pow(_ a: UInt8, _ n: Int) -> UInt8 {
        if n == 0 { return 1 }
        if a == 0 { return 0 }
        return exp[(Int(log[Int(a)]) * n) % 255]
    }

    static func inv(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "zero has no inverse")
        return exp[255 - Int(log[Int(a)])]
    }
}

enum FECError: Error, CustomStringConvertible {
    case tooManyErasures(Int, Int)
    case singular

    var description: String {
        switch self {
        case .tooManyErasures(let lost, let available):
            return "lost blocks with only parity available"
        case .singular:
            return "parity system is singular"
        }
    }
}

/// Systematic Reed-Solomon over the fragments of one frame.
struct FEC {
    static func parityCount(for dataBlocks: Int, overhead: Double) -> Int {
        guard dataBlocks > 0, overhead > 0 else { return 0 }
        return max(0, Int((Double(dataBlocks) * overhead).rounded(.up)))
    }

    static func pad(_ block: Data, to length: Int) -> [UInt8] {
        var out = Array(block)
        if out.count < length { out += [UInt8](repeating: 0, count: length - out.count) }
        return out
    }

    /// Parity blocks for the given data blocks. Shorter blocks are zero padded.
    static func encode(data: [Data], parity: Int) -> [Data] {
        guard parity > 0, !data.isEmpty else { return [] }
        let k = data.count
        let length = data.map { $0.count }.max() ?? 0
        guard length > 0 else { return [] }
        let rows = data.map { pad($0, to: length) }

        var out: [Data] = []
        out.reserveCapacity(parity)
        for j in 0..<parity {
            let x = UInt8(j + 1)
            var acc = [UInt8](repeating: 0, count: length)
            for i in 0..<k {
                let coefficient = GF256.pow(x, i)
                if coefficient == 0 { continue }
                let row = rows[i]
                for b in 0..<length { acc[b] ^= GF256.mul(coefficient, row[b]) }
            }
            out.append(Data(acc))
        }
        return out
    }

    /// Rebuilds the full set of data blocks. Indices missing from received
    /// are the erasures.
    static func decode(received: [Int: Data], dataCount: Int, parity: [Data]) throws -> [Data] {
        let length = (Array(received.values) + parity).map { $0.count }.max() ?? 0
        let missing = (0..<dataCount).filter { received[$0] == nil }

        if missing.isEmpty {
            return (0..<dataCount).map { Data(pad(received[$0]!, to: length)) }
        }
        guard missing.count <= parity.count else {
            throw FECError.tooManyErasures(missing.count, parity.count)
        }

        let r = missing.count
        var matrix = [[UInt8]](repeating: [UInt8](repeating: 0, count: r), count: r)
        for j in 0..<r {
            let x = UInt8(j + 1)
            for (col, index) in missing.enumerated() { matrix[j][col] = GF256.pow(x, index) }
        }
        let inverse = try invert(matrix)

        var rhs = [[UInt8]](repeating: [UInt8](repeating: 0, count: length), count: r)
        for j in 0..<r {
            let x = UInt8(j + 1)
            var row = pad(parity[j], to: length)
            for i in 0..<dataCount where received[i] != nil {
                let coefficient = GF256.pow(x, i)
                if coefficient == 0 { continue }
                let known = pad(received[i]!, to: length)
                for b in 0..<length { row[b] ^= GF256.mul(coefficient, known[b]) }
            }
            rhs[j] = row
        }

        var out = [Data](repeating: Data(), count: dataCount)
        for i in 0..<dataCount where received[i] != nil {
            out[i] = Data(pad(received[i]!, to: length))
        }
        for (col, index) in missing.enumerated() {
            var block = [UInt8](repeating: 0, count: length)
            for j in 0..<r {
                let coefficient = inverse[col][j]
                if coefficient == 0 { continue }
                let row = rhs[j]
                for b in 0..<length { block[b] ^= GF256.mul(coefficient, row[b]) }
            }
            out[index] = Data(block)
        }
        return out
    }

    /// Gauss-Jordan inverse over GF(256).
    private static func invert(_ source: [[UInt8]]) throws -> [[UInt8]] {
        let n = source.count
        var a = source
        var inv = (0..<n).map { i in (0..<n).map { j in UInt8(i == j ? 1 : 0) } }
        for col in 0..<n {
            var pivot = col
            while pivot < n && a[pivot][col] == 0 { pivot += 1 }
            guard pivot < n else { throw FECError.singular }
            if pivot != col {
                a.swapAt(pivot, col)
                inv.swapAt(pivot, col)
            }
            let scale = GF256.inv(a[col][col])
            for j in 0..<n {
                a[col][j] = GF256.mul(a[col][j], scale)
                inv[col][j] = GF256.mul(inv[col][j], scale)
            }
            for row in 0..<n where row != col {
                let factor = a[row][col]
                if factor == 0 { continue }
                for j in 0..<n {
                    a[row][j] ^= GF256.mul(factor, a[col][j])
                    inv[row][j] ^= GF256.mul(factor, inv[col][j])
                }
            }
        }
        return inv
    }
}
