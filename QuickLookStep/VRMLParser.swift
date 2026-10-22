import Foundation
import Compression
import simd

// A small, dependency-free VRML 2.0 (VRML97) reader covering the subset that
// KiCad writes: Transform/Group hierarchies of Shapes with Materials and
// IndexedFaceSets, DEF/USE, optional gzip compression. Everything else is
// skipped. The output is flattened into world-space triangle meshes, one per
// Shape, so it can be turned into SceneKit geometry (or benchmarked) without
// any further knowledge of VRML.

struct VRMLMaterial: Hashable {
    var diffuse = SIMD3<Float>(0.8, 0.8, 0.8)
    var specular = SIMD3<Float>(0, 0, 0)
    var emissive = SIMD3<Float>(0, 0, 0)
    /// VRML shininess in [0, 1]; the Blinn exponent is `shininess * 128`.
    var shininess: Float = 0.2
    var transparency: Float = 0
}

struct VRMLPart {
    /// World-space xyz triples.
    var positions: [Float]
    /// Unit normals, one per position.
    var normals: [Float]
    var indices: [UInt32]
    /// `nil` when the Shape has no Material (VRML says: unlit; we use white).
    var material: VRMLMaterial?

    var vertexCount: Int { positions.count / 3 }
    var triangleCount: Int { indices.count / 3 }
}

struct VRMLScene {
    var parts: [VRMLPart] = []
    var boundsMin = SIMD3<Float>(repeating: .infinity)
    var boundsMax = SIMD3<Float>(repeating: -.infinity)
    /// Inline nodes are never followed (the sandbox only grants the previewed file).
    var skippedInlines = 0

    var triangleCount: Int { parts.reduce(0) { $0 + $1.triangleCount } }
    var vertexCount: Int { parts.reduce(0) { $0 + $1.vertexCount } }
}

enum VRMLError: LocalizedError {
    case notVRML(String)
    case vrml1
    case decompressionFailed(String)
    case unexpectedEOF(line: Int)
    case unexpectedToken(expected: String, found: String, line: Int)
    case indexOutOfRange(kind: String, index: Int, count: Int, line: Int)
    case undefinedUSE(name: String, line: Int)
    case malformed(String, line: Int)
    case tooComplex(String)
    case noGeometry

    var errorDescription: String? {
        switch self {
        case .notVRML(let header):
            return "Not a VRML 2.0 file (header: \"\(header)\")"
        case .vrml1:
            return "VRML 1.0 files are not supported; only VRML 2.0 (VRML97)"
        case .decompressionFailed(let reason):
            return "Could not decompress gzipped VRML: \(reason)"
        case .unexpectedEOF(let line):
            return "Unexpected end of file at line \(line) (file truncated?)"
        case .unexpectedToken(let expected, let found, let line):
            return "Expected \(expected) but found \(found) at line \(line)"
        case .indexOutOfRange(let kind, let index, let count, let line):
            return "\(kind) value \(index) is out of range (\(count) available) in IndexedFaceSet at line \(line)"
        case .undefinedUSE(let name, let line):
            return "USE of undefined name \"\(name)\" at line \(line)"
        case .malformed(let reason, let line):
            return "\(reason) at line \(line)"
        case .tooComplex(let reason):
            return "VRML file is too complex: \(reason)"
        case .noGeometry:
            return "VRML file contains no displayable geometry"
        }
    }
}

enum VRMLParser {
    static func parse(url: URL) throws -> VRMLScene {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> VRMLScene {
        let source = isGzip(data) ? try gunzip(data) : data
        guard !source.isEmpty else { throw VRMLError.notVRML("file is empty") }
        return try source.withUnsafeBytes { raw -> VRMLScene in
            let reader = Reader(raw.bindMemory(to: UInt8.self))
            try reader.checkHeader()
            let roots = try reader.parseFile()

            var flattener = Flattener(reader: reader)
            for root in roots {
                try flattener.walk(root, matrix_identity_float4x4, depth: 0)
            }
            var scene = flattener.scene
            scene.skippedInlines = reader.skippedInlines
            if scene.skippedInlines > 0 {
                NSLog("VRMLParser: skipped %d Inline node(s); referenced files are not loaded", scene.skippedInlines)
            }
            guard !scene.parts.isEmpty else { throw VRMLError.noGeometry }
            return scene
        }
    }

    // MARK: - gzip

    private static let maxDecompressedSize = 1 << 30

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Strips the gzip header and inflates the raw deflate payload with the
    /// Compression framework (whose `COMPRESSION_ZLIB` is raw deflate).
    static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { raw -> Data in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            // 10 byte header + 8 byte trailer at minimum.
            guard n >= 18 else { throw VRMLError.decompressionFailed("file is truncated") }
            guard b[2] == 8 else { throw VRMLError.decompressionFailed("unsupported compression method \(b[2])") }
            let flags = b[3]
            var j = 10
            if flags & 0x04 != 0 { // FEXTRA
                guard j + 2 <= n else { throw VRMLError.decompressionFailed("header is truncated") }
                j += 2 + (Int(b[j]) | Int(b[j + 1]) << 8)
            }
            for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
                while j < n && b[j] != 0 { j += 1 }
                j += 1
            }
            if flags & 0x02 != 0 { j += 2 } // FHCRC
            guard j < n else { throw VRMLError.decompressionFailed("header is truncated") }

            // ISIZE (uncompressed size mod 2^32) is only a capacity hint.
            let sizeHint = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
            var out = Data()
            out.reserveCapacity(min(max(sizeHint, n * 4), 256 << 20))

            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw VRMLError.decompressionFailed("could not initialise decoder")
            }
            defer { compression_stream_destroy(stream) }

            let chunk = 1 << 20
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { dst.deallocate() }
            stream.pointee.src_ptr = b.baseAddress! + j
            stream.pointee.src_size = n - j

            while true {
                let srcBefore = stream.pointee.src_size
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                out.append(dst, count: produced)
                guard out.count <= maxDecompressedSize else {
                    throw VRMLError.decompressionFailed("decompressed size exceeds 1 GB")
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return out
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.pointee.src_size == srcBefore {
                        throw VRMLError.decompressionFailed("compressed data is truncated")
                    }
                default:
                    throw VRMLError.decompressionFailed("compressed data is corrupt or truncated")
                }
            }
        }
    }
}

// MARK: - Scene graph

private class Node {}

private final class OtherNode: Node {}

private final class TransformNode: Node {
    var translation = SIMD3<Float>(0, 0, 0)
    var rotation = SIMD4<Float>(0, 0, 1, 0) // axis xyz, angle (radians)
    var scale = SIMD3<Float>(1, 1, 1)
    var center = SIMD3<Float>(0, 0, 0)
    var children: [Node] = []

    /// T × C × R × S × C⁻¹ (scaleOrientation is ignored).
    var matrix: simd_float4x4 {
        func translate(_ v: SIMD3<Float>) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(v, 1)
            return m
        }
        let axis = SIMD3<Float>(rotation.x, rotation.y, rotation.z)
        let axisLength = simd_length(axis)
        let r: simd_float4x4
        if axisLength > 1e-12 && rotation.w.isFinite && rotation.w != 0 {
            r = simd_float4x4(simd_quatf(angle: rotation.w, axis: axis / axisLength))
        } else {
            r = matrix_identity_float4x4
        }
        let s = simd_float4x4(diagonal: SIMD4<Float>(scale, 1))
        return translate(translation) * translate(center) * r * s * translate(-center)
    }
}

private final class GroupNode: Node {
    var children: [Node] = []
}

private final class ShapeNode: Node {
    var appearance: AppearanceNode?
    var geometry: IFSNode?
}

private final class AppearanceNode: Node {
    var material: MaterialNode?
}

private final class MaterialNode: Node {
    var material = VRMLMaterial()
}

private final class CoordinateNode: Node {
    var points: [Float] = []
}

private final class NormalNode: Node {
    var vectors: [Float] = []
}

/// Triangulated IndexedFaceSet in its own coordinate system.
private struct LocalMesh {
    var positions: [Float] = []
    var normals: [Float] = []
    var indices: [UInt32] = []
}

private final class IFSNode: Node {
    var coord: CoordinateNode?
    var normal: NormalNode?
    var coordIndex: [Int32] = []
    var normalIndex: [Int32] = []
    var ccw = true
    var normalPerVertex = true
    /// Byte offset of the node, for error messages.
    var offset = 0
    /// Triangulated once, reused for every USE.
    var localMesh: LocalMesh?
}

// MARK: - Tokenizer + parser

private enum Char {
    static let lbrace = UInt8(ascii: "{"), rbrace = UInt8(ascii: "}")
    static let lbracket = UInt8(ascii: "["), rbracket = UInt8(ascii: "]")
    static let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), comma = UInt8(ascii: ",")
    static let backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
    static let minus = UInt8(ascii: "-"), plus = UInt8(ascii: "+"), dot = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
}

private struct Word {
    let s: Int
    let e: Int
}

private let powersOfTen: [Double] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]

private final class Reader {
    let p: UnsafePointer<UInt8>
    let n: Int
    var i = 0
    var defs: [String: Node] = [:]
    var skippedInlines = 0
    private var depth = 0
    private static let maxDepth = 100 // keeps recursion well inside a 512 KB thread stack, even in Debug

    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        p = buffer.baseAddress!
        n = buffer.count
    }

    // MARK: Errors

    func line(at offset: Int) -> Int {
        var line = 1
        var k = 0
        let end = min(offset, n)
        while k < end {
            if p[k] == Char.newline { line += 1 }
            k += 1
        }
        return line
    }

    func eof() -> VRMLError {
        .unexpectedEOF(line: line(at: n))
    }

    func unexpected(_ expected: String) -> VRMLError {
        skipWhitespace()
        let found: String
        if i >= n {
            return eof()
        } else if isDelimiter(p[i]) {
            found = "'\(Character(Unicode.Scalar(p[i])))'"
        } else {
            var e = i
            while e < n && !isDelimiter(p[e]) && e - i < 32 { e += 1 }
            found = "\"\(string(Word(s: i, e: e)))\""
        }
        return .unexpectedToken(expected: expected, found: found, line: line(at: i))
    }

    // MARK: Header

    func checkHeader() throws {
        var j = 0
        if n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF { j = 3 } // UTF-8 BOM
        func hasPrefix(_ lit: StaticString) -> Bool {
            let len = lit.utf8CodeUnitCount
            return n - j >= len && memcmp(p + j, lit.utf8Start, len) == 0
        }
        if hasPrefix("#VRML V2.0") {
            i = j // the header line is a comment, skipped by the tokenizer
            return
        }
        if hasPrefix("#VRML V1.0") { throw VRMLError.vrml1 }
        var e = j
        while e < n && e - j < 40 && p[e] != Char.newline && p[e] != Char.cr { e += 1 }
        let header = String(decoding: UnsafeBufferPointer(start: p + j, count: e - j), as: UTF8.self)
            .map { $0.isASCII && !$0.isWhitespace || $0 == " " ? $0 : "?" }
        throw VRMLError.notVRML(String(header))
    }

    // MARK: Lexing

    @inline(__always)
    func isDelimiter(_ c: UInt8) -> Bool {
        c <= 32 || c == Char.comma || c == Char.lbrace || c == Char.rbrace
            || c == Char.lbracket || c == Char.rbracket || c == Char.quote || c == Char.hash
    }

    @inline(__always)
    func skipWhitespace() {
        while i < n {
            let c = p[i]
            if c <= 32 || c == Char.comma {
                i += 1
            } else if c == Char.hash {
                while i < n && p[i] != Char.newline && p[i] != Char.cr { i += 1 }
            } else {
                return
            }
        }
    }

    /// Next non-whitespace byte, not consumed. Throws at end of file.
    @inline(__always)
    func peek() throws -> UInt8 {
        skipWhitespace()
        guard i < n else { throw eof() }
        return p[i]
    }

    func expect(_ c: UInt8, _ what: String) throws {
        guard try peek() == c else { throw unexpected(what) }
        i += 1
    }

    func readWord(_ what: String = "identifier") throws -> Word {
        skipWhitespace()
        guard i < n else { throw eof() }
        let s = i
        while i < n && !isDelimiter(p[i]) { i += 1 }
        guard i > s else { throw unexpected(what) }
        return Word(s: s, e: i)
    }

    @inline(__always)
    func eq(_ w: Word, _ lit: StaticString) -> Bool {
        let len = lit.utf8CodeUnitCount
        return w.e - w.s == len && memcmp(p + w.s, lit.utf8Start, len) == 0
    }

    func string(_ w: Word) -> String {
        String(decoding: UnsafeBufferPointer(start: p + w.s, count: w.e - w.s), as: UTF8.self)
    }

    @inline(__always)
    func isNumberStart(_ c: UInt8) -> Bool {
        (c &- Char.zero) < 10 || c == Char.minus || c == Char.plus || c == Char.dot
    }

    /// Skips a balanced `{ … }` or `[ … ]` group starting at the current byte.
    func skipBalanced() throws {
        var level = 0
        while i < n {
            let c = p[i]
            if c == Char.lbrace || c == Char.lbracket {
                level += 1
            } else if c == Char.rbrace || c == Char.rbracket {
                level -= 1
                if level == 0 { i += 1; return }
            } else if c == Char.quote {
                try skipString()
                continue
            } else if c == Char.hash {
                while i < n && p[i] != Char.newline && p[i] != Char.cr { i += 1 }
                continue
            }
            i += 1
        }
        throw eof()
    }

    func skipString() throws {
        i += 1
        while i < n {
            let c = p[i]
            if c == Char.backslash {
                i += 2
            } else if c == Char.quote {
                i += 1
                return
            } else {
                i += 1
            }
        }
        throw eof()
    }

    // MARK: Numbers

    func readNumber() throws -> Float {
        let w = try readWord("number")
        guard isNumberStart(p[w.s]) else { i = w.s; throw unexpected("number") }
        return Float(try parseDouble(w))
    }

    /// Exact fast path for the common case (≤ 19 significant digits, small
    /// exponent), otherwise Swift's `Double(String)`.
    @inline(__always)
    func parseDouble(_ w: Word) throws -> Double {
        var j = w.s
        let e = w.e
        var negative = false
        if p[j] == Char.minus { negative = true; j += 1 } else if p[j] == Char.plus { j += 1 }
        var mantissa: UInt64 = 0
        var digits = 0
        var exponent = 0
        var sawDigit = false
        while j < e {
            let d = p[j] &- Char.zero
            guard d < 10 else { break }
            mantissa = mantissa &* 10 &+ UInt64(d)
            if mantissa != 0 { digits += 1 }
            sawDigit = true
            j += 1
        }
        if j < e && p[j] == Char.dot {
            j += 1
            while j < e {
                let d = p[j] &- Char.zero
                guard d < 10 else { break }
                mantissa = mantissa &* 10 &+ UInt64(d)
                if mantissa != 0 { digits += 1 }
                exponent -= 1
                sawDigit = true
                j += 1
            }
        }
        if j < e && (p[j] | 0x20) == UInt8(ascii: "e") {
            j += 1
            var expNegative = false
            if j < e && p[j] == Char.minus { expNegative = true; j += 1 } else if j < e && p[j] == Char.plus { j += 1 }
            var exp = 0
            var sawExpDigit = false
            while j < e {
                let d = p[j] &- Char.zero
                guard d < 10, exp < 10_000 else { break }
                exp = exp * 10 + Int(d)
                sawExpDigit = true
                j += 1
            }
            if !sawExpDigit { return try parseDoubleSlow(w) }
            exponent += expNegative ? -exp : exp
        }
        guard j == e, sawDigit, digits <= 19 else { return try parseDoubleSlow(w) }
        if mantissa == 0 { return negative ? -0.0 : 0.0 }
        guard mantissa < (1 << 53), exponent >= -22, exponent <= 22 else { return try parseDoubleSlow(w) }
        var value = Double(mantissa)
        value = exponent < 0 ? value / powersOfTen[-exponent] : value * powersOfTen[exponent]
        return negative ? -value : value
    }

    func parseDoubleSlow(_ w: Word) throws -> Double {
        guard w.e - w.s < 64 else { throw VRMLError.malformed("Number is too long", line: line(at: w.s)) }
        // Swift's parser is locale-independent (unlike plain strtod).
        guard let value = Double(string(w)), value.isFinite else {
            throw VRMLError.malformed("Invalid number \"\(string(w))\"", line: line(at: w.s))
        }
        return value
    }

    func readInt() throws -> Int32 {
        let w = try readWord("integer")
        var j = w.s
        var negative = false
        if p[j] == Char.minus { negative = true; j += 1 } else if p[j] == Char.plus { j += 1 }
        if j < w.e && w.e - j <= 9 {
            var value: Int32 = 0
            while j < w.e {
                let d = p[j] &- Char.zero
                guard d < 10 else { break }
                value = value * 10 + Int32(d)
                j += 1
            }
            if j == w.e { return negative ? -value : value }
        }
        // Hex, exponents, or very long numbers.
        guard isNumberStart(p[w.s]) else { i = w.s; throw unexpected("integer") }
        let d = try parseDouble(w)
        guard d == d.rounded(), let value = Int32(exactly: d) else {
            throw VRMLError.malformed("Invalid integer \"\(string(w))\"", line: line(at: w.s))
        }
        return value
    }

    func readBool() throws -> Bool {
        let w = try readWord("TRUE or FALSE")
        if eq(w, "TRUE") { return true }
        if eq(w, "FALSE") { return false }
        i = w.s
        throw unexpected("TRUE or FALSE")
    }

    func readVec3() throws -> SIMD3<Float> {
        SIMD3(try readNumber(), try readNumber(), try readNumber())
    }

    /// MFFloat / MFVec3f: `[ … ]` or a single unbracketed value.
    func readFloatArray(multipleOf stride: Int, field: String) throws -> [Float] {
        let start = i
        var out: [Float] = []
        if try peek() == Char.lbracket {
            i += 1
            while try peek() != Char.rbracket {
                out.append(try readNumber())
            }
            i += 1
        } else {
            for _ in 0..<stride { out.append(try readNumber()) }
        }
        guard out.count % stride == 0 else {
            throw VRMLError.malformed("\(field) has \(out.count) values, not a multiple of \(stride)", line: line(at: start))
        }
        return out
    }

    func readIntArray() throws -> [Int32] {
        var out: [Int32] = []
        if try peek() == Char.lbracket {
            i += 1
            while try peek() != Char.rbracket {
                out.append(try readInt())
            }
            i += 1
        } else {
            out.append(try readInt())
        }
        return out
    }

    // MARK: Statements

    func parseFile() throws -> [Node] {
        var roots: [Node] = []
        while true {
            skipWhitespace()
            if i >= n { return roots }
            if let node = try parseStatement() { roots.append(node) }
        }
    }

    /// A node statement, or a PROTO/EXTERNPROTO/ROUTE statement (skipped → nil).
    func parseStatement() throws -> Node? {
        let w = try readWord("node")
        if eq(w, "ROUTE") {
            _ = try readWord(); _ = try readWord(); _ = try readWord() // a.b TO c.d
            return nil
        }
        if eq(w, "PROTO") {
            _ = try readWord("PROTO name")
            guard try peek() == Char.lbracket else { throw unexpected("'['") }
            try skipBalanced()
            guard try peek() == Char.lbrace else { throw unexpected("'{'") }
            try skipBalanced()
            return nil
        }
        if eq(w, "EXTERNPROTO") {
            _ = try readWord("EXTERNPROTO name")
            guard try peek() == Char.lbracket else { throw unexpected("'['") }
            try skipBalanced()
            try skipFieldValue()
            return nil
        }
        return try parseNode(after: w)
    }

    func parseNode(after w: Word) throws -> Node? {
        if eq(w, "DEF") {
            let name = string(try readWord("DEF name"))
            let node = try parseNode(after: try readWord("node"))
            if let node { defs[name] = node }
            return node
        }
        if eq(w, "USE") {
            let nameWord = try readWord("USE name")
            guard let node = defs[string(nameWord)] else {
                throw VRMLError.undefinedUSE(name: string(nameWord), line: line(at: nameWord.s))
            }
            return node
        }
        if eq(w, "NULL") { return nil }

        depth += 1
        defer { depth -= 1 }
        guard depth <= Reader.maxDepth else {
            throw VRMLError.tooComplex("nodes nested more than \(Reader.maxDepth) deep")
        }

        if eq(w, "Transform") { return try parseTransform() }
        if eq(w, "Shape") { return try parseShape() }
        if eq(w, "Appearance") { return try parseAppearance() }
        if eq(w, "Material") { return try parseMaterial() }
        if eq(w, "IndexedFaceSet") { return try parseIFS(offset: w.s) }
        if eq(w, "Coordinate") { return try parseCoordinate() }
        if eq(w, "Normal") { return try parseNormal() }
        if eq(w, "Group") || eq(w, "Anchor") || eq(w, "Billboard") || eq(w, "Collision") {
            return try parseGroup(listField: "children", firstOnly: false)
        }
        if eq(w, "LOD") { return try parseGroup(listField: "level", firstOnly: true) }
        if eq(w, "Switch") { return try parseGroup(listField: "choice", firstOnly: true) }
        if eq(w, "Inline") { skippedInlines += 1 }

        guard try peek() == Char.lbrace else { throw unexpected("'{' after \(string(w))") }
        try skipBalanced()
        return OtherNode()
    }

    /// Parses `{ field value … }`. `handle` returns false for fields it does not
    /// know, whose values are then skipped.
    @inline(__always)
    func parseBody(_ handle: (Word) throws -> Bool) throws {
        try expect(Char.lbrace, "'{'")
        while true {
            if try peek() == Char.rbrace { i += 1; return }
            let w = try readWord("field name")
            if try handle(w) { continue }
            if eq(w, "ROUTE") || eq(w, "PROTO") || eq(w, "EXTERNPROTO") {
                i = w.s
                _ = try parseStatement()
                continue
            }
            try skipFieldValue()
        }
    }

    /// Skips the value of a field we don't interpret, without knowing its type.
    func skipFieldValue() throws {
        let c = try peek()
        if c == Char.lbracket || c == Char.lbrace { try skipBalanced(); return }
        if c == Char.quote { try skipString(); return }
        if c == Char.rbrace || c == Char.rbracket { return }
        let w = try readWord("field value")
        if isNumberStart(p[w.s]) || eq(w, "TRUE") || eq(w, "FALSE") {
            // Scalar(s): consume until the next field name or '}'.
            while true {
                skipWhitespace()
                guard i < n else { return }
                if p[i] == Char.quote { try skipString(); continue }
                if isDelimiter(p[i]) { return }
                let next = try readWord()
                if !(isNumberStart(p[next.s]) || eq(next, "TRUE") || eq(next, "FALSE")) {
                    i = next.s
                    return
                }
            }
        }
        _ = try parseNode(after: w) // SFNode value: DEF/USE/NULL/Type { … }
    }

    func parseSFNode() throws -> Node? {
        try parseNode(after: try readWord("node"))
    }

    /// MFNode: `[ … ]` or a single node.
    func parseNodeList() throws -> [Node] {
        guard try peek() == Char.lbracket else {
            return try parseSFNode().map { [$0] } ?? []
        }
        i += 1
        var list: [Node] = []
        while try peek() != Char.rbracket {
            if let node = try parseStatement() { list.append(node) }
        }
        i += 1
        return list
    }

    // MARK: Nodes

    func parseTransform() throws -> Node {
        let t = TransformNode()
        try parseBody { w in
            if eq(w, "children") { t.children = try parseNodeList() }
            else if eq(w, "translation") { t.translation = try readVec3() }
            else if eq(w, "rotation") { t.rotation = SIMD4(try readVec3(), try readNumber()) }
            else if eq(w, "scale") { t.scale = try readVec3() }
            else if eq(w, "center") { t.center = try readVec3() }
            else { return false }
            return true
        }
        return t
    }

    func parseGroup(listField: StaticString, firstOnly: Bool) throws -> Node {
        let g = GroupNode()
        try parseBody { w in
            guard eq(w, listField) || eq(w, "children") else { return false }
            let list = try parseNodeList()
            g.children = firstOnly ? Array(list.prefix(1)) : list
            return true
        }
        return g
    }

    func parseShape() throws -> Node {
        let s = ShapeNode()
        try parseBody { w in
            if eq(w, "appearance") { s.appearance = try parseSFNode() as? AppearanceNode }
            else if eq(w, "geometry") { s.geometry = try parseSFNode() as? IFSNode }
            else { return false }
            return true
        }
        return s
    }

    func parseAppearance() throws -> Node {
        let a = AppearanceNode()
        try parseBody { w in
            guard eq(w, "material") else { return false }
            a.material = try parseSFNode() as? MaterialNode
            return true
        }
        return a
    }

    func parseMaterial() throws -> Node {
        let m = MaterialNode()
        func unit(_ v: Float) -> Float { min(max(v, 0), 1) }
        func unit(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_clamp(v, SIMD3(repeating: 0), SIMD3(repeating: 1)) }
        try parseBody { w in
            if eq(w, "diffuseColor") { m.material.diffuse = unit(try readVec3()) }
            else if eq(w, "specularColor") { m.material.specular = unit(try readVec3()) }
            else if eq(w, "emissiveColor") { m.material.emissive = unit(try readVec3()) }
            else if eq(w, "shininess") { m.material.shininess = unit(try readNumber()) }
            else if eq(w, "transparency") { m.material.transparency = unit(try readNumber()) }
            else { return false }
            return true
        }
        return m
    }

    func parseIFS(offset: Int) throws -> Node {
        let f = IFSNode()
        f.offset = offset
        try parseBody { w in
            if eq(w, "coord") { f.coord = try parseSFNode() as? CoordinateNode }
            else if eq(w, "normal") { f.normal = try parseSFNode() as? NormalNode }
            else if eq(w, "coordIndex") { f.coordIndex = try readIntArray() }
            else if eq(w, "normalIndex") { f.normalIndex = try readIntArray() }
            else if eq(w, "ccw") { f.ccw = try readBool() }
            else if eq(w, "normalPerVertex") { f.normalPerVertex = try readBool() }
            else { return false }
            return true
        }
        return f
    }

    func parseCoordinate() throws -> Node {
        let c = CoordinateNode()
        try parseBody { w in
            guard eq(w, "point") else { return false }
            c.points = try readFloatArray(multipleOf: 3, field: "Coordinate point")
            return true
        }
        return c
    }

    func parseNormal() throws -> Node {
        let nn = NormalNode()
        try parseBody { w in
            guard eq(w, "vector") else { return false }
            nn.vectors = try readFloatArray(multipleOf: 3, field: "Normal vector")
            return true
        }
        return nn
    }
}

// MARK: - Triangulation

private extension IFSNode {
    func triangulated(_ reader: Reader) throws -> LocalMesh {
        if let localMesh { return localMesh }
        let mesh = try triangulate(reader)
        localMesh = mesh
        return mesh
    }

    private func triangulate(_ reader: Reader) throws -> LocalMesh {
        var mesh = LocalMesh()
        guard let points = coord?.points, !points.isEmpty else { return mesh }
        let pointCount = points.count / 3
        let vectors = normal?.vectors ?? []
        let normalCount = vectors.count / 3
        let hasNormals = normalCount > 0
        let ci = coordIndex
        let ni = normalIndex

        func outOfRange(_ kind: String, _ index: Int, _ count: Int) -> VRMLError {
            .indexOutOfRange(kind: kind, index: index, count: count, line: reader.line(at: offset))
        }
        func point(_ k: Int) -> SIMD3<Float> {
            SIMD3(points[3 * k], points[3 * k + 1], points[3 * k + 2])
        }
        func vector(_ k: Int) throws -> SIMD3<Float> {
            guard k >= 0 && k < normalCount else { throw outOfRange("normalIndex", k, normalCount) }
            return SIMD3(vectors[3 * k], vectors[3 * k + 1], vectors[3 * k + 2])
        }

        mesh.positions.reserveCapacity(ci.count * 3)
        mesh.normals.reserveCapacity(ci.count * 3)
        mesh.indices.reserveCapacity(ci.count * 3)

        var faceStart = 0
        var face = 0
        while faceStart < ci.count {
            var end = faceStart
            while end < ci.count && ci[end] >= 0 { end += 1 }
            defer { faceStart = end + 1; face += 1 }

            for k in faceStart..<end where Int(ci[k]) >= pointCount {
                throw outOfRange("coordIndex", Int(ci[k]), pointCount)
            }
            let count = end - faceStart
            if count < 3 { continue }

            // Newell's method: robust polygon normal, zero for degenerate faces.
            var newell = SIMD3<Float>(0, 0, 0)
            for k in 0..<count {
                let a = point(Int(ci[faceStart + k]))
                let b = point(Int(ci[faceStart + (k + 1) % count]))
                newell += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
            }
            let newellLength = simd_length(newell)

            let base = mesh.positions.count / 3
            guard base + count < Int(UInt32.max) else {
                throw VRMLError.tooComplex("IndexedFaceSet has more than 2^32 vertices")
            }

            if hasNormals && normalPerVertex {
                for k in faceStart..<end {
                    let nk: Int
                    if ni.isEmpty {
                        nk = Int(ci[k])
                    } else {
                        guard k < ni.count else { throw outOfRange("normalIndex position", k, ni.count) }
                        nk = Int(ni[k])
                    }
                    let v = try vector(nk)
                    let pt = point(Int(ci[k]))
                    mesh.positions.append(pt.x); mesh.positions.append(pt.y); mesh.positions.append(pt.z)
                    mesh.normals.append(v.x); mesh.normals.append(v.y); mesh.normals.append(v.z)
                }
            } else {
                let faceNormal: SIMD3<Float>
                if hasNormals {
                    let nk: Int
                    if ni.isEmpty {
                        nk = face
                    } else {
                        guard face < ni.count else { throw outOfRange("normalIndex position", face, ni.count) }
                        nk = Int(ni[face])
                    }
                    faceNormal = try vector(nk)
                } else {
                    guard newellLength > 0, newellLength.isFinite else { continue }
                    faceNormal = (ccw ? newell : -newell) / newellLength
                }
                for k in faceStart..<end {
                    let pt = point(Int(ci[k]))
                    mesh.positions.append(pt.x); mesh.positions.append(pt.y); mesh.positions.append(pt.z)
                    mesh.normals.append(faceNormal.x); mesh.normals.append(faceNormal.y); mesh.normals.append(faceNormal.z)
                }
            }

            // Fan triangulation, dropping zero-area triangles.
            let a = point(Int(ci[faceStart]))
            for j in 1..<(count - 1) {
                let b = point(Int(ci[faceStart + j]))
                let c = point(Int(ci[faceStart + j + 1]))
                let area = simd_length_squared(simd_cross(b - a, c - a))
                guard area > 0, area.isFinite else { continue }
                let i0 = UInt32(base), i1 = UInt32(base + j), i2 = UInt32(base + j + 1)
                mesh.indices.append(i0)
                mesh.indices.append(ccw ? i1 : i2)
                mesh.indices.append(ccw ? i2 : i1)
            }
        }
        return mesh
    }
}

// MARK: - Flattening

private struct Flattener {
    let reader: Reader
    var scene = VRMLScene()
    private var totalVertices = 0
    private static let maxVertices = 50_000_000
    private static let maxParts = 100_000
    private static let maxDepth = 200

    init(reader: Reader) {
        self.reader = reader
    }

    mutating func walk(_ node: Node, _ m: simd_float4x4, depth: Int) throws {
        guard depth <= Flattener.maxDepth else {
            throw VRMLError.tooComplex("scene graph deeper than \(Flattener.maxDepth) levels")
        }
        switch node {
        case let t as TransformNode:
            let world = m * t.matrix
            for child in t.children { try walk(child, world, depth: depth + 1) }
        case let g as GroupNode:
            for child in g.children { try walk(child, m, depth: depth + 1) }
        case let s as ShapeNode:
            try emit(s, m)
        default:
            break
        }
    }

    private mutating func emit(_ shape: ShapeNode, _ m: simd_float4x4) throws {
        guard let ifs = shape.geometry else { return }
        let local = try ifs.triangulated(reader)
        guard !local.indices.isEmpty else { return }

        let vertexCount = local.positions.count / 3
        totalVertices += vertexCount
        guard totalVertices <= Flattener.maxVertices else {
            throw VRMLError.tooComplex("more than \(Flattener.maxVertices) vertices after expanding USE")
        }
        guard scene.parts.count < Flattener.maxParts else {
            throw VRMLError.tooComplex("more than \(Flattener.maxParts) shapes after expanding USE")
        }

        let linear = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        let det = linear.determinant
        let normalMatrix = det != 0 && det.isFinite ? linear.inverse.transpose : linear
        let translation = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        var positions = [Float](repeating: 0, count: local.positions.count)
        var normals = [Float](repeating: 0, count: local.normals.count)
        var lo = scene.boundsMin
        var hi = scene.boundsMax
        local.positions.withUnsafeBufferPointer { src in
            positions.withUnsafeMutableBufferPointer { dst in
                for v in 0..<vertexCount {
                    let o = 3 * v
                    let w = linear * SIMD3(src[o], src[o + 1], src[o + 2]) + translation
                    dst[o] = w.x; dst[o + 1] = w.y; dst[o + 2] = w.z
                    lo = simd_min(lo, w)
                    hi = simd_max(hi, w)
                }
            }
        }
        local.normals.withUnsafeBufferPointer { src in
            normals.withUnsafeMutableBufferPointer { dst in
                for v in 0..<vertexCount {
                    let o = 3 * v
                    var w = normalMatrix * SIMD3(src[o], src[o + 1], src[o + 2])
                    let length = simd_length(w)
                    if length > 0 && length.isFinite { w /= length }
                    dst[o] = w.x; dst[o + 1] = w.y; dst[o + 2] = w.z
                }
            }
        }
        scene.boundsMin = lo
        scene.boundsMax = hi

        var indices = local.indices
        if det < 0 {
            // Mirroring flips the winding; keep front faces facing the normals.
            for t in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(t + 1, t + 2) }
        }

        scene.parts.append(VRMLPart(
            positions: positions,
            normals: normals,
            indices: indices,
            material: shape.appearance?.material?.material
        ))
    }
}
