//! A thread-safe container for all document related state like zig source files including `build.zig`.

const std = @import("std");
const builtin = @import("builtin");
const URI = @import("uri.zig");
const analysis = @import("analysis.zig");
const offsets = @import("offsets.zig");
const log = std.log.scoped(.store);
const lsp = @import("lsp");
const Ast = std.zig.Ast;
const BuildAssociatedConfig = @import("BuildAssociatedConfig.zig");
const BuildConfig = @import("build_runner/shared.zig").BuildConfig;
const tracy = @import("tracy");
const translate_c = @import("translate_c.zig");
const DocumentScope = @import("DocumentScope.zig");
const DiagnosticsCollection = @import("DiagnosticsCollection.zig");

const DocumentStore = @This();

allocator: std.mem.Allocator,
/// the DocumentStore assumes that `config` is not modified while calling one of its functions.
config: Config,
lock: std.Thread.RwLock = .{},
thread_pool: if (builtin.single_threaded) void else *std.Thread.Pool,
handles: std.StringArrayHashMapUnmanaged(*Handle) = .empty,
build_files: if (supports_build_system) std.StringArrayHashMapUnmanaged(*BuildFile) else void = if (supports_build_system) .empty else {},
cimports: if (supports_build_system) std.AutoArrayHashMapUnmanaged(Hash, translate_c.Result) else void = if (supports_build_system) .empty else {},
diagnostics_collection: *DiagnosticsCollection,
builds_in_progress: std.atomic.Value(i32) = .init(0),
transport: ?*lsp.Transport = null,
lsp_capabilities: struct {
    supports_work_done_progress: bool = false,
    supports_semantic_tokens_refresh: bool = false,
    supports_inlay_hints_refresh: bool = false,
} = .{},

pub const Uri = []const u8;

pub const Hasher = std.crypto.auth.siphash.SipHash128(1, 3);
pub const Hash = [Hasher.mac_length]u8;

pub const max_document_size = std.math.maxInt(u32);

pub const supports_build_system = std.process.can_spawn;

pub fn computeHash(bytes: []const u8) Hash {
    var hasher: Hasher = .init(&@splat(0));
    hasher.update(bytes);
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

pub const Config = struct {
    zig_exe_path: ?[]const u8,
    zig_lib_dir: ?std.Build.Cache.Directory,
    build_runner_path: ?[]const u8,
    builtin_path: ?[]const u8,
    global_cache_dir: ?std.Build.Cache.Directory,

    pub const init: Config = .{
        .zig_exe_path = null,
        .zig_lib_dir = null,
        .build_runner_path = null,
        .builtin_path = null,
        .global_cache_dir = null,
    };
};

/// Represents a `build.zig`
pub const BuildFile = struct {
    uri: Uri,
    /// this build file may have an explicitly specified path to builtin.zig
    builtin_uri: ?Uri = null,
    /// config options extracted from zls.build.json
    build_associated_config: ?std.json.Parsed(BuildAssociatedConfig) = null,
    impl: struct {
        mutex: std.Thread.Mutex = .{},
        build_runner_state: if (builtin.single_threaded) void else BuildRunnerState = if (builtin.single_threaded) {} else .idle,
        version: u32 = 0,
        /// contains information extracted from running build.zig with a custom build runner
        /// e.g. include paths & packages
        /// TODO this field should not be nullable, callsites should await the build config to be resolved
        /// and then continue instead of dealing with missing information.
        config: ?std.json.Parsed(BuildConfig) = null,
    } = .{},

    const BuildRunnerState = enum {
        idle,
        running,
        running_but_already_invalidated,
    };

    pub fn tryLockConfig(self: *BuildFile) ?BuildConfig {
        self.impl.mutex.lock();
        return if (self.impl.config) |cfg| cfg.value else {
            self.impl.mutex.unlock();
            return null;
        };
    }

    pub fn unlockConfig(self: *BuildFile) void {
        self.impl.mutex.unlock();
    }

    /// Usage example:
    /// ```zig
    /// const package_uris: std.ArrayListUnmanaged([]const u8) = .empty;
    /// defer {
    ///     for (package_uris) |uri| allocator.free(uri);
    ///     package_uris.deinit(allocator);
    /// }
    /// const success = try build_file.collectBuildConfigPackageUris(allocator, &package_uris);
    /// ```
    pub fn collectBuildConfigPackageUris(
        self: *BuildFile,
        allocator: std.mem.Allocator,
        package_uris: *std.ArrayListUnmanaged(Uri),
    ) error{OutOfMemory}!bool {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        const build_config = self.tryLockConfig() orelse return false;
        defer self.unlockConfig();

        try package_uris.ensureUnusedCapacity(allocator, build_config.packages.len);
        for (build_config.packages) |package| {
            package_uris.appendAssumeCapacity(try URI.fromPath(allocator, package.path));
        }
        return true;
    }

    /// Usage example:
    /// ```zig
    /// const include_paths: std.ArrayListUnmanaged([]u8) = .empty;
    /// defer {
    ///     for (include_paths) |path| allocator.free(path);
    ///     include_paths.deinit(allocator);
    /// }
    /// const success = try build_file.collectBuildConfigIncludePaths(allocator, &include_paths);
    /// ```
    pub fn collectBuildConfigIncludePaths(
        self: *BuildFile,
        allocator: std.mem.Allocator,
        include_paths: *std.ArrayListUnmanaged([]const u8),
    ) !bool {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        const build_config = self.tryLockConfig() orelse return false;
        defer self.unlockConfig();

        try include_paths.ensureUnusedCapacity(allocator, build_config.include_dirs.len);
        for (build_config.include_dirs) |include_path| {
            const absolute_path = if (std.fs.path.isAbsolute(include_path))
                try allocator.dupe(u8, include_path)
            else blk: {
                const build_file_dir = std.fs.path.dirname(self.uri).?;
                const build_file_path = try URI.toFsPath(allocator, build_file_dir);
                defer allocator.free(build_file_path);
                break :blk try std.fs.path.join(allocator, &.{ build_file_path, include_path });
            };

            include_paths.appendAssumeCapacity(absolute_path);
        }
        return true;
    }

    fn deinit(self: *BuildFile, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        if (self.impl.config) |cfg| cfg.deinit();
        if (self.builtin_uri) |builtin_uri| allocator.free(builtin_uri);
        if (self.build_associated_config) |cfg| cfg.deinit();
    }
};

/// Represents a Zig source file.
pub const Handle = struct {
    uri: Uri,
    version: u32 = 0,
    tree: Ast,
    /// Contains one entry for every import in the document
    import_uris: std.ArrayListUnmanaged(Uri) = .empty,
    /// Contains one entry for every cimport in the document
    cimports: std.MultiArrayList(CImportHandle) = .empty,

    /// private field
    impl: struct {
        /// @bitCast from/to `Status`
        status: std.atomic.Value(u32) = .init(@bitCast(Status{})),
        /// TODO can we avoid storing one allocator per Handle?
        allocator: std.mem.Allocator,

        lock: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},

        document_scope: DocumentScope = undefined,
        zir: std.zig.Zir = undefined,
        zoir: std.zig.Zoir = undefined,

        associated_build_file: union(enum) {
            /// The Handle has no associated build file (build.zig).
            none,
            /// The associated build file (build.zig) has not been resolved yet.
            /// Uris that come first have higher priority.
            unresolved: struct {
                potential_build_files: []const *BuildFile,
                /// to avoid checking build files multiple times, a bitset stores whether or
                /// not the build file should be skipped because it has previously been
                /// found to be "unassociated" with the handle.
                has_been_checked: std.DynamicBitSetUnmanaged,

                fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    allocator.free(self.potential_build_files);
                    self.has_been_checked.deinit(allocator);
                    self.* = undefined;
                }
            },
            /// The associated build file (build.zig) has been successfully resolved.
            resolved: *BuildFile,
        } = .none,
    },

    const Status = packed struct(u32) {
        /// `true` if the document has been directly opened by the client i.e. with `textDocument/didOpen`
        /// `false` indicates the document only exists because it is a dependency of another document
        /// or has been closed with `textDocument/didClose` and is awaiting cleanup through `garbageCollection`
        open: bool = false,
        /// true if a thread has acquired the permission to compute the `DocumentScope`
        /// all other threads will wait until the given thread has computed the `DocumentScope` before reading it.
        has_document_scope_lock: bool = false,
        /// true if `handle.impl.document_scope` has been set
        has_document_scope: bool = false,
        /// true if a thread has acquired the permission to compute the `std.zig.Zir`
        has_zir_lock: bool = false,
        /// all other threads will wait until the given thread has computed the `std.zig.Zir` before reading it.
        /// true if `handle.impl.zir` has been set
        has_zir: bool = false,
        zir_outdated: bool = undefined,
        /// true if a thread has acquired the permission to compute the `std.zig.Zoir`
        has_zoir_lock: bool = false,
        /// all other threads will wait until the given thread has computed the `std.zig.Zoir` before reading it.
        /// true if `handle.impl.zoir` has been set
        has_zoir: bool = false,
        zoir_outdated: bool = undefined,
        _: u23 = undefined,
    };

    pub const ZirOrZoirStatus = enum {
        none,
        outdated,
        done,
    };

    /// takes ownership of `text`
    pub fn init(allocator: std.mem.Allocator, uri: Uri, text: [:0]const u8) error{OutOfMemory}!Handle {
        const duped_uri = try allocator.dupe(u8, uri);
        errdefer allocator.free(duped_uri);

        const mode: Ast.Mode = if (std.mem.eql(u8, std.fs.path.extension(uri), ".zon")) .zon else .zig;

        const tree = try parseTree(allocator, text, mode);
        errdefer tree.deinit(allocator);

        return .{
            .uri = duped_uri,
            .tree = tree,
            .impl = .{
                .allocator = allocator,
            },
        };
    }

    pub fn getDocumentScope(self: *Handle) error{OutOfMemory}!DocumentScope {
        if (self.getStatus().has_document_scope) return self.impl.document_scope;
        return try self.getDocumentScopeCold();
    }

    /// Asserts that `getDocumentScope` has been previously called on `handle`.
    pub fn getDocumentScopeCached(self: *Handle) DocumentScope {
        if (builtin.mode == .Debug) {
            std.debug.assert(self.getStatus().has_document_scope);
        }
        return self.impl.document_scope;
    }

    pub fn getZir(self: *Handle) error{OutOfMemory}!std.zig.Zir {
        std.debug.assert(self.tree.mode == .zig);
        if (self.getStatus().has_zir) return self.impl.zir;
        return try self.getZirOrZoirCold(.zir);
    }

    pub fn getZirStatus(self: *const Handle) ZirOrZoirStatus {
        const status = self.getStatus();
        if (!status.has_zir) return .none;
        return if (status.zir_outdated) .outdated else .done;
    }

    pub fn getZoir(self: *Handle) error{OutOfMemory}!std.zig.Zoir {
        std.debug.assert(self.tree.mode == .zon);
        if (self.getStatus().has_zoir) return self.impl.zoir;
        return try self.getZirOrZoirCold(.zoir);
    }

    pub fn getZoirStatus(self: *const Handle) ZirOrZoirStatus {
        const status = self.getStatus();
        if (!status.has_zoir) return .none;
        return if (status.zoir_outdated) .outdated else .done;
    }

    /// Returns the associated build file (build.zig) of the handle.
    ///
    /// `DocumentStore.build_files` is guaranteed to contain this Uri.
    /// Uri memory managed by its build_file
    pub fn getAssociatedBuildFileUri(self: *Handle, document_store: *DocumentStore) error{OutOfMemory}!?Uri {
        comptime std.debug.assert(supports_build_system);
        switch (try self.getAssociatedBuildFileUri2(document_store)) {
            .none,
            .unresolved,
            => return null,
            .resolved => |build_file| return build_file.uri,
        }
    }

    /// Returns the associated build file (build.zig) of the handle.
    ///
    /// `DocumentStore.build_files` is guaranteed to contain this Uri.
    /// Uri memory managed by its build_file
    pub fn getAssociatedBuildFileUri2(self: *Handle, document_store: *DocumentStore) error{OutOfMemory}!union(enum) {
        /// The Handle has no associated build file (build.zig).
        none,
        /// The associated build file (build.zig) has not been resolved yet.
        unresolved,
        /// The associated build file (build.zig) has been successfully resolved.
        resolved: *BuildFile,
    } {
        comptime std.debug.assert(supports_build_system);

        self.impl.lock.lock();
        defer self.impl.lock.unlock();

        const unresolved = switch (self.impl.associated_build_file) {
            .none => return .none,
            .unresolved => |*unresolved| unresolved,
            .resolved => |build_file| return .{ .resolved = build_file },
        };

        // special case when there is only one potential build file
        if (unresolved.potential_build_files.len == 1) {
            const build_file = unresolved.potential_build_files[0];
            log.debug("Resolved build file of '{s}' as '{s}'", .{ self.uri, build_file.uri });
            unresolved.deinit(document_store.allocator);
            self.impl.associated_build_file = .{ .resolved = build_file };
            return .{ .resolved = build_file };
        }

        var has_missing_build_config = false;

        var it = unresolved.has_been_checked.iterator(.{
            .kind = .unset,
            .direction = .reverse,
        });
        while (it.next()) |i| {
            const build_file = unresolved.potential_build_files[i];
            const is_associated = try document_store.uriAssociatedWithBuild(build_file, self.uri) orelse {
                has_missing_build_config = true;
                continue;
            };

            if (!is_associated) {
                // the build file should be skipped in future calls.
                unresolved.has_been_checked.set(i);
                continue;
            }

            log.debug("Resolved build file of '{s}' as '{s}'", .{ self.uri, build_file.uri });
            unresolved.deinit(document_store.allocator);
            self.impl.associated_build_file = .{ .resolved = build_file };
            return .{ .resolved = build_file };
        }

        if (has_missing_build_config) {
            // when build configs are missing we keep the state at .unresolved so that
            // future calls will retry until all build config are resolved.
            // Then will have a conclusive result on whether or not there is a associated build file.
            return .unresolved;
        }

        unresolved.deinit(document_store.allocator);
        self.impl.associated_build_file = .none;
        return .none;
    }

    fn getAssociatedBuildFileUriDontResolve(self: *Handle) ?Uri {
        self.impl.lock.lock();
        defer self.impl.lock.unlock();

        switch (self.impl.associated_build_file) {
            .none, .unresolved => return null,
            .resolved => |build_file| return build_file.uri,
        }
    }

    fn getReferencedBuildFiles(self: *Handle) []const *BuildFile {
        switch (self.impl.associated_build_file) {
            .none => return &.{},
            .unresolved => |unresolved| return unresolved.potential_build_files, // some of these could be removed because of `has_been_checked`
            .resolved => |*build_file| return build_file[0..1],
        }
    }

    fn getDocumentScopeCold(self: *Handle) error{OutOfMemory}!DocumentScope {
        @branchHint(.cold);
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        self.impl.lock.lock();
        defer self.impl.lock.unlock();
        while (true) {
            const status = self.getStatus();
            if (status.has_document_scope) break;
            if (status.has_document_scope_lock or
                self.impl.status.bitSet(@bitOffsetOf(Status, "has_document_scope_lock"), .release) != 0)
            {
                // another thread is currently computing the document scope
                self.impl.condition.wait(&self.impl.lock);
                continue;
            }
            defer self.impl.condition.broadcast();

            self.impl.document_scope = blk: {
                var document_scope: DocumentScope = try .init(self.impl.allocator, self.tree);
                errdefer document_scope.deinit(self.impl.allocator);

                // remove unused capacity
                document_scope.extra.shrinkAndFree(self.impl.allocator, document_scope.extra.items.len);
                try document_scope.declarations.setCapacity(self.impl.allocator, document_scope.declarations.len);
                try document_scope.scopes.setCapacity(self.impl.allocator, document_scope.scopes.len);

                break :blk document_scope;
            };
            const old_has_document_scope = self.impl.status.bitSet(@bitOffsetOf(Status, "has_document_scope"), .release); // atomically set has_document_scope
            std.debug.assert(old_has_document_scope == 0); // race condition: another thread set `has_document_scope` even though we hold the lock
        }
        return self.impl.document_scope;
    }

    fn getZirOrZoirCold(self: *Handle, comptime kind: enum { zir, zoir }) error{OutOfMemory}!switch (kind) {
        .zir => std.zig.Zir,
        .zoir => std.zig.Zoir,
    } {
        @branchHint(.cold);
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        const has_field = "has_" ++ @tagName(kind);
        const has_lock_field = "has_" ++ @tagName(kind) ++ "_lock";
        const outdated_field = @tagName(kind) ++ "_outdated";

        self.impl.lock.lock();
        defer self.impl.lock.unlock();
        while (true) {
            const status = self.getStatus();
            if (@field(status, has_field)) break;
            if (@field(status, has_lock_field) or
                self.impl.status.bitSet(@bitOffsetOf(Status, has_lock_field), .release) != 0)
            {
                // another thread is currently computing the ZIR
                self.impl.condition.wait(&self.impl.lock);
                continue;
            }
            defer self.impl.condition.broadcast();

            switch (kind) {
                .zir => {
                    const tracy_zone_inner = tracy.traceNamed(@src(), "AstGen.generate");
                    defer tracy_zone_inner.end();

                    var zir = try std.zig.AstGen.generate(self.impl.allocator, self.tree);
                    errdefer zir.deinit(self.impl.allocator);

                    // remove unused capacity
                    var instructions = zir.instructions.toMultiArrayList();
                    try instructions.setCapacity(self.impl.allocator, instructions.len);
                    zir.instructions = instructions.slice();

                    self.impl.zir = zir;
                },
                .zoir => {
                    const tracy_zone_inner = tracy.traceNamed(@src(), "ZonGen.generate");
                    defer tracy_zone_inner.end();

                    var zoir = try std.zig.ZonGen.generate(self.impl.allocator, self.tree, .{});
                    errdefer zoir.deinit(self.impl.allocator);

                    self.impl.zoir = zoir;
                },
            }

            _ = self.impl.status.bitReset(@bitOffsetOf(Status, outdated_field), .release); // atomically set [zir|zoir]_outdated
            const old_has = self.impl.status.bitSet(@bitOffsetOf(Status, has_field), .release); // atomically set has_[zir|zoir]
            std.debug.assert(old_has == 0); // race condition: another thread set Zir or Zoir even though we hold the lock
        }
        return switch (kind) {
            .zir => self.impl.zir,
            .zoir => self.impl.zoir,
        };
    }

    fn getStatus(self: *const Handle) Status {
        return @bitCast(self.impl.status.load(.acquire));
    }

    pub fn isOpen(self: *const Handle) bool {
        return self.getStatus().open;
    }

    /// returns the previous value
    fn setOpen(self: *Handle, open: bool) bool {
        if (open) {
            return self.impl.status.bitSet(@offsetOf(Handle.Status, "open"), .release) == 1;
        } else {
            return self.impl.status.bitReset(@offsetOf(Handle.Status, "open"), .release) == 1;
        }
    }

    fn parseTree(allocator: std.mem.Allocator, new_text: [:0]const u8, mode: Ast.Mode) error{OutOfMemory}!Ast {
        const tracy_zone_inner = tracy.traceNamed(@src(), "Ast.parse");
        defer tracy_zone_inner.end();

        var tree = try Ast.parse(allocator, new_text, mode);
        errdefer tree.deinit(allocator);

        // remove unused capacity
        var nodes = tree.nodes.toMultiArrayList();
        try nodes.setCapacity(allocator, nodes.len);
        tree.nodes = nodes.slice();

        // remove unused capacity
        var tokens = tree.tokens.toMultiArrayList();
        try tokens.setCapacity(allocator, tokens.len);
        tree.tokens = tokens.slice();
        return tree;
    }

    /// Takes ownership of `new_text`.
    fn setSource(self: *Handle, new_text: [:0]const u8) error{OutOfMemory}!void {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        const new_status: Handle.Status = .{
            .open = self.getStatus().open,
        };

        const new_tree = try parseTree(self.impl.allocator, new_text, self.tree.mode);

        self.impl.lock.lock();
        errdefer @compileError("");

        const old_status: Handle.Status = @bitCast(self.impl.status.swap(@bitCast(new_status), .acq_rel));

        var old_tree = self.tree;
        var old_import_uris = self.import_uris;
        var old_cimports = self.cimports;
        var old_document_scope = if (old_status.has_document_scope) self.impl.document_scope else null;
        var old_zir = if (old_status.has_zir) self.impl.zir else null;
        var old_zoir = if (old_status.has_zoir) self.impl.zoir else null;

        self.tree = new_tree;
        self.import_uris = .empty;
        self.cimports = .empty;
        self.impl.document_scope = undefined;
        self.impl.zir = undefined;
        self.impl.zoir = undefined;

        self.version += 1;

        self.impl.lock.unlock();

        self.impl.allocator.free(old_tree.source);
        old_tree.deinit(self.impl.allocator);

        for (old_import_uris.items) |uri| self.impl.allocator.free(uri);
        old_import_uris.deinit(self.impl.allocator);

        for (old_cimports.items(.source)) |source| self.impl.allocator.free(source);
        old_cimports.deinit(self.impl.allocator);

        if (old_document_scope) |*document_scope| document_scope.deinit(self.impl.allocator);
        if (old_zir) |*zir| zir.deinit(self.impl.allocator);
        if (old_zoir) |*zoir| zoir.deinit(self.impl.allocator);
    }

    fn deinit(self: *Handle) void {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        const status = self.getStatus();

        const allocator = self.impl.allocator;

        if (status.has_zir) self.impl.zir.deinit(allocator);
        if (status.has_zoir) self.impl.zoir.deinit(allocator);
        if (status.has_document_scope) self.impl.document_scope.deinit(allocator);
        allocator.free(self.tree.source);
        self.tree.deinit(allocator);
        allocator.free(self.uri);

        for (self.import_uris.items) |uri| allocator.free(uri);
        self.import_uris.deinit(allocator);

        for (self.cimports.items(.source)) |source| allocator.free(source);
        self.cimports.deinit(allocator);

        switch (self.impl.associated_build_file) {
            .none, .resolved => {},
            .unresolved => |*payload| payload.deinit(allocator),
        }

        self.* = undefined;
    }
};

pub const ErrorMessage = struct {
    loc: offsets.Loc,
    code: []const u8,
    message: []const u8,
};

pub fn deinit(self: *DocumentStore) void {
    for (self.handles.values()) |handle| {
        handle.deinit();
        self.allocator.destroy(handle);
    }
    self.handles.deinit(self.allocator);

    if (supports_build_system) {
        for (self.build_files.values()) |build_file| {
            build_file.deinit(self.allocator);
            self.allocator.destroy(build_file);
        }
        self.build_files.deinit(self.allocator);

        for (self.cimports.values()) |*result| {
            result.deinit(self.allocator);
        }
        self.cimports.deinit(self.allocator);
    }

    self.* = undefined;
}

/// Returns a handle to the given document
/// **Thread safe** takes a shared lock
/// This function does not protect against data races from modifying the Handle
pub fn getHandle(self: *DocumentStore, uri: Uri) ?*Handle {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.handles.get(uri);
}

/// Returns a handle to the given document
/// Will load the document from disk if it hasn't been already
/// **Thread safe** takes an exclusive lock
/// This function does not protect against data races from modifying the Handle
pub fn getOrLoadHandle(self: *DocumentStore, uri: Uri) ?*Handle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (self.getHandle(uri)) |handle| return handle;

    const file_path = URI.toFsPath(self.allocator, uri) catch |err| {
        log.err("failed to parse URI '{s}': {}", .{ uri, err });
        return null;
    };
    defer self.allocator.free(file_path);

    if (!std.fs.path.isAbsolute(file_path)) {
        log.err("file path is not absolute '{s}'", .{file_path});
        return null;
    }

    const dir, const sub_path = blk: {
        if (builtin.target.cpu.arch.isWasm() and !builtin.link_libc) {
            // look up whether the file path refers to a preopen directory.
            for ([_]?std.Build.Cache.Directory{
                self.config.zig_lib_dir,
                self.config.global_cache_dir,
            }) |opt_preopen_dir| {
                const preopen_dir = opt_preopen_dir orelse continue;
                const preopen_path = preopen_dir.path.?;
                std.debug.assert(std.mem.eql(u8, preopen_path, "/lib") or std.mem.eql(u8, preopen_path, "/cache"));

                if (!std.mem.startsWith(u8, file_path, preopen_path)) continue;
                if (!std.mem.startsWith(u8, file_path[preopen_path.len..], "/")) continue;

                break :blk .{ preopen_dir.handle, file_path[preopen_path.len + 1 ..] };
            }
        }
        break :blk .{ std.fs.cwd(), file_path };
    };

    const file_contents = dir.readFileAllocOptions(
        self.allocator,
        sub_path,
        max_document_size,
        null,
        .of(u8),
        0,
    ) catch |err| {
        log.err("failed to read document '{s}': {}", .{ file_path, err });
        return null;
    };

    return self.createAndStoreDocument(uri, file_contents) catch |err| {
        log.err("failed to store document '{s}': {}", .{ file_path, err });
        return null;
    };
}

/// **Thread safe** takes a shared lock
/// This function does not protect against data races from modifying the BuildFile
pub fn getBuildFile(self: *DocumentStore, uri: Uri) ?*BuildFile {
    comptime std.debug.assert(supports_build_system);
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.build_files.get(uri);
}

/// invalidates any pointers into `DocumentStore.build_files`
/// **Thread safe** takes an exclusive lock
/// This function does not protect against data races from modifying the BuildFile
fn getOrLoadBuildFile(self: *DocumentStore, uri: Uri) ?*BuildFile {
    comptime std.debug.assert(supports_build_system);

    if (self.getBuildFile(uri)) |build_file| return build_file;

    const new_build_file: *BuildFile = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        const gop = self.build_files.getOrPut(self.allocator, uri) catch return null;
        if (gop.found_existing) return gop.value_ptr.*;

        gop.value_ptr.* = self.allocator.create(BuildFile) catch |err| {
            self.build_files.swapRemoveAt(gop.index);
            log.debug("Failed to load build file {s}: {}", .{ uri, err });
            return null;
        };

        gop.value_ptr.*.* = self.createBuildFile(uri) catch |err| {
            self.allocator.destroy(gop.value_ptr.*);
            self.build_files.swapRemoveAt(gop.index);
            log.debug("Failed to load build file {s}: {}", .{ uri, err });
            return null;
        };
        gop.key_ptr.* = gop.value_ptr.*.uri;
        break :blk gop.value_ptr.*;
    };

    // this code path is only reached when the build file is new

    self.invalidateBuildFile(new_build_file.uri);

    return new_build_file;
}

/// **Not thread safe**
/// Assumes that no other thread is currently accessing the given document
pub fn openDocument(self: *DocumentStore, uri: Uri, text: []const u8) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const handle_ptr: *Handle = try self.allocator.create(Handle);
    errdefer self.allocator.destroy(handle_ptr);

    const duped_text = try self.allocator.dupeZ(u8, text);
    handle_ptr.* = try self.createDocument(uri, duped_text, true);
    errdefer handle_ptr.deinit();

    const gop = try self.handles.getOrPut(self.allocator, handle_ptr.uri);
    if (gop.found_existing) {
        if (gop.value_ptr.*.isOpen()) {
            log.warn("Document already open: {s}", .{uri});
        }
        std.mem.swap([]const u8, &gop.value_ptr.*.uri, &handle_ptr.uri);
        gop.value_ptr.*.deinit();
        self.allocator.destroy(gop.value_ptr.*);
    }
    gop.value_ptr.* = handle_ptr;

    if (isBuildFile(uri)) {
        log.debug("Opened document '{s}' (build file)", .{uri});
    } else {
        log.debug("Opened document '{s}'", .{uri});
    }
}

/// **Thread safe** takes a shared lock, takes an exclusive lock (with `tryLock`)
/// Assumes that no other thread is currently accessing the given document
pub fn closeDocument(self: *DocumentStore, uri: Uri) void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const handle = self.handles.get(uri) orelse {
            log.warn("Document not found: {s}", .{uri});
            return;
        };
        // instead of destroying the handle here we just mark it not open
        // and let it be destroy by the garbage collection code
        if (!handle.setOpen(false)) {
            log.warn("Document already closed: {s}", .{uri});
        }
    }

    if (!self.lock.tryLock()) return;
    defer self.lock.unlock();

    self.garbageCollectionImports() catch {};
    if (supports_build_system) {
        self.garbageCollectionCImports() catch {};
        self.garbageCollectionBuildFiles() catch {};
    }
}

/// Takes ownership of `new_text` which has to be allocated with this DocumentStore's allocator.
/// Assumes that a document with the given `uri` is in the DocumentStore.
///
/// **Thread safe** takes a shared lock when called on different documents
/// **Not thread safe** when called on the same document
pub fn refreshDocument(self: *DocumentStore, uri: Uri, new_text: [:0]const u8) !void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const handle = self.getHandle(uri).?;
    if (!handle.getStatus().open) {
        log.warn("Document modified without being opened: {s}", .{uri});
    }
    try handle.setSource(new_text);
    handle.import_uris = try self.collectImportUris(handle);
    handle.cimports = try collectCIncludes(self.allocator, handle.tree);
}

/// Removes a document from the store, unless said document is currently open and
/// has been synchronized via `textDocument/didOpen`.
/// **Thread safe** takes an exclusive lock when called on different documents
/// **Not thread safe** when called on the same document
pub fn refreshDocumentFromFileSystem(self: *DocumentStore, uri: Uri) !bool {
    {
        const handle = self.getHandle(uri) orelse return false;
        if (handle.getStatus().open) return false;
    }

    {
        self.lock.lock();
        defer self.lock.unlock();

        const kv = self.handles.fetchSwapRemove(uri) orelse return false;
        log.debug("Closing document {s}", .{kv.key});
        kv.value.deinit();
        self.allocator.destroy(kv.value);
        return true;
    }
}

/// Invalidates a build files.
/// **Thread safe** takes a shared lock
pub fn invalidateBuildFile(self: *DocumentStore, build_file_uri: Uri) void {
    comptime std.debug.assert(supports_build_system);

    if (self.config.zig_exe_path == null) return;
    if (self.config.build_runner_path == null) return;
    if (self.config.global_cache_dir == null) return;
    if (self.config.zig_lib_dir == null) return;

    const build_file = self.getBuildFile(build_file_uri) orelse return;

    if (builtin.single_threaded) {
        self.invalidateBuildFileWorker(build_file);
        return;
    }

    self.thread_pool.spawn(invalidateBuildFileWorker, .{ self, build_file }) catch {
        self.invalidateBuildFileWorker(build_file);
        return;
    };
}

const progress_token = "buildProgressToken";

fn sendMessageToClient(allocator: std.mem.Allocator, transport: *lsp.Transport, message: anytype) !void {
    const serialized = try std.json.Stringify.valueAlloc(
        allocator,
        message,
        .{ .emit_null_optional_fields = false },
    );
    defer allocator.free(serialized);

    try transport.writeJsonMessage(serialized);
}

fn notifyBuildStart(self: *DocumentStore) void {
    if (!self.lsp_capabilities.supports_work_done_progress) return;

    const transport = self.transport orelse return;

    // Atomicity note: We do not actually care about memory surrounding the
    // counter, we only care about the counter itself. We only need to ensure
    // we aren't double entering/exiting
    const prev = self.builds_in_progress.fetchAdd(1, .monotonic);
    if (prev != 0) return;

    sendMessageToClient(
        self.allocator,
        transport,
        .{
            .jsonrpc = "2.0",
            .id = "progress",
            .method = "window/workDoneProgress/create",
            .params = lsp.types.WorkDoneProgressCreateParams{
                .token = .{ .string = progress_token },
            },
        },
    ) catch |err| {
        log.err("Failed to send create work message: {}", .{err});
        return;
    };

    sendMessageToClient(self.allocator, transport, .{
        .jsonrpc = "2.0",
        .method = "$/progress",
        .params = .{
            .token = progress_token,
            .value = lsp.types.WorkDoneProgressBegin{
                .title = "Loading build configuration",
            },
        },
    }) catch |err| {
        log.err("Failed to send progress start message: {}", .{err});
        return;
    };
}

const EndStatus = enum { success, failed };

fn notifyBuildEnd(self: *DocumentStore, status: EndStatus) void {
    if (!self.lsp_capabilities.supports_work_done_progress) return;

    const transport = self.transport orelse return;

    // Atomicity note: We do not actually care about memory surrounding the
    // counter, we only care about the counter itself. We only need to ensure
    // we aren't double entering/exiting
    const prev = self.builds_in_progress.fetchSub(1, .monotonic);
    if (prev != 1) return;

    const message = switch (status) {
        .failed => "Failed",
        .success => "Success",
    };

    sendMessageToClient(self.allocator, transport, .{
        .jsonrpc = "2.0",
        .method = "$/progress",
        .params = .{
            .token = progress_token,
            .value = lsp.types.WorkDoneProgressEnd{
                .message = message,
            },
        },
    }) catch |err| {
        log.err("Failed to send progress end message: {}", .{err});
        return;
    };
}

fn invalidateBuildFileWorker(self: *DocumentStore, build_file: *BuildFile) void {
    {
        build_file.impl.mutex.lock();
        defer build_file.impl.mutex.unlock();

        switch (build_file.impl.build_runner_state) {
            .idle => build_file.impl.build_runner_state = .running,
            .running => {
                build_file.impl.build_runner_state = .running_but_already_invalidated;
                return;
            },
            .running_but_already_invalidated => return,
        }
    }

    self.notifyBuildStart();

    while (true) {
        build_file.impl.version += 1;
        const new_version = build_file.impl.version;

        const build_config = loadBuildConfiguration(self, build_file.uri, new_version) catch |err| {
            if (err != error.RunFailed) { // already logged
                log.err("Failed to load build configuration for {s} (error: {})", .{ build_file.uri, err });
            }
            self.notifyBuildEnd(.failed);
            build_file.impl.mutex.lock();
            defer build_file.impl.mutex.unlock();
            build_file.impl.build_runner_state = .idle;
            return;
        };

        build_file.impl.mutex.lock();
        switch (build_file.impl.build_runner_state) {
            .idle => unreachable,
            .running => {
                var old_config = build_file.impl.config;
                build_file.impl.config = build_config;
                build_file.impl.build_runner_state = .idle;
                build_file.impl.mutex.unlock();

                if (old_config) |*config| config.deinit();
                self.notifyBuildEnd(.success);
                break;
            },
            .running_but_already_invalidated => {
                build_file.impl.build_runner_state = .running;
                build_file.impl.mutex.unlock();

                build_config.deinit();
                continue;
            },
        }
    }

    if (self.transport) |transport| {
        if (self.lsp_capabilities.supports_semantic_tokens_refresh) {
            sendMessageToClient(
                self.allocator,
                transport,
                lsp.TypedJsonRPCRequest(?void){
                    .id = .{ .string = "semantic_tokens_refresh" },
                    .method = "workspace/semanticTokens/refresh",
                    .params = @as(?void, null),
                },
            ) catch {};
        }
        if (self.lsp_capabilities.supports_inlay_hints_refresh) {
            sendMessageToClient(
                self.allocator,
                transport,
                lsp.TypedJsonRPCRequest(?void){
                    .id = .{ .string = "inlay_hints_refresh" },
                    .method = "workspace/inlayHint/refresh",
                    .params = @as(?void, null),
                },
            ) catch {};
        }
    }
}

/// The `DocumentStore` represents a graph structure where every
/// handle/document is a node and every `@import` and `@cImport` represent
/// a directed edge.
/// We can remove every document which cannot be reached from
/// another document that is `open` (see `Handle.open`)
/// **Not thread safe** requires access to `DocumentStore.handles`, `DocumentStore.cimports` and `DocumentStore.build_files`
fn garbageCollectionImports(self: *DocumentStore) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    var reachable: std.DynamicBitSetUnmanaged = try .initEmpty(arena.allocator(), self.handles.count());

    var queue: std.ArrayListUnmanaged(Uri) = .empty;

    for (self.handles.values(), 0..) |handle, handle_index| {
        if (!handle.getStatus().open) continue;
        reachable.set(handle_index);

        try self.collectDependenciesInternal(arena.allocator(), handle, &queue, false);
    }

    while (queue.pop()) |uri| {
        const handle_index = self.handles.getIndex(uri) orelse continue;
        if (reachable.isSet(handle_index)) continue;
        reachable.set(handle_index);

        const handle = self.handles.values()[handle_index];

        try self.collectDependenciesInternal(arena.allocator(), handle, &queue, false);
    }

    var it = reachable.iterator(.{
        .kind = .unset,
        .direction = .reverse,
    });

    while (it.next()) |handle_index| {
        const handle = self.handles.values()[handle_index];
        log.debug("Closing document {s}", .{handle.uri});
        self.handles.swapRemoveAt(handle_index);
        handle.deinit();
        self.allocator.destroy(handle);
    }
}

/// see `garbageCollectionImports`
/// **Not thread safe** requires access to `DocumentStore.handles` and `DocumentStore.cimports`
fn garbageCollectionCImports(self: *DocumentStore) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (self.cimports.count() == 0) return;

    var reachable: std.DynamicBitSetUnmanaged = try .initEmpty(self.allocator, self.cimports.count());
    defer reachable.deinit(self.allocator);

    for (self.handles.values()) |handle| {
        for (handle.cimports.items(.hash)) |hash| {
            const index = self.cimports.getIndex(hash) orelse continue;
            reachable.set(index);
        }
    }

    var it = reachable.iterator(.{
        .kind = .unset,
        .direction = .reverse,
    });

    while (it.next()) |cimport_index| {
        var result = self.cimports.values()[cimport_index];
        const message = switch (result) {
            .failure => "",
            .success => |uri| uri,
        };
        log.debug("Destroying cimport {s}", .{message});
        self.cimports.swapRemoveAt(cimport_index);
        result.deinit(self.allocator);
    }
}

/// see `garbageCollectionImports`
/// **Not thread safe** requires access to `DocumentStore.handles` and `DocumentStore.build_files`
fn garbageCollectionBuildFiles(self: *DocumentStore) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (self.build_files.count() == 0) return;

    var reachable: std.DynamicBitSetUnmanaged = try .initEmpty(self.allocator, self.build_files.count());
    defer reachable.deinit(self.allocator);

    var queue: std.ArrayListUnmanaged(*BuildFile) = .empty;
    defer queue.deinit(self.allocator);

    for (self.handles.values()) |handle| {
        for (handle.getReferencedBuildFiles()) |build_file| {
            const build_file_index = self.build_files.getIndex(build_file.uri).?;
            if (reachable.isSet(build_file_index)) continue;
            try queue.append(self.allocator, build_file);
        }

        if (isBuildFile(handle.uri)) blk: {
            const build_file_index = self.build_files.getIndex(handle.uri) orelse break :blk;
            const build_file = self.build_files.values()[build_file_index];
            if (reachable.isSet(build_file_index)) break :blk;
            try queue.append(self.allocator, build_file);
        }
    }

    while (queue.pop()) |build_file| {
        const build_file_index = self.build_files.getIndex(build_file.uri).?;
        if (reachable.isSet(build_file_index)) continue;
        reachable.set(build_file_index);

        const build_config = build_file.tryLockConfig() orelse continue;
        defer build_file.unlockConfig();

        try queue.ensureUnusedCapacity(self.allocator, build_config.deps_build_roots.len);
        for (build_config.deps_build_roots) |dep_build_root| {
            const dep_build_file_uri = try URI.fromPath(self.allocator, dep_build_root.path);
            defer self.allocator.free(dep_build_file_uri);
            const dep_build_file = self.build_files.get(dep_build_file_uri) orelse continue;
            queue.appendAssumeCapacity(dep_build_file);
        }
    }

    var it = reachable.iterator(.{
        .kind = .unset,
        .direction = .reverse,
    });

    while (it.next()) |build_file_index| {
        const build_file = self.build_files.values()[build_file_index];
        log.debug("Destroying build file {s}", .{build_file.uri});
        self.build_files.swapRemoveAt(build_file_index);
        build_file.deinit(self.allocator);
        self.allocator.destroy(build_file);
    }
}

pub fn isBuildFile(uri: Uri) bool {
    return std.mem.endsWith(u8, uri, "/build.zig");
}

pub fn isBuiltinFile(uri: Uri) bool {
    return std.mem.endsWith(u8, uri, "/builtin.zig");
}

pub fn isInStd(uri: Uri) bool {
    // TODO: Better logic for detecting std or subdirectories?
    return std.mem.indexOf(u8, uri, "/std/") != null;
}

/// looks for a `zls.build.json` file in the build file directory
/// has to be freed with `json_compat.parseFree`
fn loadBuildAssociatedConfiguration(allocator: std.mem.Allocator, build_file: BuildFile) !std.json.Parsed(BuildAssociatedConfig) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const build_file_path = try URI.toFsPath(allocator, build_file.uri);
    defer allocator.free(build_file_path);
    const config_file_path = try std.fs.path.resolve(allocator, &.{ build_file_path, "..", "zls.build.json" });
    defer allocator.free(config_file_path);

    var config_file = try std.fs.cwd().openFile(config_file_path, .{});
    defer config_file.close();

    const file_buf = try config_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(file_buf);

    return try std.json.parseFromSlice(
        BuildAssociatedConfig,
        allocator,
        file_buf,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

fn prepareBuildRunnerArgs(self: *DocumentStore, build_file_uri: []const u8) ![][]const u8 {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const base_args = &[_][]const u8{
        self.config.zig_exe_path.?,
        "build",
        "--build-runner",
        self.config.build_runner_path.?,
        "--zig-lib-dir",
        self.config.zig_lib_dir.?.path orelse ".",
    };

    var args: std.ArrayListUnmanaged([]const u8) = try .initCapacity(self.allocator, base_args.len);
    errdefer {
        for (args.items) |arg| self.allocator.free(arg);
        args.deinit(self.allocator);
    }

    for (base_args) |arg| {
        args.appendAssumeCapacity(try self.allocator.dupe(u8, arg));
    }

    if (self.getBuildFile(build_file_uri)) |build_file| blk: {
        const build_config = build_file.build_associated_config orelse break :blk;
        const build_options = build_config.value.build_options orelse break :blk;

        try args.ensureUnusedCapacity(self.allocator, build_options.len);
        for (build_options) |option| {
            args.appendAssumeCapacity(try option.formatParam(self.allocator));
        }
    }

    return try args.toOwnedSlice(self.allocator);
}

/// Runs the build.zig and extracts include directories and packages
fn loadBuildConfiguration(self: *DocumentStore, build_file_uri: Uri, build_file_version: u32) !std.json.Parsed(BuildConfig) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    std.debug.assert(self.config.zig_exe_path != null);
    std.debug.assert(self.config.build_runner_path != null);
    std.debug.assert(self.config.global_cache_dir != null);
    std.debug.assert(self.config.zig_lib_dir != null);

    const build_file_path = try URI.toFsPath(self.allocator, build_file_uri);
    defer self.allocator.free(build_file_path);

    const cwd = std.fs.path.dirname(build_file_path).?;

    const args = try self.prepareBuildRunnerArgs(build_file_uri);
    defer {
        for (args) |arg| self.allocator.free(arg);
        self.allocator.free(args);
    }

    const zig_run_result = blk: {
        const tracy_zone2 = tracy.trace(@src());
        defer tracy_zone2.end();
        break :blk try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args,
            .cwd = cwd,
            .max_output_bytes = 16 * 1024 * 1024,
        });
    };
    defer self.allocator.free(zig_run_result.stdout);
    defer self.allocator.free(zig_run_result.stderr);

    const is_ok = switch (zig_run_result.term) {
        .Exited => |exit_code| exit_code == 0,
        else => false,
    };

    const diagnostic_tag: DiagnosticsCollection.Tag = tag: {
        var hasher: std.hash.Wyhash = .init(47); // Chosen by the following prompt: Pwease give a wandom nyumbew
        hasher.update(build_file_uri);
        break :tag @enumFromInt(@as(u32, @truncate(hasher.final())));
    };

    if (!is_ok) {
        const joined = try std.mem.join(self.allocator, " ", args);
        defer self.allocator.free(joined);

        log.err(
            "Failed to execute build runner to collect build configuration, command:\ncd {s};{s}\nError: {s}",
            .{ cwd, joined, zig_run_result.stderr },
        );

        var error_bundle = try @import("features/diagnostics.zig").getErrorBundleFromStderr(self.allocator, zig_run_result.stderr, false, null);
        defer error_bundle.deinit(self.allocator);

        try self.diagnostics_collection.pushErrorBundle(diagnostic_tag, build_file_version, cwd, error_bundle);
        try self.diagnostics_collection.publishDiagnostics();
        return error.RunFailed;
    } else {
        try self.diagnostics_collection.pushErrorBundle(diagnostic_tag, build_file_version, null, .empty);
        try self.diagnostics_collection.publishDiagnostics();
    }

    const parse_options: std.json.ParseOptions = .{
        // We ignore unknown fields so people can roll
        // their own build runners in libraries with
        // the only requirement being general adherence
        // to the BuildConfig type
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    const build_config = std.json.parseFromSlice(
        BuildConfig,
        self.allocator,
        zig_run_result.stdout,
        parse_options,
    ) catch return error.InvalidBuildConfig;
    errdefer build_config.deinit();

    for (build_config.value.packages) |*pkg| {
        pkg.path = try std.fs.path.resolve(build_config.arena.allocator(), &.{ build_file_path, "..", pkg.path });
    }

    return build_config;
}

/// Checks if the build.zig file is accessible in dir.
fn buildDotZigExists(dir_path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return false;
    defer dir.close();
    dir.access("build.zig", .{}) catch return false;
    return true;
}

/// Walk down the tree towards the uri. When we hit `build.zig` files
/// add them to the list of potential build files.
/// `build.zig` files higher in the filesystem have precedence.
/// See `Handle.getAssociatedBuildFileUri`.
/// Caller owns returned memory.
fn collectPotentialBuildFiles(self: *DocumentStore, uri: Uri) ![]*BuildFile {
    var potential_build_files: std.ArrayListUnmanaged(*BuildFile) = .empty;
    errdefer potential_build_files.deinit(self.allocator);

    const path = try URI.toFsPath(self.allocator, uri);
    defer self.allocator.free(path);

    var current_path: []const u8 = path;
    while (std.fs.path.dirname(current_path)) |potential_root_path| : (current_path = potential_root_path) {
        if (!buildDotZigExists(potential_root_path)) continue;

        const build_path = try std.fs.path.join(self.allocator, &.{ potential_root_path, "build.zig" });
        defer self.allocator.free(build_path);

        try potential_build_files.ensureUnusedCapacity(self.allocator, 1);

        const build_file_uri = try URI.fromPath(self.allocator, build_path);
        defer self.allocator.free(build_file_uri);

        const build_file = self.getOrLoadBuildFile(build_file_uri) orelse continue;
        potential_build_files.appendAssumeCapacity(build_file);
    }
    // The potential build files that come first should have higher priority.
    //
    // `build.zig` files that are higher up in the filesystem are more likely
    // to be the `build.zig` of the entire project/package instead of just a
    // sub-project/package.
    std.mem.reverse(*BuildFile, potential_build_files.items);

    return try potential_build_files.toOwnedSlice(self.allocator);
}

fn createBuildFile(self: *DocumentStore, uri: Uri) error{OutOfMemory}!BuildFile {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var build_file: BuildFile = .{
        .uri = try self.allocator.dupe(u8, uri),
    };

    errdefer build_file.deinit(self.allocator);

    if (loadBuildAssociatedConfiguration(self.allocator, build_file)) |cfg| {
        build_file.build_associated_config = cfg;

        if (cfg.value.relative_builtin_path) |relative_builtin_path| blk: {
            const build_file_path = URI.toFsPath(self.allocator, build_file.uri) catch break :blk;
            const absolute_builtin_path = std.fs.path.resolve(self.allocator, &.{ build_file_path, "..", relative_builtin_path }) catch break :blk;
            defer self.allocator.free(absolute_builtin_path);
            build_file.builtin_uri = try URI.fromPath(self.allocator, absolute_builtin_path);
        }
    } else |err| {
        if (err != error.FileNotFound) {
            log.debug("Failed to load config associated with build file {s} (error: {})", .{ build_file.uri, err });
        }
    }

    log.info("Loaded build file '{s}'", .{build_file.uri});

    return build_file;
}

/// Returns whether the `Uri` is a dependency of the given `BuildFile`.
/// May return `null` to indicate an inconclusive result because
/// the required build config has not been resolved yet.
///
/// invalidates any pointers into `build_files`
/// **Thread safe** takes an exclusive lock
fn uriAssociatedWithBuild(
    self: *DocumentStore,
    build_file: *BuildFile,
    uri: Uri,
) error{OutOfMemory}!?bool {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var checked_uris: std.StringHashMapUnmanaged(void) = .empty;
    defer checked_uris.deinit(self.allocator);

    var package_uris: std.ArrayListUnmanaged(Uri) = .empty;
    defer {
        for (package_uris.items) |package_uri| self.allocator.free(package_uri);
        package_uris.deinit(self.allocator);
    }
    const success = try build_file.collectBuildConfigPackageUris(self.allocator, &package_uris);
    if (!success) return null;

    for (package_uris.items) |package_uri| {
        if (try self.uriInImports(&checked_uris, build_file.uri, package_uri, uri))
            return true;
    }

    return false;
}

/// invalidates any pointers into `DocumentStore.build_files`
/// **Thread safe** takes an exclusive lock
fn uriInImports(
    self: *DocumentStore,
    checked_uris: *std.StringHashMapUnmanaged(void),
    build_file_uri: Uri,
    source_uri: Uri,
    uri: Uri,
) error{OutOfMemory}!bool {
    if (std.mem.eql(u8, uri, source_uri)) return true;
    if (isInStd(source_uri)) return false;

    const gop = try checked_uris.getOrPut(self.allocator, source_uri);
    if (gop.found_existing) return false;

    const handle = self.getOrLoadHandle(source_uri) orelse {
        errdefer std.debug.assert(checked_uris.remove(source_uri));
        gop.key_ptr.* = try self.allocator.dupe(u8, source_uri);
        return false;
    };
    gop.key_ptr.* = handle.uri;

    if (try handle.getAssociatedBuildFileUri(self)) |associated_build_file_uri| {
        return std.mem.eql(u8, associated_build_file_uri, build_file_uri);
    }

    for (handle.import_uris.items) |import_uri| {
        if (try self.uriInImports(checked_uris, build_file_uri, import_uri, uri))
            return true;
    }

    return false;
}

/// invalidates any pointers into `DocumentStore.build_files`
/// takes ownership of the `text` passed in.
/// **Thread safe** takes an exclusive lock
fn createDocument(self: *DocumentStore, uri: Uri, text: [:0]const u8, open: bool) error{OutOfMemory}!Handle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var handle: Handle = try .init(self.allocator, uri, text);
    errdefer handle.deinit();

    _ = handle.setOpen(open);

    if (!supports_build_system) {
        // nothing to do
    } else if (isBuildFile(handle.uri) and !isInStd(handle.uri)) {
        _ = self.getOrLoadBuildFile(handle.uri);
    } else if (!isBuiltinFile(handle.uri) and !isInStd(handle.uri)) blk: {
        const potential_build_files = self.collectPotentialBuildFiles(uri) catch {
            log.err("failed to collect potential build files of '{s}'", .{handle.uri});
            break :blk;
        };
        errdefer self.allocator.free(potential_build_files);

        var has_been_checked: std.DynamicBitSetUnmanaged = try .initEmpty(self.allocator, potential_build_files.len);
        errdefer has_been_checked.deinit(self.allocator);

        handle.impl.associated_build_file = .{ .unresolved = .{
            .has_been_checked = has_been_checked,
            .potential_build_files = potential_build_files,
        } };
    }

    handle.import_uris = try self.collectImportUris(&handle);
    handle.cimports = try collectCIncludes(self.allocator, handle.tree);

    return handle;
}

/// takes ownership of the `text` passed in.
/// invalidates any pointers into `DocumentStore.build_files`
/// **Thread safe** takes an exclusive lock
fn createAndStoreDocument(self: *DocumentStore, uri: Uri, text: [:0]const u8) error{OutOfMemory}!*Handle {
    const handle_ptr: *Handle = try self.allocator.create(Handle);
    errdefer self.allocator.destroy(handle_ptr);

    handle_ptr.* = try self.createDocument(uri, text, false);
    errdefer handle_ptr.deinit();

    const gop = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        break :blk try self.handles.getOrPutValue(self.allocator, handle_ptr.uri, handle_ptr);
    };

    if (gop.found_existing) {
        handle_ptr.deinit();
        self.allocator.destroy(handle_ptr);
    }

    if (isBuildFile(gop.value_ptr.*.uri)) {
        log.debug("Opened document '{s}' (build file)", .{gop.value_ptr.*.uri});
    } else {
        log.debug("Opened document '{s}'", .{gop.value_ptr.*.uri});
    }

    return gop.value_ptr.*;
}

/// Caller owns returned memory.
/// **Thread safe** takes a shared lock
fn collectImportUris(self: *DocumentStore, handle: *Handle) error{OutOfMemory}!std.ArrayListUnmanaged(Uri) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var imports = try analysis.collectImports(self.allocator, handle.tree);

    var i: usize = 0;
    errdefer {
        // only free the uris
        for (imports.items[0..i]) |uri| self.allocator.free(uri);
        imports.deinit(self.allocator);
    }

    // Convert to URIs
    while (i < imports.items.len) {
        const maybe_uri = try self.uriFromImportStr(self.allocator, handle, imports.items[i]);

        if (maybe_uri) |uri| {
            // The raw import strings are owned by the document and do not need to be freed here.
            imports.items[i] = uri;
            i += 1;
        } else {
            _ = imports.swapRemove(i);
        }
    }

    return imports;
}

pub const CImportHandle = struct {
    /// the `@cImport` node
    node: Ast.Node.Index,
    /// hash of c source file
    hash: Hash,
    /// c source file
    source: []const u8,
};

/// Collects all `@cImport` nodes and converts them into c source code if possible
/// Caller owns returned memory.
fn collectCIncludes(allocator: std.mem.Allocator, tree: Ast) error{OutOfMemory}!std.MultiArrayList(CImportHandle) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const cimport_nodes = try analysis.collectCImportNodes(allocator, tree);
    defer allocator.free(cimport_nodes);

    var sources: std.MultiArrayList(CImportHandle) = .empty;
    try sources.ensureTotalCapacity(allocator, cimport_nodes.len);
    errdefer {
        for (sources.items(.source)) |source| {
            allocator.free(source);
        }
        sources.deinit(allocator);
    }

    for (cimport_nodes) |node| {
        const c_source = translate_c.convertCInclude(allocator, tree, node) catch |err| switch (err) {
            error.Unsupported => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };

        sources.appendAssumeCapacity(.{
            .node = node,
            .hash = computeHash(c_source),
            .source = c_source,
        });
    }

    return sources;
}

/// collects every file uri the given handle depends on
/// includes imports, cimports & packages
/// **Thread safe** takes a shared lock
pub fn collectDependencies(
    store: *DocumentStore,
    allocator: std.mem.Allocator,
    handle: *Handle,
    dependencies: *std.ArrayListUnmanaged(Uri),
) error{OutOfMemory}!void {
    return store.collectDependenciesInternal(allocator, handle, dependencies, true);
}

fn collectDependenciesInternal(
    store: *DocumentStore,
    allocator: std.mem.Allocator,
    handle: *Handle,
    dependencies: *std.ArrayListUnmanaged(Uri),
    lock: bool,
) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (!supports_build_system) return;

    {
        if (lock) store.lock.lockShared();
        defer if (lock) store.lock.unlockShared();

        try dependencies.ensureUnusedCapacity(allocator, handle.import_uris.items.len + handle.cimports.len);
        for (handle.import_uris.items) |uri| {
            dependencies.appendAssumeCapacity(try allocator.dupe(u8, uri));
        }

        for (handle.cimports.items(.hash)) |hash| {
            const result = store.cimports.get(hash) orelse continue;
            switch (result) {
                .success => |uri| dependencies.appendAssumeCapacity(try allocator.dupe(u8, uri)),
                .failure => continue,
            }
        }
    }

    no_build_file: {
        const build_file_uri = if (lock)
            try handle.getAssociatedBuildFileUri(store) orelse break :no_build_file
        else
            handle.getAssociatedBuildFileUriDontResolve() orelse break :no_build_file;

        const build_file = if (lock)
            store.getBuildFile(build_file_uri) orelse break :no_build_file
        else
            store.build_files.get(build_file_uri) orelse break :no_build_file;

        _ = try build_file.collectBuildConfigPackageUris(allocator, dependencies);
    }
}

/// returns `true` if all include paths could be collected
/// may return `false` because include paths from a build.zig may not have been resolved already
/// **Thread safe** takes a shared lock
pub fn collectIncludeDirs(
    store: *DocumentStore,
    allocator: std.mem.Allocator,
    handle: *Handle,
    include_dirs: *std.ArrayListUnmanaged([]const u8),
) !bool {
    comptime std.debug.assert(supports_build_system);

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();

    const target_info: std.Target = .{
        .cpu = .{
            .arch = builtin.cpu.arch,
            .model = undefined,
            .features = undefined,
        },
        .os = builtin.target.os,
        .abi = .none,
        .ofmt = comptime std.Target.ObjectFormat.default(builtin.os.tag, builtin.cpu.arch),
        .dynamic_linker = std.Target.DynamicLinker.none,
    };
    const native_paths: std.zig.system.NativePaths = try .detect(arena_allocator.allocator(), &target_info);

    try include_dirs.ensureUnusedCapacity(allocator, native_paths.include_dirs.items.len);
    for (native_paths.include_dirs.items) |native_include_dir| {
        include_dirs.appendAssumeCapacity(try allocator.dupe(u8, native_include_dir));
    }

    const collected_all = switch (try handle.getAssociatedBuildFileUri2(store)) {
        .none => true,
        .unresolved => false,
        .resolved => |build_file| try build_file.collectBuildConfigIncludePaths(allocator, include_dirs),
    };

    return collected_all;
}

/// returns `true` if all c macro definitions could be collected
/// may return `false` because macros from a build.zig may not have been resolved already
/// **Thread safe** takes a shared lock
pub fn collectCMacros(
    store: *DocumentStore,
    allocator: std.mem.Allocator,
    handle: *Handle,
    c_macros: *std.ArrayListUnmanaged([]const u8),
) !bool {
    comptime std.debug.assert(supports_build_system);

    const collected_all = switch (try handle.getAssociatedBuildFileUri2(store)) {
        .none => true,
        .unresolved => false,
        .resolved => |build_file| blk: {
            const build_config = build_file.tryLockConfig() orelse break :blk false;
            defer build_file.unlockConfig();

            try c_macros.ensureUnusedCapacity(allocator, build_config.c_macros.len);
            for (build_config.c_macros) |c_macro| {
                c_macros.appendAssumeCapacity(try allocator.dupe(u8, c_macro));
            }
            break :blk true;
        },
    };

    return collected_all;
}

/// returns the document behind `@cImport()` where `node` is the `cImport` node
/// if a cImport can't be translated e.g. requires computing a
/// comptime value `resolveCImport` will return null
/// returned memory is owned by DocumentStore
/// **Thread safe** takes an exclusive lock
pub fn resolveCImport(self: *DocumentStore, handle: *Handle, node: Ast.Node.Index) error{OutOfMemory}!?Uri {
    comptime std.debug.assert(supports_build_system);

    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (self.config.zig_exe_path == null) return null;
    if (self.config.zig_lib_dir == null) return null;
    if (self.config.global_cache_dir == null) return null;

    // TODO regenerate cimports if the header files gets modified

    const index = std.mem.indexOfScalar(Ast.Node.Index, handle.cimports.items(.node), node) orelse return null;
    const hash: Hash = handle.cimports.items(.hash)[index];
    const source = handle.cimports.items(.source)[index];

    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.cimports.get(hash)) |result| {
            switch (result) {
                .success => |uri| return uri,
                .failure => return null,
            }
        }
    }

    var include_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (include_dirs.items) |path| {
            self.allocator.free(path);
        }
        include_dirs.deinit(self.allocator);
    }

    const collected_all_include_dirs = self.collectIncludeDirs(self.allocator, handle, &include_dirs) catch |err| {
        log.err("failed to resolve include paths: {}", .{err});
        return null;
    };

    var c_macros: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (c_macros.items) |c_macro| {
            self.allocator.free(c_macro);
        }
        c_macros.deinit(self.allocator);
    }

    const collected_all_c_macros = self.collectCMacros(self.allocator, handle, &c_macros) catch |err| {
        log.err("failed to resolve include paths: {}", .{err});
        return null;
    };

    const maybe_result = translate_c.translate(
        self.allocator,
        self.config,
        include_dirs.items,
        c_macros.items,
        source,
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => |e| {
            log.err("failed to translate cimport: {}", .{e});
            return null;
        },
    };
    var result = maybe_result orelse return null;

    if (result == .failure and (!collected_all_include_dirs or !collected_all_c_macros)) {
        result.deinit(self.allocator);
        return null;
    }

    {
        self.lock.lock();
        defer self.lock.unlock();
        const gop = self.cimports.getOrPutValue(self.allocator, hash, result) catch |err| {
            result.deinit(self.allocator);
            return err;
        };
        if (gop.found_existing) {
            result.deinit(self.allocator);
            result = gop.value_ptr.*;
        }
    }

    self.publishCimportDiagnostics(handle) catch |err| {
        log.err("failed to publish cImport diagnostics: {}", .{err});
    };

    switch (result) {
        .success => |uri| {
            log.debug("Translated cImport into {s}", .{uri});
            return uri;
        },
        .failure => return null,
    }
}

fn publishCimportDiagnostics(self: *DocumentStore, handle: *Handle) !void {
    var wip: std.zig.ErrorBundle.Wip = undefined;
    try wip.init(self.allocator);
    defer wip.deinit();

    const src_path = try wip.addString("");

    for (handle.cimports.items(.hash), handle.cimports.items(.node)) |hash, node| {
        const result = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.cimports.get(hash) orelse continue;
        };
        const error_bundle: std.zig.ErrorBundle = switch (result) {
            .success => continue,
            .failure => |bundle| bundle,
        };

        if (error_bundle.errorMessageCount() == 0) continue;

        const loc = offsets.nodeToLoc(handle.tree, node);
        const source_loc = std.zig.findLineColumn(handle.tree.source, loc.start);

        comptime std.debug.assert(max_document_size <= std.math.maxInt(u32));

        const src_loc = try wip.addSourceLocation(.{
            .src_path = src_path,
            .line = @intCast(source_loc.line),
            .column = @intCast(source_loc.column),
            .span_start = @intCast(loc.start),
            .span_main = @intCast(loc.start),
            .span_end = @intCast(loc.end),
            .source_line = try wip.addString(source_loc.source_line),
        });

        for (error_bundle.getMessages()) |err_msg_index| {
            const err_msg = error_bundle.getErrorMessage(err_msg_index);
            const msg = error_bundle.nullTerminatedString(err_msg.msg);

            try wip.addRootErrorMessage(.{
                .msg = try wip.addString(msg),
                .src_loc = src_loc,
            });
        }
    }

    {
        var error_bundle = try wip.toOwnedBundle("");
        errdefer error_bundle.deinit(self.allocator);

        try self.diagnostics_collection.pushSingleDocumentDiagnostics(
            .cimport,
            handle.uri,
            .{ .error_bundle = error_bundle },
        );
    }
    try self.diagnostics_collection.publishDiagnostics();
}

/// takes the string inside a @import() node (without the quotation marks)
/// and returns it's uri
/// caller owns the returned memory
/// **Thread safe** takes a shared lock
pub fn uriFromImportStr(self: *DocumentStore, allocator: std.mem.Allocator, handle: *Handle, import_str: []const u8) error{OutOfMemory}!?Uri {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (std.mem.eql(u8, import_str, "std")) {
        const zig_lib_dir = self.config.zig_lib_dir orelse return null;

        const std_path = try zig_lib_dir.join(allocator, &.{ "std", "std.zig" });
        defer allocator.free(std_path);

        return try URI.fromPath(allocator, std_path);
    } else if (std.mem.eql(u8, import_str, "builtin")) {
        if (supports_build_system) {
            if (try handle.getAssociatedBuildFileUri(self)) |build_file_uri| {
                const build_file = self.getBuildFile(build_file_uri).?;
                if (build_file.builtin_uri) |builtin_uri| {
                    return try allocator.dupe(u8, builtin_uri);
                }
            }
        }
        if (self.config.builtin_path) |builtin_path| {
            return try URI.fromPath(allocator, builtin_path);
        }
        return null;
    } else if (!std.mem.endsWith(u8, import_str, ".zig")) {
        if (!supports_build_system) return null;

        if (try handle.getAssociatedBuildFileUri(self)) |build_file_uri| blk: {
            const build_file = self.getBuildFile(build_file_uri).?;
            const build_config = build_file.tryLockConfig() orelse break :blk;
            defer build_file.unlockConfig();

            for (build_config.packages) |pkg| {
                if (std.mem.eql(u8, import_str, pkg.name)) {
                    return try URI.fromPath(allocator, pkg.path);
                }
            }
        } else if (isBuildFile(handle.uri)) blk: {
            const build_file = self.getBuildFile(handle.uri) orelse break :blk;
            const build_config = build_file.tryLockConfig() orelse break :blk;
            defer build_file.unlockConfig();

            for (build_config.deps_build_roots) |dep_build_root| {
                if (std.mem.eql(u8, import_str, dep_build_root.name)) {
                    return try URI.fromPath(allocator, dep_build_root.path);
                }
            }
        }
        return null;
    } else {
        const base_path = URI.toFsPath(allocator, handle.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer allocator.free(base_path);

        const joined_path = std.fs.path.resolve(allocator, &.{ base_path, "..", import_str }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer allocator.free(joined_path);

        return try URI.fromPath(allocator, joined_path);
    }
}
