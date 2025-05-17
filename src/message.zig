const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const log = std.log;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const types = @import("types.zig");
const Value = types.Value;
const Values = types.Values;
const ValueUnion = types.ValueUnion;
const TypeSignature = types.TypeSignature;

pub const Hello = Message.init(.{
    .msg_type = .method_call,
    .path = "/org/freedesktop/DBus",
    .interface = "org.freedesktop.DBus",
    .destination = "org.freedesktop.DBus",
    .member = "Hello",
    .flags = 0x04
});

pub const RequestName = Message.init(.{
    .msg_type = .method_call,
    .path = "/org/freedesktop/DBus",
    .interface = "org.freedesktop.DBus",
    .destination = "org.freedesktop.DBus",
    .member = "RequestName",
    .signature = "su",
    .flags = 0x04
});

const MsgOptions = struct {
    endian: Endian = .little,
    msg_type: MessageType,
    serial: u32 = 1,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    unix_fds: ?u32 = null,
    flags: u3 = 0x0,
};

pub const Message = struct {
    // header portion of the message
    // it's a known size and can be
    // read directly from buffer
    header: Header,

    /// object path to send the call to
    path: ?[]const u8 = null,

    /// interface to invoke the method on
    interface: ?[]const u8 = null,

    /// member (method or signal) to call
    member: ?[]const u8 = null,

    /// name of the error if one occurred
    error_name: ?[]const u8 = null,

    /// serial this message is a reply to
    reply_serial: ?u32 = null,

    /// name of the connection to send the message to
    destination: ?[]const u8 = null,

    /// unique name of the sender
    /// controlled by the bus daemon
    sender: ?[]const u8 = null,

    /// signature of the message body
    signature: ?[]const u8 = null,

    /// number of file descriptors in the message
    unix_fds: ?u32 = null,

    // allocated slice for the fields
    // portion of the message header
    fields_buf: ?[]u8 = null,

    // allocated slice for the body
    // of the message
    body_buf: ?[]u8 = null,

    // list of values in the message
    values: ?Values = null,

    // Yes??
    arena: ?ArenaAllocator = null,

    const Self = @This();

    pub fn init(opts: MsgOptions) Self {
        return .{
            .header = Header.init(opts),
            .path = opts.path,
            .interface = opts.interface,
            .member = opts.member,
            .error_name = opts.error_name,
            .reply_serial = opts.reply_serial,
            .destination = opts.destination,
            .sender = opts.sender,
            .signature = opts.signature,
            .unix_fds = opts.unix_fds,
        };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        if (self.fields_buf) |fields| alloc.free(fields);
        if (self.body_buf) |body| alloc.free(body);
        if (self.values) |*values| values.deinit(alloc);
    }

    pub fn appendString(
        self: *Self,
        alloc: Allocator,
        T: TypeSignature,
        value: []const u8
    ) !void {
        assert(@TypeOf(value) == []const u8);
        var values = self.values orelse Values.init(alloc);
        const v: Value = switch (T) {
            .string => .{ .type = T, .inner = .{ .string = .{ .inner = value } } },
            .object_path => .{ .type = T, .inner = .{ .object_path = .{ .inner = value } } },
            .signature => .{ .type = T, .inner = .{ .signature = .{ .inner = value } } },
            else => return error.InvalidStringType,
        };
        try values.append(v);
        self.values = values;
    }

    pub fn appendNumber(
        self: *Self,
        alloc: Allocator,
        value: anytype
    ) !void {
        var values = self.values orelse Values.init(alloc);

        const v: Value = switch (@TypeOf(value)) {
            u8 => .{ .type = .byte, .inner = .{ .byte = value }},
            u16 => .{ .type = .uint16, .inner = .{ .uint16 = value }},
            i16 => .{ .type = .int16, .inner = .{ .int16 = value }},
            u32 => .{ .type = .uint32, .inner = .{ .uint32 = value }},
            i32 => .{ .type = .int32, .inner = .{ .int32 = value }},
            u64 => .{ .type = .uint64, .inner = .{ .uint64 = value }},
            i64 => .{ .type = .int64, .inner = .{ .int64 = value }},
            f64 => .{ .type = .double, .inner = .{ .double = value }},
            comptime_int, comptime_float =>
                @compileError("numbers passed to appendNumber must be given an explicit fixed-size number type"),
            else =>
                @compileError("expected number type got" ++ @typeName(@TypeOf(value))),
        };

        try values.append(v);
        self.values = values;
    }

    pub fn appendBool(
        self: *Self,
        alloc: Allocator,
        value: bool
    ) !void {
        assert(@TypeOf(value) == bool);
        var values = self.values orelse Values.init(alloc);
        const v: Value = .{ .type = .boolean, .inner = .{ .boolean = value } };
        try values.append(v);
        self.values = values;
    }

    pub fn appendStruct(
        self: *Self,
        alloc: Allocator,
        @"struct": anytype,
    ) !void {
        const struct_info = @typeInfo(@TypeOf(@"struct"));
        assert(struct_info == .@"struct");
        var values = self.values orelse Values.init(alloc);
        try values.appendStruct(alloc, @"struct");
        self.values = values;
    }

    pub fn appendValuesFromSlice(self: *Self, alloc: Allocator, slice: []const Value) !void {
        var values = self.values orelse Values.init(alloc);
        try values.appendSliceOfValues(slice);
        self.values = values;
    }

    fn writeFieldString(code: FieldCode, type_: TypeSignature, bytes: []const u8, index: usize, writer: anytype) !void {
        try writer.writeByteNTimes(0x00, type_.alignOffset(index));

        try writer.writeInt(u8, @intFromEnum(code), .little);

        try writer.writeByte(0x01);
        try writer.writeInt(u8, @intFromEnum(type_), .little);
        try writer.writeByte(0x00);

        try writer.writeInt(u32, @as(u32, @intCast(bytes.len)), .little);
        _ = try writer.write(bytes);
        try writer.writeByte(0x00);
    }

    fn writeFieldSignature(bytes: []const u8, writer: anytype) !void {
        try writer.writeInt(u8, @intFromEnum(FieldCode.signature), .little);

        try writer.writeByte(0x01);
        try writer.writeInt(u8, @intFromEnum(TypeSignature.signature), .little);
        try writer.writeByte(0x00);

        try writer.writeByte(@as(u8, @intCast(bytes.len)));
        _ = try writer.write(bytes);
        try writer.writeByte(0x00);
    }

    fn writeFieldIntU32(code: FieldCode, value: u32, index: usize, writer: anytype) !void {
        try writer.writeByteNTimes(0x00, TypeSignature.uint32.alignOffset(index));
        try writer.writeInt(u8, @intFromEnum(code), .little);

        try writer.writeByte(0x01);
        try writer.writeInt(u8, @intFromEnum(TypeSignature.uint32), .little);
        try writer.writeByte(0x00);

        try writer.writeInt(u32, value, .little);
    }

    pub fn encode(self: *@This(), alloc: Allocator, writer: anytype) !void {
        self.fields_buf = blk: {
            var buf = ArrayList(u8).init(alloc);
            const buf_writer = buf.writer();
            errdefer buf.deinit();

            var size: usize = 0;
            if (self.path) |path| {
                try writeFieldString(.path, .object_path, path, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.member) |member| {
                try writeFieldString(.member, .string, member, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.interface) |iface| {
                try writeFieldString(.interface, .string, iface, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.error_name) |error_name| {
                var err_buf: [256]u8 = undefined;
                // TODO: get interface from dbus
                const err = try std.fmt.bufPrint(&err_buf, "com.anunknownalias.Error.{s}", .{error_name});
                try writeFieldString(.error_name, .string, err, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.destination) |dest| {
                try writeFieldString(.destination, .string, dest, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.reply_serial) |serial| {
                try writeFieldIntU32(.reply_serial, serial, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.signature) |signature| {
                try writeFieldSignature(signature, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.sender) |sender| {
                try writeFieldString(.sender, .string, sender, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.unix_fds) |fds| {
                try writeFieldIntU32(.unix_fds, fds, buf.items.len, buf_writer);
                size = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            // I would think we could use the buf.items.len for this
            // but it fails tests with incorrect size for fields
            // and I'm to lazy to figure out why right now
            self.header.fields_len = @as(u32, @intCast(size));

            const pad = TypeSignature.@"struct".alignOffset(buf.items.len);
            try buf_writer.writeByteNTimes(0x00, pad);

            break :blk try buf.toOwnedSlice();
        };

        if (self.values) |values| {
            var buf = ArrayList(u8).init(alloc);
            const buf_writer = buf.writer();
            errdefer buf.deinit();

            const T: TypeSignature = @enumFromInt(self.signature.?[0]);
            const pad = T.alignOffset(@sizeOf(Header) + self.fields_buf.?.len);
            try buf_writer.writeByteNTimes(0x00, pad);

            for (values.values.items) |value| {
                try buf_writer.writeByteNTimes(0x00, value.type.alignOffset(buf.items.len));
                switch (value.type) {
                    .byte => try buf_writer.writeByte(value.inner.byte),
                    .boolean => try buf_writer.writeInt(u32, @as(u32, @intFromBool(value.inner.boolean)), .little),
                    .int16 => try buf_writer.writeInt(i16, value.inner.int16, .little),
                    .uint16 => try buf_writer.writeInt(u16, value.inner.uint16, .little),
                    .int32 => try buf_writer.writeInt(i32, value.inner.int32, .little),
                    .uint32 => try buf_writer.writeInt(u32, value.inner.uint32, .little),
                    .int64 => try buf_writer.writeInt(i64, value.inner.int64, .little),
                    .uint64 => try buf_writer.writeInt(u64, value.inner.uint64, .little),
                    .double => try buf_writer.writeInt(u64, @as(u64, @bitCast(value.inner.double)), .little),
                    .string => {
                        try buf_writer.writeInt(u32, @as(u32, @intCast(value.inner.string.inner.len)), .little);
                        try buf_writer.writeAll(value.inner.string.inner);
                        try buf_writer.writeByte(0x00);
                    },
                    .object_path => {
                        try buf_writer.writeInt(u32, @as(u32, @intCast(value.inner.object_path.inner.len)), .little);
                        try buf_writer.writeAll(value.inner.object_path.inner);
                        try buf_writer.writeByte(0x00);
                    },
                    .@"struct" => {
                        assert(value.slice != null);
                        log.debug("writing struct: {d}\n", .{value.slice.?});
                        try buf_writer.writeAll(value.slice.?);
                    },
                    // TODO:
                    // .signature, array, .dict_entry, .variant, .unix_fd
                    else => unreachable,
                }
            }

            self.body_buf = try buf.toOwnedSlice();
            self.header.body_len = @as(u32, @intCast(self.body_buf.?.len));

        }

        const header = mem.asBytes(&self.header);
        try writer.writeAll(header);
        try writer.writeAll(self.fields_buf.?);
        if (self.body_buf) |body| try writer.writeAll(body);

    }

    fn readString(type_: TypeSignature, field: *?[]const u8, iter: *BytesIterator) !void {
        const v = iter.next(.variant, null) orelse return error.EOF;
        const t: TypeSignature = @enumFromInt(v[0]);
        if (t != type_) {
            log.debug("invalid type: {any}\n", .{t});
            return error.InvalidField;
        }

        const slice = iter.next(type_, null) orelse return error.EOF;
        field.* = slice;
    }

    fn readIntU32(field: *?u32, iter: *BytesIterator) !void {
        const v = iter.next(.variant, null) orelse return error.EOF;
        if (@as(TypeSignature, @enumFromInt(v[0])) != .uint32)
            return error.InvalidField;

        const slice = iter.next(.uint32, null) orelse return error.EOF;
        field.* = mem.readInt(u32, slice[0..4], .little);
    }

    fn parseFields(self: *Self) !void {
        var bytes_iter: BytesIterator = .{ .buffer = self.fields_buf.? };

        while (bytes_iter.next(.byte, null)) |t| {
            const field_code: FieldCode = @enumFromInt(t[0]);
            try switch (field_code) {
                .path => readString(.object_path, &self.path, &bytes_iter),
                .signature => readString(.signature, &self.signature, &bytes_iter),

                inline .interface, .member, .error_name, .destination, .sender
                    => |v| readString(.string, &@field(self, @tagName(v)), &bytes_iter),

                inline .reply_serial, .unix_fds
                    => |v| readIntU32(&@field(self, @tagName(v)), &bytes_iter),

                else => return error.InvalidField,
            };
        // TODO: hacky, read fields as actual structs
        bytes_iter.index += TypeSignature.@"struct".alignOffset(bytes_iter.index);
        }
    }

    test "container signatures" {
        const cases = [_]struct {
            t: TypeSignature,
            sig: []const u8,
            expected: []const u8
        }{
            .{ .t = .array, .sig = "yaai", .expected = "y" },
            .{ .t = .array, .sig = "ayuu", .expected = "ay" },
            .{ .t = .array, .sig = "{ay}yy", .expected = "{ay}" },
            .{ .t = .array, .sig = "{a{ay}}aay", .expected = "{a{ay}}" },
            .{ .t = .array, .sig = "{a{a{ay}}}uu", .expected = "{a{a{ay}}}" },
            .{ .t = .array, .sig = "{a{a{a{ay}}}}xx", .expected = "{a{a{a{ay}}}}" },
            .{ .t = .@"struct", .sig = "sas)", .expected = "sas" },
            .{ .t = .dict_entry, .sig = "sa}", .expected = "sa" },
        };
        for (cases) |c| {
            var iter = SignatureIterator{ .buffer = c.sig };
            const contained_sig = try readContainerSignature(c.t, &iter);
            try std.testing.expectEqualSlices(u8, c.expected, contained_sig.?);
        }
    }

    fn readContainerSignature(
        T: TypeSignature,
        iter: *SignatureIterator,
    ) !?[]const u8 {
        const start = iter.index;
        var i: usize = 1;
        var stack: [64]u8 = undefined;
        switch (T) {
            .@"struct" => stack[0] = ')',
            .dict_entry => stack[0] = '}',
            .array => i -= 1,
            else => return null,
        }

        while (iter.next()) |c| {
            const s = if (i > 0) stack[i-1] else 0;
            switch (c) {
                'a' => continue,
                ')', '}' => |b| {
                    if (s == b) i -= 1 else return error.InvalidSignature;
                    if (i == 0 and (T == .@"struct" or T == .dict_entry)) {
                        const end = iter.index-1;
                        return iter.buffer[start..end];
                    }
                },
                '(' => {
                    if (i >= stack.len) return error.SignatureMaxDepth;
                    stack[i] = ')';
                    i += 1;
                },
                '{' => {
                    if (i >= stack.len) return error.SignatureMaxDepth;
                    stack[i] = '}';
                    i += 1;
                },
                else => {}
            }
            if (i == 0) { const end = iter.index; return iter.buffer[start..end]; }
        } else return error.InvalidSignature;
    }

    fn parseBytes(
        alloc: Allocator,
        signature: []const u8,
        bytes_iter: *BytesIterator,
        values: *Values,
    ) !usize {
        const start = bytes_iter.index;
        var sig_iter: SignatureIterator = .{ .buffer = signature };

        while (sig_iter.next()) |t| {
            const T: TypeSignature = @enumFromInt(t);
            const contained_sig = try readContainerSignature(T, &sig_iter);
            const conained_type: ?TypeSignature =
                if (contained_sig) |sig| @enumFromInt(sig[0]) else null;
            const b = bytes_iter.next(T, conained_type) orelse return error.InvalidBodySignature;

            const value: ValueUnion = switch (T) {
                .byte => .{ .byte = b[0] },
                .boolean => .{ .boolean = mem.readInt(u32, b[0..4], .little) == 1 },
                .int16 => .{ .int16 = mem.readInt(i16, b[0..2], .little) },
                .uint16 => .{ .uint16 = mem.readInt(u16, b[0..2], .little) },
                .int32 => .{ .int32 = mem.readInt(i32, b[0..4], .little) },
                .uint32 => .{ .uint32 = mem.readInt(u32, b[0..4], .little) },
                .int64 => .{ .int64 = mem.readInt(i64, b[0..8], .little) },
                .uint64 => .{ .uint64 = mem.readInt(u64, b[0..8], .little) },
                .double => .{ .double = @as(f64, @bitCast(mem.readInt(u64, b[0..8], .little))) },
                .string => .{ .string = .{ .inner = b } },
                .object_path => .{ .object_path = .{ .inner = b } },
                .array => blk: {
                    var values_ = Values.init(alloc);
                    var iter = BytesIterator{ .buffer = b };
                    var n_: usize = 0;
                    var i: usize = 0;
                    while (n_ < b.len) {
                        n_ += try parseBytes(alloc, contained_sig.?, &iter, &values_);
                        i += 1;
                    }
                    break :blk .{ .array = values_ };
                },
                .@"struct" => blk: {
                    var values_ = Values.init(alloc);
                    _ = try parseBytes(alloc, contained_sig.?, bytes_iter, &values_);
                    break :blk .{ .@"struct" = values_ };
                },
                .dict_entry => blk: {
                    var values_ = Values.init(alloc);
                    _ = try parseBytes(alloc, contained_sig.?, bytes_iter, &values_);
                    assert(values_.len() == 2);
                    break :blk .{ .dict_entry = values_ };
                },
                // TODO
                // .variant => unreachable,
                // .signature => unreachable,
                else => return error.InvalidType,
            };
            try values.append(.{ .type = T, .contained_sig = contained_sig, .slice = b, .inner = value });
        }
        return bytes_iter.index - start;
    }

    fn parseBody( self: *Self, alloc: Allocator) !void {
        self.values = Values.init(alloc);
        var bytes_iter: BytesIterator = .{ .buffer = self.body_buf.? };
        _ = try parseBytes(alloc, self.signature.?, &bytes_iter, &self.values.?);
    }

    pub fn decode(alloc: Allocator, reader: anytype) !Self {
        const header = try reader.readStruct(Header);
        var message: Self = .{ .header = header };

        message.fields_buf = try alloc.alloc(u8, message.header.fields_len);
        errdefer alloc.free(message.fields_buf.?);

        var n = try reader.readAll(message.fields_buf.?);
        if (n != message.header.fields_len) return error.InvalidFields;
        try message.parseFields();

        if (message.header.body_len == 0
            and message.signature == null
        ) return message;

        if (message.header.body_len == 0
            and message.signature != null
        ) return error.InvalidBody;

        if (message.header.body_len > 0
            and message.signature == null
        ) return error.InvalidSignature;

        // align to the start of the body
        // and confirm padding bytes are zero
        const sig: TypeSignature = .@"struct";
        const pad = sig.alignOffset(@sizeOf(Header) + message.header.fields_len);
        for (0..pad) |_| assert(try reader.readByte() == 0x00);

        message.body_buf = try alloc.alloc(u8, message.header.body_len);
        errdefer alloc.free(message.body_buf.?);
        n = try reader.readAll(message.body_buf.?);
        if (n != message.header.body_len) return error.InvalidBody;
        try message.parseBody(alloc);

        return message;
    }
};

const Endian = enum(u8) {
    little = 'l',
    big = 'B',
};

const MessageType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
};

const Header = packed struct {
    endian: u8,
    msg_type: MessageType,
    flags: u8,
    protocol_version: u8,
    body_len: u32,
    serial: u32,
    fields_len: u32,

    pub fn init(opts: MsgOptions) @This() {
        return .{
            .endian = @intFromEnum(opts.endian),
            .msg_type = opts.msg_type,
            .flags = opts.flags,
            .protocol_version = 1,
            .serial = opts.serial,
            .body_len = 0,
            .fields_len = 0,
        };
    }
};

const Flags = enum(u3) {
    no_reply_expected = 0x1,
    no_auto_start = 0x2,
    allow_interactive_authorization = 0x4,
};

const FieldCode = enum(u8) {
    invalid = 0,
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

const BytesIterator = struct {
    buffer: []const u8,
    index: usize = 0,
    const Self = @This();

    fn pos(self: *Self) usize {
        return self.index;
    }

    fn next(self: *Self, T: TypeSignature, t: ?TypeSignature) ?[]const u8 {
        const result, const n = self.peek(T, t) orelse return null;
        self.index += n;
        return result;
    }

    fn peek(self: *Self, T: TypeSignature, t: ?TypeSignature) ?struct{ []const u8, usize } {
        const offset = T.alignOffset(self.index);
        var alignment = self.index + offset;
        if (alignment >= self.buffer.len) return null;

        return switch (T) {
            .byte => .{
                self.buffer[alignment..][0..@sizeOf(u8)],
                offset + @sizeOf(u8)
            },
            .boolean => .{
                self.buffer[alignment..][0..@sizeOf(u32)],
                offset + @sizeOf(u32)
            },
            .int16 => .{
                self.buffer[alignment..][0..@sizeOf(i16)],
                offset + @sizeOf(i16)
            },
            .uint16 => .{
                self.buffer[alignment..][0..@sizeOf(u16)],
                offset + @sizeOf(u16)
            },
            .int32 => .{
                self.buffer[alignment..][0..@sizeOf(i32)],
                offset + @sizeOf(i32)
            },
            .uint32 => .{
                self.buffer[alignment..][0..@sizeOf(u32)],
                offset + @sizeOf(u32)
            },
            .int64 => .{
                self.buffer[alignment..][0..@sizeOf(i64)],
                offset + @sizeOf(i64)
            },
            .uint64 => .{
                self.buffer[alignment..][0..@sizeOf(u64)],
                offset + @sizeOf(u64)
            },
            .double => .{
                self.buffer[alignment..][0..@sizeOf(f64)],
                offset + @sizeOf(f64)
            },
            .signature => blk: {
                const slice = self.buffer[alignment..][0..@sizeOf(u8)];
                const len = mem.readInt(u8, slice, .little);
                const ret = self.buffer[alignment+@sizeOf(u8)..][0..len];
                const n = offset + len + @sizeOf(u8) + 1; // 1 for null byte
                break :blk .{ ret, n };
            },
            .variant => blk: {
                const slice = self.buffer[alignment..][0..@sizeOf(u8)];
                const len = mem.readInt(u8, slice, .little);
                const ret = self.buffer[alignment+@sizeOf(u8)..][0..len];
                const n = offset + len + @sizeOf(u8) + 1; // 1 for null byte
                break :blk .{ ret, n }; // 1 for null byte
            },
            .object_path, .string => blk: {
                const slice = self.buffer[alignment..][0..@sizeOf(u32)];
                const len = mem.readInt(u32, slice, .little);
                const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
                const n = offset + len + @sizeOf(u32) + 1;
                break :blk .{ ret, n }; // 1 for null byte
            },
            .array => blk: {
                const slice = self.buffer[alignment..][0..@sizeOf(u32)];
                const len = mem.readInt(u32, slice, .little);
                const offset_ = t.?.alignOffset(alignment + @sizeOf(u32));
                alignment += offset_;
                const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
                const n = offset + offset_ + len + @sizeOf(u32) + 1;
                break :blk .{ ret, n };
            },
            .@"struct", .dict_entry  => .{ self.buffer[alignment..], offset },
            else =>  null,
        };
    }
};

const SignatureIterator = struct {
    buffer: []const u8,
    index: usize = 0,

    const Self = @This();

    fn next(self: *Self) ?u8 {
        const result = self.peek() orelse return null;
        self.index += 1;
        return result;
    }

    fn peek(self: *Self) ?u8 {
        if (self.index >= self.buffer.len) return null;
        return self.buffer[self.index];
    }

    fn rest(self: *Self) []const u8 {
        return self.buffer[self.index..];
    }

    fn advance(self: *Self, n: usize) void {
        self.index += n;
    }
};

test "encode method call" {
    const String = @import("types.zig").String;
    const cases = [_]struct {
        opts: MsgOptions,
        values: ?[]const Value = null,
        expected: []const u8,
    }{
        .{
            .opts = .{
                .msg_type = .method_call,
                .path = "/org/freedesktop/DBus",
                .interface = "org.freedesktop.DBus",
                .destination = "org.freedesktop.DBus",
                .sender = "test",
                .member = "Hello",
                .flags = 0x04
            },
            .expected = &[_]u8{
                0x6c, 0x01, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
                0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
                0x03, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00,
                0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00,
            }
        },
        .{
            .opts = .{
                .msg_type = .method_call,
                .serial = 2,
                .path = "/org/freedesktop/DBus",
                .member = "RequestName",
                .interface = "org.freedesktop.DBus",
                .destination = "org.freedesktop.DBus",
                .signature = "su",
                .sender = ":1.2054",
                .flags = 0x04
            },
            .values = &[_]Value{
                .{
                    .type = .string,
                    .contained_sig = null,
                    .slice = &[_]u8{
                        0x10, 0x00, 0x00, 0x00, 0x63, 0x6f, 0x6d, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x2e, 0x54, 0x65, 0x73,
                        0x74, 0x42, 0x75, 0x73, 0x00
                    },
                    .inner = .{
                        .string = String{
                            .inner = &[_]u8{
                                0x63, 0x6f, 0x6d, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x2e, 0x54, 0x65, 0x73, 0x74, 0x42, 0x75, 0x73
                            }
                        }
                    }
                },
                .{
                    .type = .uint32,
                    .contained_sig = null,
                    .slice = &[_]u8{0x00, 0x00, 0x00, 0x00},
                    .inner = .{ .uint32 = 0x00 }
                },
            },
            .expected = &[_]u8{
                0x6c, 0x01, 0x04, 0x01, 0x1c, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
                0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
                0x03, 0x01, 0x73, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x52, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x4e,
                0x61, 0x6d, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00,
                0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
                0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00, 0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00,
                0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
                0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x02, 0x73, 0x75, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x32, 0x30, 0x35, 0x34, 0x00,
                0x10, 0x00, 0x00, 0x00, 0x63, 0x6f, 0x6d, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x2e, 0x54, 0x65, 0x73,
                0x74, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            }
        },
    };

    const alloc = std.testing.allocator;
    for (cases) |case| {
        var msg = Message.init(case.opts);
        defer msg.deinit(alloc);
        if (case.values) |values| {
            try msg.appendValuesFromSlice(alloc, values);
        }

        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        try msg.encode(alloc, writer);
        const got = fbs.getWritten();
        try std.testing.expectEqualSlices(u8, case.expected, got);
    }
}

test "encode method return" {
    const String = @import("types.zig").String;
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        opts: MsgOptions,
        values: ?[]const Value,
        expected: []const u8,
    }{
        .{
            .opts = .{
                .msg_type = .method_return,
                .destination = ":1.1993",
                .reply_serial = 2,
                .signature = "s",
                .sender = "org.freedesktop.DBus",
                .flags = 0x01,
            },
            .values = &[_]Value{
                .{
                    .type = .string,
                    .contained_sig = null,
                    .slice = &[_]u8{0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00},
                    .inner = .{ .string = String{ .inner = &[_]u8{0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33} } }
                }
            },
            .expected = &[_]u8{
                0x6c, 0x02, 0x01, 0x01, 0x0c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
                0x06, 0x01, 0x73, 0x00, 0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00,
                0x05, 0x01, 0x75, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00
            }
        },
    };

    for (cases) |case| {
        var msg = Message.init(case.opts);
        defer msg.deinit(alloc);
        if (case.values) |values| {
            try msg.appendValuesFromSlice(alloc, values);
        }

        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        try msg.encode(alloc, writer);
        const got = fbs.getWritten();
        try std.testing.expectEqualSlices(u8, case.expected, got);
    }
}

test "decode" {
    const cases = [_]struct {
        name: []const u8,
        msg_type: MessageType,
        path: ?[]const u8 = null,
        interface: ?[]const u8 = null,
        member: ?[]const u8 = null,
        destination: ?[]const u8 = null,
        reply_serial: ?u32 = null,
        signature: ?[]const u8 = null,
        sender: ?[]const u8 = null,
        body: ?[]const u8 = null,
        bytes: []const u8,
    }{
        .{
            .name = "hello",
            .msg_type = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
            .bytes = &[_]u8{
                0x6c, 0x01, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
                0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
                0x03, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00,
                0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x38, 0x36, 0x00,
            }
        },
        .{
            .name = "hello_resp",
            .msg_type = .method_return,
            .destination = ":1.1993",
            .reply_serial = 2,
            .signature = "s",
            .sender = "org.freedesktop.DBus",
            .body = &[_]u8{
                0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00
            },
            .bytes = &[_]u8{
                0x6c, 0x02, 0x01, 0x01, 0x0c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
                0x06, 0x01, 0x73, 0x00, 0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00,
                0x05, 0x01, 0x75, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00
            }
        },
        .{
            .name = "NameOwnerChanged",
            .msg_type = .signal,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameOwnerChanged",
            .signature = "sss",
            .sender = "org.freedesktop.DBus",
            .body = &[_]u8{
                0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00,
            },
            .bytes = &[_]u8{
                0x6c, 0x04, 0x01, 0x01, 0x20, 0x00, 0x00, 0x00, 0x55, 0x0f, 0x00, 0x00, 0x89, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
                0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
                0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x03, 0x01, 0x73, 0x00, 0x10, 0x00, 0x00, 0x00, 0x4e, 0x61, 0x6d, 0x65, 0x4f, 0x77, 0x6e, 0x65,
                0x72, 0x43, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                0x08, 0x01, 0x67, 0x00, 0x03, 0x73, 0x73, 0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33, 0x00,
            }
        },
        .{
            .name = "RequestName",
            .msg_type = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "RequestName",
            .signature = "su",
            .sender = ":",
            .body = &[_]u8{
                0x17, 0x00, 0x00, 0x00, 0x6e, 0x65, 0x74, 0x2e, 0x61, 0x6e, 0x75, 0x6e, 0x6b, 0x6e, 0x6f, 0x77,
                0x6e, 0x61, 0x6c, 0x69, 0x61, 0x73, 0x2e, 0x44, 0x42, 0x75, 0x7a, 0x00, 0x01, 0x00, 0x00, 0x00
            },
            .bytes = &[_]u8{
                0x6c, 0x01, 0x04, 0x01, 0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x8a, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
                0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
                0x03, 0x01, 0x73, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x52, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x4e,
                0x61, 0x6d, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00,
                0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
                0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00, 0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00,
                0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
                0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x02, 0x73, 0x75, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x17, 0x00, 0x00, 0x00, 0x6e, 0x65, 0x74, 0x2e, 0x61, 0x6e, 0x75, 0x6e, 0x6b, 0x6e, 0x6f, 0x77,
                0x6e, 0x61, 0x6c, 0x69, 0x61, 0x73, 0x2e, 0x44, 0x42, 0x75, 0x7a, 0x00, 0x01, 0x00, 0x00, 0x00
            }
        },
        .{
            .name = "Notify",
            .msg_type = .method_call,
            .path = "/net/anunknownalias/Dbuz",
            .interface = "net.anunknownalias.Dbuz",
            .member = "Notify",
            .signature = "a(sas)sa{ss}",
            .body = &[_]u8{
                0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x79, 0x61, 0x79, 0x61,
                0x00, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74,
                0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x32, 0x00, 0x00, 0x00,
                0x05, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00, 0x6e, 0x61, 0x6e, 0x61, 0x00, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00, 0x74, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
                0x74, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x63, 0x68, 0x61, 0x63,
                0x68, 0x61, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x72, 0x61, 0x72, 0x61,
                0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x77, 0x6f, 0x77, 0x6f, 0x77, 0x00, 0x00, 0x00,
                0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x77, 0x65, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00, 0x77, 0x68, 0x6f, 0x6f, 0x00,
            },
            .bytes = &[_]u8{
                0x6c, 0x01, 0x04, 0x01, 0xa9, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x9f, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x18, 0x00, 0x00, 0x00, 0x2f, 0x6e, 0x65, 0x74, 0x2f, 0x61, 0x6e, 0x75,
                0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x61, 0x6c, 0x69, 0x61, 0x73, 0x2f, 0x44, 0x62, 0x75, 0x7a,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x73, 0x00, 0x06, 0x00, 0x00, 0x00,
                0x4e, 0x6f, 0x74, 0x69, 0x66, 0x79, 0x00, 0x00, 0x02, 0x01, 0x73, 0x00, 0x17, 0x00, 0x00, 0x00,
                0x6e, 0x65, 0x74, 0x2e, 0x61, 0x6e, 0x75, 0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x61, 0x6c, 0x69,
                0x61, 0x73, 0x2e, 0x44, 0x62, 0x75, 0x7a, 0x00, 0x06, 0x01, 0x73, 0x00, 0x17, 0x00, 0x00, 0x00,
                0x6e, 0x65, 0x74, 0x2e, 0x61, 0x6e, 0x75, 0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x61, 0x6c, 0x69,
                0x61, 0x73, 0x2e, 0x44, 0x62, 0x75, 0x7a, 0x00, 0x08, 0x01, 0x67, 0x00, 0x0c, 0x61, 0x28, 0x73,
                0x61, 0x73, 0x29, 0x73, 0x61, 0x7b, 0x73, 0x73, 0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x06, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x36, 0x35, 0x38, 0x00, 0x00,
                0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x79, 0x61, 0x79, 0x61,
                0x00, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74,
                0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x32, 0x00, 0x00, 0x00,
                0x05, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00, 0x6e, 0x61, 0x6e, 0x61, 0x00, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00, 0x74, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
                0x74, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x63, 0x68, 0x61, 0x63,
                0x68, 0x61, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x72, 0x61, 0x72, 0x61,
                0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x77, 0x6f, 0x77, 0x6f, 0x77, 0x00, 0x00, 0x00,
                0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x77, 0x65, 0x00, 0x00,
                0x04, 0x00, 0x00, 0x00, 0x77, 0x68, 0x6f, 0x6f, 0x00,
            }
        },
    };
    const alloc = std.testing.allocator;
    for (cases) |case| {
        var fbs = std.io.fixedBufferStream(case.bytes);
        const reader = fbs.reader();
        var msg = try Message.decode(alloc, reader);
        defer msg.deinit(alloc);

        try std.testing.expectEqual(msg.header.msg_type, case.msg_type);
        if (case.path) |path| try std.testing.expectEqualStrings(path, msg.path.?);
        if (case.interface) |iface| try std.testing.expectEqualStrings(iface, msg.interface.?);
        if (case.member) |member| try std.testing.expectEqualStrings(member, msg.member.?);
        if (case.destination) |dest| try std.testing.expectEqualStrings(dest, msg.destination.?);
        if (case.reply_serial) |serial| try std.testing.expectEqual(serial, msg.reply_serial);
        if (case.signature) |sig| try std.testing.expectEqualStrings(sig, msg.signature.?);
        if (case.sender) |sender| try std.testing.expectEqualStrings(sender, msg.sender.?);
        if (case.body) |body| try std.testing.expectEqualSlices(u8, body, msg.body_buf.?);
    }
}

test "array" {
    const String = @import("types.zig").String;
    const cases = [_]struct {
        name: []const u8,
        msg_type: MessageType,
        path: ?[]const u8 = null,
        interface: ?[]const u8 = null,
        member: ?[]const u8 = null,
        destination: ?[]const u8 = null,
        reply_serial: ?u32 = null,
        signature: ?[]const u8 = null,
        sender: ?[]const u8 = null,
        values: ?[]const Value = null,
        body: ?[]const u8 = null,
        bytes: []const u8,
    }{
        .{
            .name = "Notify",
            .msg_type = .method_call,
            .path = "/net/anunknownalias/Dbuz",
            .destination = "net.anunknownalias.Dbuz",
            .interface = "net.anunknownalias.Dbuz",
            .member = "Notify",
            .signature = "as",
            .sender = ":1.51",
            .values = &[_]Value{
                .{
                    .type = .string,
                    .contained_sig = "s",
                    .slice = &[_]u8{0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00},
                    .inner = .{ .string = String{ .inner = &[_]u8{0x74, 0x65, 0x73, 0x74} } }
                },
                .{
                    .type = .string,
                    .contained_sig = "s",
                    .slice = &[_]u8{0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x32, 0x00},
                    .inner = .{ .string = String{ .inner = &[_]u8{0x74, 0x65, 0x73, 0x74, 0x32} } }
                },
                .{
                    .type = .string,
                    .contained_sig = "s",
                    .slice = &[_]u8{0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x33, 0x00},
                    .inner = .{ .string = String{ .inner = &[_]u8{0x74, 0x65, 0x73, 0x74, 0x33} } }
                }
            },
            .body = &[_]u8{
                0x22, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00,
                0x05, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x32, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
                0x74, 0x65, 0x73, 0x74, 0x33, 0x00

            },
            .bytes = &[_]u8{
                0x6c, 0x01, 0x04, 0x01, 0x26, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x8e, 0x00, 0x00, 0x00,
                0x01, 0x01, 0x6f, 0x00, 0x18, 0x00, 0x00, 0x00, 0x2f, 0x6e, 0x65, 0x74, 0x2f, 0x61, 0x6e, 0x75,
                0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x61, 0x6c, 0x69, 0x61, 0x73, 0x2f, 0x44, 0x62, 0x75, 0x7a,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x73, 0x00, 0x06, 0x00, 0x00, 0x00,
                0x4e, 0x6f, 0x74, 0x69, 0x66, 0x79, 0x00, 0x00, 0x02, 0x01, 0x73, 0x00, 0x17, 0x00, 0x00, 0x00,
                0x6e, 0x65, 0x74, 0x2e, 0x61, 0x6e, 0x75, 0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x61, 0x6c, 0x69,
                0x61, 0x73, 0x2e, 0x44, 0x62, 0x75, 0x7a, 0x00, 0x06, 0x01, 0x73, 0x00, 0x17, 0x00, 0x00, 0x00,
                0x6e, 0x65, 0x74, 0x2e, 0x61, 0x6e, 0x75, 0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x61, 0x6c, 0x69,
                0x61, 0x73, 0x2e, 0x44, 0x62, 0x75, 0x7a, 0x00, 0x08, 0x01, 0x67, 0x00, 0x02, 0x61, 0x73, 0x00,
                0x07, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x35, 0x31, 0x00, 0x00, 0x00,
                0x22, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00,
                0x05, 0x00, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x32, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
                0x74, 0x65, 0x73, 0x74, 0x33, 0x00
            }
        },
    };
    const alloc = std.testing.allocator;
    for (cases) |case| {
        var fbs = std.io.fixedBufferStream(case.bytes);
        const reader = fbs.reader();
        var msg = try Message.decode(alloc, reader);
        defer msg.deinit(alloc);

        try std.testing.expectEqual(msg.header.msg_type, case.msg_type);
        if (case.path) |path| try std.testing.expectEqualStrings(path, msg.path.?);
        if (case.interface) |iface| try std.testing.expectEqualStrings(iface, msg.interface.?);
        if (case.member) |member| try std.testing.expectEqualStrings(member, msg.member.?);
        if (case.destination) |dest| try std.testing.expectEqualStrings(dest, msg.destination.?);
        if (case.reply_serial) |serial| try std.testing.expectEqual(serial, msg.reply_serial);
        if (case.signature) |sig| try std.testing.expectEqualStrings(sig, msg.signature.?);
        if (case.sender) |sender| try std.testing.expectEqualStrings(sender, msg.sender.?);
        if (case.body) |body| try std.testing.expectEqualSlices(u8, body, msg.body_buf.?);
        const arr = msg.values.?.values.items[0].inner.array;
        try std.testing.expectEqual(case.values.?[0..].len, arr.values.items.len);
        for (arr.values.items, 0..) |value, i| {
            const expect = case.values.?[i];
            try std.testing.expect(value.type == expect.type);
            try std.testing.expectEqualSlices(u8, value.inner.string.inner, expect.inner.string.inner);
        }
    }
}

