import Testing
import Darwin
import Foundation
@testable import ScannerKit

/// Diagnostic: dumps a real kernel getattrlistbulk buffer so the packed layout can be checked
/// against the parser on an actual Mac (CI). Always passes; read the log.
@Test func dumpRealGetattrlistbulkBuffer() throws {
    let dir = NSTemporaryDirectory() + "n4s-diag-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/hello.txt", contents: Data(count: 5000))
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    let fd = open(dir, O_RDONLY | O_DIRECTORY)
    try #require(fd >= 0)
    defer { close(fd) }
    let size = 64 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buf.deallocate() }
    let n = DirectoryReader.readEntries(fd: fd, buffer: buf, bufferSize: size)
    print("DIAG n=\(n) errno=\(errno)")
    var cursor = 0
    for i in 0..<max(0, n) {
        let len = Int(buf.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
        let bytes = (0..<min(len, 160)).map { String(format: "%02x", buf.load(fromByteOffset: cursor + $0, as: UInt8.self)) }
        print("DIAG rec\(i) len=\(len) common=\(String(buf.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self), radix: 16)) file=\(String(buf.loadUnaligned(fromByteOffset: cursor + 16, as: UInt32.self), radix: 16))")
        print("DIAG rec\(i) bytes=\(bytes.joined(separator: " "))")
        cursor += len
    }
    let parsed = DirectoryReader.parseAttrBuffer(UnsafeRawBufferPointer(start: buf, count: size), count: max(0, n))
    print("DIAG parsed=\(parsed.count) names=\(parsed.map { $0.name.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }) alloc=\(parsed.map { $0.allocSize ?? 0 }) err=\(parsed.map { $0.error ?? 0 })")
}
