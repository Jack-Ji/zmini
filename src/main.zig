const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const c = @cImport({
    @cInclude("miniz.h");
});

/// zip file manipulation
pub const Archive = struct {
    pub const Mode = enum {
        read,
        write,
    };

    pub const Error = error{
        UndefinedError,
        TooManyFiles,
        FileTooLarge,
        UnsupportedMethod,
        UnsupportedEncryption,
        UnsupportedFeature,
        FailedFindingCentralDir,
        NotAnArchive,
        InvalidHeaderOrCorrupted,
        UnsupportedMultidisk,
        DecompressionFailed,
        CompressionFailed,
        UnexpectedDecompressedSize,
        CrcCheckFailed,
        UnsupportedCdirSize,
        AllocFailed,
        FileOpenFailed,
        FileCreateFailed,
        FileWriteFailed,
        FileReadFailed,
        FileCloseFailed,
        FileSeekFailed,
        FileStatFailed,
        InvalidParameter,
        InvalidFilename,
        BufTooSmall,
        InternalError,
        FileNotFound,
        ArchiveTooLarge,
        ValidationFailed,
        WriteCallbackFailed,
    };

    pub const FileStat = struct {
        size: usize,
        is_dir: bool,
        is_encrypted: bool,
        is_supported: bool,
        filename: [512]u8 = undefined,
        filename_size: usize = undefined,
    };

    allocator: std.mem.Allocator,
    mode: Mode,
    archive: c.mz_zip_archive,
    need_write: bool = false,

    /// Create an archive
    pub fn init(allocator: std.mem.Allocator, file_path: [:0]const u8, mode: Mode) !*Archive {
        var ar = try allocator.create(Archive);
        errdefer allocator.destroy(ar);
        ar.* = .{
            .allocator = allocator,
            .mode = mode,
            .archive = undefined,
        };
        ar.initArchive();
        const result = switch (mode) {
            .read => c.mz_zip_reader_init_file(&ar.archive, file_path, 0),
            .write => c.mz_zip_writer_init_file(&ar.archive, file_path, 0),
        };
        if (result != 1) return ar.getLastError();
        return ar;
    }

    /// Close archive, flush data to disk if necessary
    pub fn deinit(ar: *Archive) void {
        if (ar.need_write) {
            assert(ar.mode == .write);
            const result = c.mz_zip_writer_finalize_archive(&ar.archive);
            assert(result == 1);
        }
        const result = c.mz_zip_end(&ar.archive);
        assert(result == 1);
        ar.allocator.destroy(ar);
    }

    /// Get number of files in archive
    pub fn getNumberOfFiles(ar: *Archive) u32 {
        assert(ar.mode == .read);
        return @intCast(u32, c.mz_zip_reader_get_num_files(&ar.archive));
    }

    /// Add contents of buffer to archive.
    /// To add a directory entry, call this method with an
    /// archive name ending in a forwardslash with an empty buffer.
    /// Compression level is between 0-10, 0 means no compression, use 6 by default
    pub fn addFileFromMemory(
        ar: *Archive,
        archive_name: [:0]const u8,
        data: []const u8,
        compress_level: ?u8,
    ) !void {
        assert(ar.mode == .write);
        if (std.mem.endsWith(u8, archive_name, "/")) assert(data.len == 0);
        const result = c.mz_zip_writer_add_mem(
            &ar.archive,
            archive_name,
            data.ptr,
            data.len,
            @intCast(c.mz_uint, compress_level orelse 6),
        );
        if (result != 1) return ar.getLastError();
        ar.need_write = true;
    }

    /// Add contexts of file on disk
    pub fn addFileFromPath(
        ar: *Archive,
        archive_name: [:0]const u8,
        file_path: [:0]const u8,
        compress_level: ?u8,
    ) !void {
        assert(ar.mode == .write);
        assert(!std.mem.endsWith(u8, archive_name, "/"));
        const result = c.mz_zip_writer_add_file(
            &ar.archive,
            archive_name,
            file_path,
            null,
            0,
            @intCast(c.mz_uint, compress_level orelse 6),
        );
        if (result != 1) return ar.getLastError();
        ar.need_write = true;
    }

    /// Add contexts of dir recursively on disk
    pub fn addDir(ar: *Archive, allocator: std.mem.Allocator, dir_path: []const u8, compress_level: ?u8) !void {
        assert(ar.mode == .write);
        var dir = try std.fs.cwd().openIterableDir(dir_path, .{
            .access_sub_paths = true,
            .no_follow = true,
        });
        defer dir.close();
        var walk = try dir.walk(allocator);
        defer walk.deinit();
        var buf1: [512]u8 = undefined;
        var buf2: [512]u8 = undefined;
        while (try walk.next()) |we| {
            if (we.kind != .File) continue;
            const archive_name = try std.fmt.bufPrintZ(
                &buf1,
                "{s}",
                .{we.path},
            );
            std.mem.replaceScalar(u8, archive_name, '\\', '/');
            const path = try std.fmt.bufPrintZ(
                &buf2,
                "{s}/{s}",
                .{ dir_path, we.path },
            );
            try ar.addFileFromPath(
                archive_name,
                path,
                compress_level,
            );
        }
    }

    /// Read file's content to self-allocated buffer
    pub fn readFileAlloc(
        ar: *Archive,
        allocator: std.mem.Allocator,
        archive_name: [:0]const u8,
        case_sensitivy: bool,
        ignore_path: bool,
    ) ![]u8 {
        assert(ar.mode == .read);
        var file_index = try ar.getFileIndex(archive_name, case_sensitivy, ignore_path);
        var file_stat = try ar.getFileStat(file_index);
        var buf = try allocator.alloc(u8, file_stat.size);
        errdefer allocator.free(buf);
        const result = c.mz_zip_reader_extract_to_mem(
            &ar.archive,
            @intCast(c.mz_uint, file_index),
            buf.ptr,
            buf.len,
            0,
        );
        if (result != 1) return ar.getLastError();
        return buf;
    }

    /// Read file's content into given buffer
    pub fn readFile(ar: *Archive, file_index: u32, buf: []u8) !void {
        assert(ar.mode == .read);
        const result = c.mz_zip_reader_extract_to_mem(
            &ar.archive,
            @intCast(c.mz_uint, file_index),
            buf.ptr,
            buf.len,
            0,
        );
        if (result != 1) return ar.getLastError();
    }

    /// Search for file in archive and return its index
    pub fn getFileIndex(
        ar: *Archive,
        archive_name: [:0]const u8,
        case_sensitivy: bool,
        ignore_path: bool,
    ) !u32 {
        assert(ar.mode == .read);
        var flags: c.mz_uint = 0;
        if (case_sensitivy) flags |= c.MZ_ZIP_FLAG_CASE_SENSITIVE;
        if (ignore_path) flags |= c.MZ_ZIP_FLAG_IGNORE_PATH;
        const index = c.mz_zip_reader_locate_file(&ar.archive, archive_name, null, flags);
        if (index < 0) return ar.getLastError();
        return @intCast(u32, index);
    }

    /// Get file's basic information
    pub fn getFileStat(ar: *Archive, file_index: u32) !FileStat {
        assert(ar.mode == .read);
        var mz_stat: c.mz_zip_archive_file_stat = undefined;
        const result = c.mz_zip_reader_file_stat(
            &ar.archive,
            @intCast(c.mz_uint, file_index),
            &mz_stat,
        );
        if (result != 1) return ar.getLastError();
        var info = FileStat{
            .size = @intCast(usize, mz_stat.m_uncomp_size),
            .is_dir = if (mz_stat.m_is_directory == 1) true else false,
            .is_encrypted = if (mz_stat.m_is_encrypted == 1) true else false,
            .is_supported = if (mz_stat.m_is_supported == 1) true else false,
        };
        std.mem.copy(u8, info.filename[0..512], mz_stat.m_filename[0..512]);
        info.filename_size = std.mem.indexOfSentinel(
            u8,
            0,
            @ptrCast([*:0]u8, &info.filename),
        );
        return info;
    }

    fn initArchive(ar: *Archive) void {
        c.mz_zip_zero_struct(&ar.archive);
    }

    fn getLastError(ar: *Archive) Error {
        const err = c.mz_zip_get_last_error(&ar.archive);
        return switch (err) {
            c.MZ_ZIP_UNDEFINED_ERROR => error.UndefinedError,
            c.MZ_ZIP_TOO_MANY_FILES => error.TooManyFiles,
            c.MZ_ZIP_FILE_TOO_LARGE => error.FileTooLarge,
            c.MZ_ZIP_UNSUPPORTED_METHOD => error.UnsupportedMethod,
            c.MZ_ZIP_UNSUPPORTED_ENCRYPTION => error.UnsupportedEncryption,
            c.MZ_ZIP_UNSUPPORTED_FEATURE => error.UnsupportedFeature,
            c.MZ_ZIP_FAILED_FINDING_CENTRAL_DIR => error.FailedFindingCentralDir,
            c.MZ_ZIP_NOT_AN_ARCHIVE => error.NotAnArchive,
            c.MZ_ZIP_INVALID_HEADER_OR_CORRUPTED => error.InvalidHeaderOrCorrupted,
            c.MZ_ZIP_UNSUPPORTED_MULTIDISK => error.UnsupportedMultidisk,
            c.MZ_ZIP_DECOMPRESSION_FAILED => error.DecompressionFailed,
            c.MZ_ZIP_COMPRESSION_FAILED => error.CompressionFailed,
            c.MZ_ZIP_UNEXPECTED_DECOMPRESSED_SIZE => error.UnexpectedDecompressedSize,
            c.MZ_ZIP_CRC_CHECK_FAILED => error.CrcCheckFailed,
            c.MZ_ZIP_UNSUPPORTED_CDIR_SIZE => error.UnsupportedCdirSize,
            c.MZ_ZIP_ALLOC_FAILED => error.AllocFailed,
            c.MZ_ZIP_FILE_OPEN_FAILED => error.FileOpenFailed,
            c.MZ_ZIP_FILE_CREATE_FAILED => error.FileCreateFailed,
            c.MZ_ZIP_FILE_WRITE_FAILED => error.FileWriteFailed,
            c.MZ_ZIP_FILE_READ_FAILED => error.FileReadFailed,
            c.MZ_ZIP_FILE_CLOSE_FAILED => error.FileCloseFailed,
            c.MZ_ZIP_FILE_SEEK_FAILED => error.FileSeekFailed,
            c.MZ_ZIP_FILE_STAT_FAILED => error.FileStatFailed,
            c.MZ_ZIP_INVALID_PARAMETER => error.InvalidParameter,
            c.MZ_ZIP_INVALID_FILENAME => error.InvalidFilename,
            c.MZ_ZIP_BUF_TOO_SMALL => error.BufTooSmall,
            c.MZ_ZIP_INTERNAL_ERROR => error.InternalError,
            c.MZ_ZIP_FILE_NOT_FOUND => error.FileNotFound,
            c.MZ_ZIP_ARCHIVE_TOO_LARGE => error.ArchiveTooLarge,
            c.MZ_ZIP_VALIDATION_FAILED => error.ValidationFailed,
            c.MZ_ZIP_WRITE_CALLBACK_FAILED => error.WriteCallbackFailed,
            else => unreachable,
        };
    }
};

test "main" {
    const zipfile = "test.zip";

    var ar = try Archive.init(std.testing.allocator, zipfile, .write);
    try ar.addDir(std.testing.allocator, "testdata", null);
    ar.deinit();

    ar = try Archive.init(std.testing.allocator, zipfile, .read);
    try testing.expectEqual(@intCast(u32, 4), ar.getNumberOfFiles());
    var buf = try ar.readFileAlloc(std.testing.allocator, "manifest.txt", true, false);
    try testing.expectEqualStrings("abc", buf);
    std.testing.allocator.free(buf);
    buf = try ar.readFileAlloc(std.testing.allocator, "all/a/a.txt", true, false);
    try testing.expectEqualStrings("a", buf);
    std.testing.allocator.free(buf);
    buf = try ar.readFileAlloc(std.testing.allocator, "all/b/b.txt", true, false);
    try testing.expectEqualStrings("b", buf);
    std.testing.allocator.free(buf);
    buf = try ar.readFileAlloc(std.testing.allocator, "all/c/c.txt", true, false);
    try testing.expectEqualStrings("c", buf);
    std.testing.allocator.free(buf);
    ar.deinit();
}
