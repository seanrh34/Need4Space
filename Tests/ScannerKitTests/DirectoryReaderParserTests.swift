import Testing
@testable import ScannerKit

// Pure parser tests: hand-built getattrlistbulk buffers (little-endian, matching the
// packed record layout documented in DirectoryReader.parseAttrBuffer).

private func le32(_ v: UInt32) -> [UInt8] {
    withUnsafeBytes(of: v) { Array($0) }
}

private func le64(_ v: UInt64) -> [UInt8] {
    withUnsafeBytes(of: v) { Array($0) }
}

/// Builds one record exactly the way the kernel packs it under FSOPT_PACK_INVAL_ATTRS:
/// [len u32][attribute_set_t 20][error u32?][common attrs ascending][file attrs ascending]
/// [variable name data]. Fields whose bit is cleared are packed as zero placeholders.
private func record(
    name: String? = "entry.txt",
    objType: UInt32? = Attr.ObjType.vreg,
    modTime: Int64? = nil,
    accTime: Int64? = nil,
    fileID: UInt64? = nil,
    devid: Int32? = nil,
    linkCount: UInt32? = nil,
    alloc: UInt64? = nil,
    logical: UInt64? = nil,
    error: Int32? = nil,
    nameGap: Int = 0,
    trailingPad: [UInt8] = []
) -> [UInt8] {
    var b: [UInt8] = []
    b.reserveCapacity(128)
    b.append(contentsOf: [0, 0, 0, 0]) // length placeholder

    var common: UInt32 = Attr.cmnReturnedAttrs
    var file: UInt32 = 0
    if error != nil { common |= Attr.cmnError }
    if name != nil { common |= Attr.cmnName }
    if objType != nil { common |= Attr.cmnObjType }
    if modTime != nil { common |= Attr.cmnModTime }
    if accTime != nil { common |= Attr.cmnAccTime }
    if fileID != nil { common |= Attr.cmnFileID }
    if devid != nil { common |= Attr.cmnDevID }
    if linkCount != nil { file |= Attr.fileLinkCount }
    if alloc != nil { file |= Attr.fileAllocSize }
    if logical != nil { file |= Attr.fileDataLength }

    b.append(contentsOf: le32(common))
    b.append(contentsOf: le32(0)) // volattr
    b.append(contentsOf: le32(0)) // dirattr
    b.append(contentsOf: le32(file))
    b.append(contentsOf: le32(0)) // forkattr

    if let error {
        b.append(contentsOf: le32(UInt32(bitPattern: error)))
    }

    // attrreference_t for the name; data offset is relative to the attrref field itself
    // and lands after the fixed fields plus nameGap filler bytes.
    let nameData = name.map { Array($0.utf8) } ?? []
    let attrRefPos = b.count
    if name != nil {
        // Compute after we know the gap; patch below. Reserve the slot now.
        b.append(contentsOf: le32(0)) // offset placeholder
        b.append(contentsOf: le32(UInt32(nameData.count + 1))) // length incl. NUL
    }
    if objType != nil { b.append(contentsOf: le32(objType!)) }
    if modTime != nil {
        b.append(contentsOf: le64(UInt64(bitPattern: modTime!)))
        b.append(contentsOf: le64(999_999_999)) // tv_nsec, ignored
    }
    if accTime != nil {
        b.append(contentsOf: le64(UInt64(bitPattern: accTime!)))
        b.append(contentsOf: le64(1))
    }
    if fileID != nil { b.append(contentsOf: le64(fileID!)) }
    if devid != nil { b.append(contentsOf: le32(UInt32(bitPattern: devid!))) }
    if linkCount != nil { b.append(contentsOf: le32(linkCount!)) }
    if alloc != nil { b.append(contentsOf: le64(alloc!)) }
    if logical != nil { b.append(contentsOf: le64(logical!)) }

    if name != nil {
        b.append(contentsOf: [UInt8](repeating: 0xAB, count: nameGap))
        let dataOffset = b.count - attrRefPos
        let offsetBytes = le32(UInt32(dataOffset))
        b[attrRefPos] = offsetBytes[0]
        b[attrRefPos + 1] = offsetBytes[1]
        b[attrRefPos + 2] = offsetBytes[2]
        b[attrRefPos + 3] = offsetBytes[3]
        b.append(contentsOf: nameData)
        b.append(0) // NUL included in attr_length
    }
    b.append(contentsOf: trailingPad)

    let length = le32(UInt32(b.count))
    b[0] = length[0]
    b[1] = length[1]
    b[2] = length[2]
    b[3] = length[3]
    return b
}

private func parse(_ records: [UInt8], count: Int? = nil) -> [RawEntry] {
    let n = count ?? records.count // over-count is fine: records bound the walk
    return DirectoryReader.parseAttrBuffer(UnsafeRawBufferPointer(records), count: n)
}

@Suite("DirectoryReader.parseAttrBuffer")
struct ParserTests {
    @Test func fullRecordParsesEveryField() {
        let buf = record(
            name: "hello.txt", objType: Attr.ObjType.vdir, modTime: 1_700_000_000,
            accTime: 1_700_000_001, fileID: 0x1234_5678_9ABC, devid: 0x1000_04,
            linkCount: 3, alloc: 4096, logical: 1234)
        let entries = parse(buf, count: 1)
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.name.map { String(decoding: $0, as: UTF8.self) } == "hello.txt")
        #expect(e.objType == Attr.ObjType.vdir)
        #expect(e.modTime == 1_700_000_000)
        #expect(e.accessTime == 1_700_000_001)
        #expect(e.fileID == 0x1234_5678_9ABC)
        #expect(e.devid == 0x1000_04)
        #expect(e.linkCount == 3)
        #expect(e.allocSize == 4096)
        #expect(e.logicalSize == 1234)
        #expect(e.error == nil)
    }

    @Test func mixedReturnedAttrsLeaveMissingFieldsNil() {
        // Only NAME, OBJTYPE and ALLOCSIZE returned; other requested slots are
        // zero-filled placeholders (FSOPT_PACK_INVAL_ATTRS) and must read as nil.
        let buf = record(
            name: "mixed.bin", objType: Attr.ObjType.vreg, modTime: nil, accTime: nil,
            fileID: nil, devid: nil, linkCount: nil, alloc: 8192, logical: nil)
        let entries = parse(buf, count: 1)
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.name.map { String(decoding: $0, as: UTF8.self) } == "mixed.bin")
        #expect(e.objType == Attr.ObjType.vreg)
        #expect(e.allocSize == 8192)
        #expect(e.modTime == nil)
        #expect(e.accessTime == nil)
        #expect(e.fileID == nil)
        #expect(e.devid == nil)
        #expect(e.linkCount == nil)
        #expect(e.logicalSize == nil)
    }

    @Test func perEntryErrorCarriesNameAndSkipsNothing() {
        let errRecord = record(name: "denied", error: EPERM, objType: nil)
        let okRecord = record(name: "ok.txt", alloc: 512)
        let entries = parse(errRecord + okRecord, count: 2)
        #expect(entries.count == 2)
        #expect(entries[0].error == EPERM)
        #expect(entries[0].name.map { String(decoding: $0, as: UTF8.self) } == "denied")
        #expect(entries[1].error == nil)
        #expect(entries[1].name.map { String(decoding: $0, as: UTF8.self) } == "ok.txt")
        #expect(entries[1].allocSize == 512)
    }

    @Test func errorRecordWithoutName() {
        let entries = parse(record(name: nil, error: EACCES), count: 1)
        #expect(entries.count == 1)
        #expect(entries[0].error == EACCES)
        #expect(entries[0].name == nil)
    }

    @Test func truncatedRecordIsDroppedButEarlierEntriesRemain() {
        let good = record(name: "a.txt", alloc: 100)
        // Second record claims more bytes than the buffer holds.
        var truncated = record(name: "b.txt", alloc: 200)
        truncated[0] = 0xFF
        truncated[1] = 0xFF
        truncated[2] = 0x00
        truncated[3] = 0x00 // length = 65535 > remaining
        let entries = parse(good + truncated, count: 2)
        #expect(entries.count == 1)
        #expect(entries[0].name.map { String(decoding: $0, as: UTF8.self) } == "a.txt")
    }

    @Test func countBoundsStopBeforeStaleTail() {
        let first = record(name: "one", alloc: 1)
        let second = record(name: "two", alloc: 2)
        var buffer = first + second
        buffer.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF]) // stale bytes
        #expect(parse(buffer, count: 1).count == 1)
        #expect(parse(buffer, count: 2).count == 2)
    }

    @Test func nameDataOffsetIsRelativeToTheAttrReference() {
        // 37 filler bytes push the name data past the attrref; the offset stored in the
        // attrreference_t is relative to the field's own address.
        let buf = record(name: "offset-test", nameGap: 37, alloc: 10)
        let entries = parse(buf, count: 1)
        #expect(entries.count == 1)
        #expect(entries[0].name.map { String(decoding: $0, as: UTF8.self) } == "offset-test")
    }

    @Test func oddRecordLengthsStillParseViaLoadUnaligned() {
        // An odd trailing pad makes the NEXT record start at an odd address, so its
        // 8-byte fields are misaligned; loadUnaligned must cope.
        let first = record(name: "odd", trailingPad: [0x00])
        let second = record(name: "even-after-odd", alloc: 0x1234, fileID: 99)
        let entries = parse(first + second, count: 2)
        #expect(entries.count == 2)
        #expect(entries[1].allocSize == 0x1234)
        #expect(entries[1].fileID == 99)
        #expect(entries[1].name.map { String(decoding: $0, as: UTF8.self) } == "even-after-odd")
    }

    @Test func emptyRecordListParsesToEmpty() {
        #expect(DirectoryReader.parseAttrBuffer(UnsafeRawBufferPointer([]), count: 0).isEmpty)
        #expect(DirectoryReader.parseAttrBuffer(UnsafeRawBufferPointer([1, 2, 3]), count: 4).isEmpty)
    }
}
