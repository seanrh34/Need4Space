import Darwin
import Foundation

/// Attribute bitmap values, taken from the SDK's `sys/attr.h` via Darwin (never hand-coded,
/// so the parser cannot drift from the kernel ABI). See getattrlist(2) and
/// getattrlistbulk(2).
enum Attr {
    /// attribute_set_t is 5 x uint32 (commonattr, volattr, dirattr, fileattr, forkattr).
    static let attributeSetByteWidth = 20

    // --- common attributes (sys/attr.h, ATTR_CMN_*) ---
    static let cmnName: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_NAME)
    static let cmnDevID: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_DEVID)
    static let cmnObjType: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
    static let cmnModTime: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_MODTIME)
    static let cmnAccTime: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_ACCTIME)
    static let cmnFileID: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_FILEID)
    static let cmnError: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_ERROR)
    static let cmnReturnedAttrs: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)

    // --- file attributes (sys/attr.h, ATTR_FILE_*) ---
    static let fileLinkCount: UInt32 = UInt32(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
    static let fileAllocSize: UInt32 = UInt32(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
    static let fileDataLength: UInt32 = UInt32(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

    // --- fsobj_type_t values (sys/vnode.h vtype), returned as ATTR_CMN_OBJTYPE ---
    enum ObjType {
        static let vreg: UInt32 = 1
        static let vdir: UInt32 = 2
        static let vlnk: UInt32 = 5
    }
}

/// Attribute bitmap passed to getattrlistbulk. Layout mirrors `struct attrlist` in sys/attr.h:
/// uint16 bitmapcount, uint16 reserved, then attribute_set_t (5 x uint32).
struct AttrListRequest {
    var bitmapcount: UInt16 = UInt16(truncatingIfNeeded: ATTR_BIT_MAP_COUNT)
    var reserved: UInt16 = 0
    var commonattr: UInt32 = 0
    var volattr: UInt32 = 0
    var dirattr: UInt32 = 0
    var fileattr: UInt32 = 0
    var forkattr: UInt32 = 0
}

/// One directory entry as parsed from a getattrlistbulk buffer. Fields are optional: a field
/// is nil when its attribute bit was not set in the record's returned attribute set.
struct RawEntry {
    /// fsobj_type_t if ATTR_CMN_OBJTYPE was returned (Attr.ObjType values).
    var objType: UInt32?
    /// Device id if ATTR_CMN_DEVID was returned.
    var devid: Int32?
    /// File id if ATTR_CMN_FILEID was returned.
    var fileID: UInt64?
    /// Seconds since epoch if ATTR_CMN_MODTIME was returned.
    var modTime: Int64?
    /// Seconds since epoch if ATTR_CMN_ACCTIME was returned.
    var accessTime: Int64?
    /// Hard link count if ATTR_FILE_LINKCOUNT was returned.
    var linkCount: UInt32?
    /// Allocated bytes if ATTR_FILE_ALLOCSIZE was returned.
    var allocSize: UInt64?
    /// Logical bytes if ATTR_FILE_DATALENGTH was returned.
    var logicalSize: UInt64?
    /// Entry name without the terminating NUL if ATTR_CMN_NAME was returned.
    var name: [UInt8]?
    /// Per-entry error if ATTR_CMN_ERROR was returned. getattrlistbulk(2): an individual
    /// entry may fail; the error value is packed immediately after the returned set.
    var error: Int32?
}

/// getattrlistbulk(2) wrapper: batched directory reads with no per-file stat.
///
/// This file contains the syscall binding and the pure, unit-testable record parser. The
/// parser is a free function over an already-read buffer so tests can hand-build buffers
/// (mixed returned attrs, per-entry error, truncated record) without a file system.
enum DirectoryReader {
    /// Per-worker buffer size (256 KB; SPEC §4 requires at least 64 KB per call).
    static let defaultBufferBytes = 256 * 1024

    /// FSOPT_PACK_INVAL_ATTRS (sys/attr.h): requested-but-invalid attributes are packed as
    /// zeroed placeholders instead of being omitted, so every record has a uniform layout.
    static let fsOptPackInvalAttrs: UInt64 = UInt64(FSOPT_PACK_INVAL_ATTRS)

    /// The attribute set requested for every listing. The record layout walked by the parser
    /// is derived from this fixed request (packed under FSOPT_PACK_INVAL_ATTRS).
    static func request() -> AttrListRequest {
        var req = AttrListRequest()
        req.commonattr = Attr.cmnReturnedAttrs | Attr.cmnError | Attr.cmnName | Attr.cmnDevID
            | Attr.cmnObjType | Attr.cmnModTime | Attr.cmnAccTime | Attr.cmnFileID
        req.fileattr = Attr.fileLinkCount | Attr.fileAllocSize | Attr.fileDataLength
        return req
    }

    /// libsystem_kernel symbol, declared here because the Swift Darwin overlay does not
    /// reliably import <sys/attr.h> where getattrlistbulk is declared.
    /// Signature matches getattrlistbulk(2): returns the number of entries placed in the
    /// buffer, 0 at end of directory, or -1 with errno set on error.
    @_silgen_name("getattrlistbulk")
    private static func sys_getattrlistbulk(
        _ fd: Int32, _ attrList: UnsafeMutableRawPointer, _ attributeBuffer: UnsafeMutableRawPointer,
        _ bufferSize: Int, _ options: UInt64
    ) -> Int32

    /// Fills `buffer` with the next batch of directory entries of `fd`.
    static func readEntries(
        fd: Int32, buffer: UnsafeMutableRawPointer, bufferSize: Int
    ) -> Int {
        var req = request()
        return withUnsafeMutableBytes(of: &req) { reqBytes -> Int in
            let raw = sys_getattrlistbulk(
                fd, reqBytes.baseAddress!, buffer, bufferSize, fsOptPackInvalAttrs)
            return Int(raw)
        }
    }

    // MARK: - Pure buffer parser

    /// Requested common attributes (excluding the two special cases RETURNED_ATTRS and ERROR,
    /// which are handled in the record header) with their packed byte sizes. The parser walks
    /// them in ASCENDING BIT ORDER, as getattrlistbulk(2) packs them; the table is kept
    /// sorted at initialization so it always follows the SDK constants.
    private static let commonFieldLayout: [(bit: UInt32, byteWidth: Int)] = [
        (Attr.cmnName, 8), // attrreference_t: int32 offset, uint32 length
        (Attr.cmnDevID, 4), // dev_t is int32 on macOS
        (Attr.cmnObjType, 4),
        (Attr.cmnModTime, 16), // struct timespec: 2 x 8 bytes
        (Attr.cmnAccTime, 16),
        (Attr.cmnFileID, 8),
    ].sorted { $0.bit < $1.bit }

    /// Requested file attributes in ascending bit order with their packed sizes.
    private static let fileFieldLayout: [(bit: UInt32, byteWidth: Int)] = [
        (Attr.fileLinkCount, 4),
        (Attr.fileAllocSize, 8),
        (Attr.fileDataLength, 8),
    ].sorted { $0.bit < $1.bit }

    /// Parses a getattrlistbulk result buffer.
    ///
    /// Record layout (getattrlistbulk(2) + sys/attr.h):
    ///  - uint32 length: size of the whole record including variable data; the next record
    ///    starts at record + length.
    ///  - attribute_set_t returned (5 x uint32), present because ATTR_CMN_RETURNED_ATTRS is
    ///    requested.
    ///  - ATTR_CMN_ERROR (uint32) immediately after the returned set, iff its bit is set in
    ///    returned.commonattr (the special case shown in the man page example).
    ///  - the remaining requested common attributes in ascending bit order (NAME, DEVID,
    ///    OBJTYPE, MODTIME, ACCTIME, FILEID), then requested file attributes in ascending
    ///    bit order (LINKCOUNT, ALLOCSIZE, DATALENGTH). Under FSOPT_PACK_INVAL_ATTRS each
    ///    requested attribute occupies its slot even when invalid (zero-filled placeholder);
    ///    a value is only used when its bit is set in the returned set.
    ///  - an attrreference_t field holds int32 attr_dataoffset relative to the attrreference_t
    ///    field's own address and uint32 attr_length including the terminating NUL.
    ///
    /// All fixed-width reads use `loadUnaligned` because attribute slots are packed without
    /// padding. Every record length, field slot and attrreference offset is bounds-checked
    /// against the buffer and the record. A truncated or malformed record stops the parse
    /// (entries before it are returned). `count` bounds how many records are examined,
    /// because the buffer tail may hold stale bytes from a previous batch.
    static func parseAttrBuffer(_ buf: UnsafeRawBufferPointer, count: Int) -> [RawEntry] {
        var entries: [RawEntry] = []
        entries.reserveCapacity(max(count, 0))
        let requestedCommon = request().commonattr
        let requestedFile = request().fileattr
        var cursor = 0

        for _ in 0..<max(count, 0) {
            guard cursor + 4 <= buf.count else { break }
            let recordStart = cursor
            let length = Int(buf.loadUnaligned(fromByteOffset: recordStart, as: UInt32.self))
            // A record must at least cover length + returned set; if it claims more space
            // than the buffer holds, it is truncated: stop, return what we have.
            guard length >= 4 + Attr.attributeSetByteWidth,
                recordStart + length <= buf.count
            else { break }
            let recordEnd = recordStart + length

            let setBase = recordStart + 4
            let returnedCommon = buf.loadUnaligned(fromByteOffset: setBase, as: UInt32.self)
            let returnedVol = buf.loadUnaligned(fromByteOffset: setBase + 4, as: UInt32.self)
            let returnedDir = buf.loadUnaligned(fromByteOffset: setBase + 8, as: UInt32.self)
            let returnedFile = buf.loadUnaligned(fromByteOffset: setBase + 12, as: UInt32.self)
            // forkattr (setBase + 16) is unused: no fork attributes are requested.
            _ = returnedVol
            _ = returnedDir

            // Defensive: bits outside the requested set mean the record layout cannot be
            // walked (slot sizes unknown); treat the record as malformed and stop.
            guard returnedCommon & ~requestedCommon == 0,
                returnedVol == 0,
                returnedDir == 0,
                returnedFile & ~requestedFile == 0
            else { break }

            var entry = RawEntry()
            var offset = setBase + Attr.attributeSetByteWidth

            // The error value follows the returned set immediately (man page example). Under
            // FSOPT_PACK_INVAL_ATTRS the kernel packs it for EVERY entry with its returned bit
            // set and value 0 on success, so only a non-zero value marks a failed entry.
            var entryError: Int32 = 0
            if returnedCommon & Attr.cmnError != 0 {
                guard offset + 4 <= recordEnd else { break }
                entryError = Int32(bitPattern: buf.loadUnaligned(
                    fromByteOffset: offset, as: UInt32.self))
                offset += 4
            }
            if entryError != 0 {
                // Other fields of a failed entry are not packed reliably: read name + error.
                entry.error = entryError
                if returnedCommon & Attr.cmnName != 0 {
                    guard offset + 8 <= recordEnd else { break }
                    if let name = readName(at: offset, recordStart: recordStart, recordEnd: recordEnd, buf: buf) {
                        entry.name = name
                    }
                    offset += 8
                }
                entries.append(entry)
                cursor = recordEnd
                continue
            }

            var nameSlot: Int?
            var parsed = true

            for (bit, width) in commonFieldLayout {
                guard offset + width <= recordEnd else { parsed = false; break }
                let slot = offset
                offset += width
                guard returnedCommon & bit != 0 else { continue }
                switch bit {
                case Attr.cmnName:
                    nameSlot = slot
                case Attr.cmnDevID:
                    entry.devid = Int32(bitPattern: buf.loadUnaligned(
                        fromByteOffset: slot, as: UInt32.self))
                case Attr.cmnObjType:
                    entry.objType = buf.loadUnaligned(fromByteOffset: slot, as: UInt32.self)
                case Attr.cmnModTime:
                    entry.modTime = timespecSeconds(buf, slot)
                case Attr.cmnAccTime:
                    entry.accessTime = timespecSeconds(buf, slot)
                case Attr.cmnFileID:
                    entry.fileID = buf.loadUnaligned(fromByteOffset: slot, as: UInt64.self)
                default:
                    break
                }
            }
            guard parsed else { break }

            if let slot = nameSlot,
                let name = readName(at: slot, recordStart: recordStart, recordEnd: recordEnd, buf: buf)
            {
                entry.name = name
            }

            for (bit, width) in fileFieldLayout {
                guard offset + width <= recordEnd else { parsed = false; break }
                let slot = offset
                offset += width
                guard returnedFile & bit != 0 else { continue }
                switch bit {
                case Attr.fileLinkCount:
                    entry.linkCount = buf.loadUnaligned(fromByteOffset: slot, as: UInt32.self)
                case Attr.fileAllocSize:
                    entry.allocSize = buf.loadUnaligned(fromByteOffset: slot, as: UInt64.self)
                case Attr.fileDataLength:
                    entry.logicalSize = buf.loadUnaligned(fromByteOffset: slot, as: UInt64.self)
                default:
                    break
                }
            }
            guard parsed else { break }

            entries.append(entry)
            cursor = recordEnd
        }
        return entries
    }

    /// Reads the seconds field of a packed struct timespec (16 bytes: int64 tv_sec, int64
    /// tv_nsec on 64-bit Darwin). Only tv_sec is needed by the scanner.
    private static func timespecSeconds(_ buf: UnsafeRawBufferPointer, _ offset: Int) -> Int64 {
        buf.loadUnaligned(fromByteOffset: offset, as: Int64.self)
    }

    /// Reads a name through its attrreference_t at `slotOffset`.
    /// getattrlist(2): attr_dataoffset is relative to the start of the attribute reference
    /// field itself; attr_length includes the terminating NUL.
    private static func readName(
        at slotOffset: Int, recordStart: Int, recordEnd: Int, buf: UnsafeRawBufferPointer
    ) -> [UInt8]? {
        guard slotOffset >= 0, slotOffset + 8 <= recordEnd else { return nil }
        let dataOffset = Int(Int32(bitPattern: buf.loadUnaligned(
            fromByteOffset: slotOffset, as: UInt32.self)))
        let dataLength = Int(buf.loadUnaligned(
            fromByteOffset: slotOffset + 4, as: UInt32.self))
        guard dataOffset >= 0, dataLength >= 1 else { return nil }
        let dataStart = slotOffset + dataOffset
        // The name data must lie inside the record (and therefore inside the buffer).
        guard dataStart >= recordStart, dataStart + dataLength <= recordEnd else { return nil }
        let nameLength = dataLength - 1 // exclude NUL
        return Array(buf[dataStart..<dataStart + nameLength])
    }
}
