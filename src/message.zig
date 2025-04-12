const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

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

    /// name of the error is one occurred
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
        var values = self.values orelse Values.init(alloc);
        const v: Value = switch (T) {
            .string => .{ .type = T, .inner = .{ .string = value }},
            .object_path => .{ .type = T, .inner = .{ .object_path = value }},
            .signature => .{ .type = T, .inner = .{ .signature = value }},
            else => return error.InvalidStringType,
        };
        try values.append(v);
        self.values = values;
    }

    pub fn appendInt(
        self: *Self,
        alloc: Allocator,
        T: TypeSignature,
        value: anytype
    ) !void {
        var values = self.values orelse Values.init(alloc);

        const v: Value = switch (T) {
            .byte => .{ .type = T, .inner = .{ .byte = value }},
            .uint16 => .{ .type = T, .inner = .{ .uint16 = value }},
            .int16 => .{ .type = T, .inner = .{ .int16 = value }},
            .uint32 => .{ .type = T, .inner = .{ .uint32 = value }},
            .int32 => .{ .type = T, .inner = .{ .int32 = value }},
            .int64 => .{ .type = T, .inner = .{ .int64 = value }},
            .uint64 => .{ .type = T, .inner = .{ .uint64 = value }},
            .double => .{ .type = T, .inner = .{ .double = value }},
            else => {
                std.log.debug("invalid type: {any}", .{@TypeOf(value)});
                return error.InvalidIntType;
            }
        };
        try values.append(v);
        self.values = values;
    }

    pub fn appendValuesFromSlice(self: *Self, alloc: Allocator, slice: []const Value) !void {
        var values = self.values orelse Values.init(alloc);
        try values.appendSlice(slice);
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

            var last: usize = 0;
            if (self.path) |path| {
                try writeFieldString(.path, .object_path, path, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.member) |member| {
                try writeFieldString(.member, .string, member, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.interface) |iface| {
                try writeFieldString(.interface, .string, iface, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.error_name) |error_name| {
                try writeFieldString(.error_name, .string, error_name, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.destination) |dest| {
                try writeFieldString(.destination, .string, dest, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.reply_serial) |serial| {
                try writeFieldIntU32(.reply_serial, serial, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.signature) |signature| {
                try writeFieldSignature(signature, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.sender) |sender| {
                try writeFieldString(.sender, .string, sender, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            if (self.unix_fds) |fds| {
                try writeFieldIntU32(.unix_fds, fds, buf.items.len, buf_writer);
                last = buf.items.len;
                const i = TypeSignature.@"struct".alignOffset(buf.items.len);
                try buf_writer.writeByteNTimes(0x00, i);
            }

            self.header.fields_len = @as(u32, @intCast(last));

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

            var i: usize = 0;
            for (values.values.items) |value| {
                try buf_writer.writeByteNTimes(0x00, value.type.alignOffset(i));
                switch (value.type) {
                    .byte => {
                        try buf_writer.writeByte(value.inner.byte);
                        i += @sizeOf(u8);
                    },
                    .boolean => {
                        try buf_writer.writeInt(u32, value.inner.uint32, .little);
                        i += @sizeOf(u32);
                    },
                    .int16 => {
                        try buf_writer.writeInt(i16, value.inner.int16, .little);
                        i += @sizeOf(i16);
                    },
                    .uint16 => {
                        try buf_writer.writeInt(u16, value.inner.uint16, .little);
                        i += @sizeOf(u16);
                    },
                    .int32 => {
                        try buf_writer.writeInt(i32, value.inner.int32, .little);
                        i += @sizeOf(i32);
                    },
                    .uint32 => {
                        try buf_writer.writeInt(u32, value.inner.uint32, .little);
                        i += @sizeOf(u32);
                    },
                    .int64 => {
                        try buf_writer.writeInt(i64, value.inner.int64, .little);
                        i += @sizeOf(i64);
                    },
                    .uint64 => {
                        try buf_writer.writeInt(u64, value.inner.uint64, .little);
                        i += @sizeOf(u64);
                    },
                    .double => {
                        try buf_writer.writeInt(u64, @as(u64, @bitCast(value.inner.double)), .little);
                        i += @sizeOf(f64);
                    },
                    .string => {
                        try buf_writer.writeInt(u32, @as(u32, @intCast(value.inner.string.len)), .little);
                        try buf_writer.writeAll(value.inner.string);
                        try buf_writer.writeByte(0x00);
                        i += @sizeOf(u32) + value.inner.string.len + 1;
                    },
                    .object_path => {
                        try buf_writer.writeInt(u32, @as(u32, @intCast(value.inner.object_path.len)), .little);
                        try buf_writer.writeAll(value.inner.object_path);
                        try buf_writer.writeByte(0x00);
                        i += @sizeOf(u32) + value.inner.object_path.len + 1;
                    },
                    // TODO:
                    // .signature, array, .@"struct", .dict_entry, .variant, .unix_fd
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
        const v = iter.next(.variant) orelse return error.EOF;
        const t: TypeSignature = @enumFromInt(v[0]);
        if (t != type_) {
            std.debug.print("invalid type: {any}\n", .{t});
            return error.InvalidField;
        }

        const slice = iter.next(type_) orelse return error.EOF;
        field.* = slice;
    }

    fn readIntU32(field: *?u32, iter: *BytesIterator) !void {
        const v = iter.next(.variant) orelse return error.EOF;
        if (@as(TypeSignature, @enumFromInt(v[0])) != .uint32)
            return error.InvalidField;

        const slice = iter.next(.uint32) orelse return error.EOF;
        field.* = mem.readInt(u32, slice[0..4], .little);
    }

    fn parseFields(self: *Self) !void {
        var bytes_iter: BytesIterator = .{ .buffer = self.fields_buf.? };

        while (bytes_iter.next(.byte)) |t| {
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

    fn parseBody(self: *Self, alloc: Allocator, sig: ?[]const u8, slice: ?[]const u8) !void {
        var sig_iter: SignatureIterator = .{ .buffer = sig orelse self.signature.? };
        var bytes_iter: BytesIterator = .{ .buffer = slice orelse self.body_buf.? };

        var values: Values = Values.init(alloc);

        while (sig_iter.next()) |t| {
            const T: TypeSignature = @enumFromInt(t);
            const bytes = bytes_iter.next(T) orelse return error.InvalidBodySignature;

            // TODO: use iter in readContainerType
            const contained_sig = switch (T) {
                .array, .@"struct", .dict_entry, .variant => try readContainerType(t, sig_iter.rest(), 0),
                else => null,
            };
            if (contained_sig) |s| sig_iter.advance(s.len);

            const value: ValueUnion = switch (T) {
                .byte => .{ .byte = bytes[0] },
                .boolean => .{ .boolean = mem.readInt(u32, bytes[0..4], .little) == 1 },
                .int16 => .{ .int16 = mem.readInt(i16, bytes[0..2], .little) },
                .uint16 => .{ .uint16 = mem.readInt(u16, bytes[0..2], .little) },
                .int32 => .{ .int32 = mem.readInt(i32, bytes[0..4], .little) },
                .uint32 => .{ .uint32 = mem.readInt(u32, bytes[0..4], .little) },
                .int64 => .{ .int64 = mem.readInt(i64, bytes[0..8], .little) },
                .uint64 => .{ .uint64 = mem.readInt(u64, bytes[0..8], .little) },
                .double => .{ .double = @as(f64, @bitCast(mem.readInt(u64, bytes[0..8], .little))) },
                .string => .{ .string = bytes },
                .object_path => .{ .object_path = bytes },
                .signature => unreachable,
                .array => blk: {
                    var arr = ArrayList(ValueUnion).init(alloc);
                    errdefer arr.deinit();
                    try self.parseBody(alloc, contained_sig, bytes);
                    break :blk .{ .array = try arr.toOwnedSlice() };
                },
                // TODO
                // .@"struct", .dict_entry, .variant => unreachable,
                else => return error.InvalidType,
            };
            try values.append(.{ .type = T, .contained_sig = contained_sig, .slice = bytes, .inner = value });
        }
        self.values = values;
    }

    pub fn decode(alloc: Allocator, reader: anytype) !Self {
        const header = try reader.readStruct(Header);
        var message: Self = .{ .header = header };

        message.fields_buf = try alloc.alloc(u8, message.header.fields_len);
        errdefer alloc.free(message.fields_buf.?);
        var n = try reader.readAll(message.fields_buf.?);
        if (n != message.header.fields_len) return error.InvalidFields;
        try message.parseFields();

        if (message.header.body_len == 0 and message.signature == null)
            return message;

        if (message.header.body_len == 0 and message.signature != null)
            return error.InvalidBody;
        if (message.header.body_len > 0 and message.signature == null)
            return error.InvalidSignature;

        // align to the start of the body
        // and confirm padding bytes are zero
        const sig: TypeSignature = .@"struct";
        const pad = sig.alignOffset(@sizeOf(Header) + message.header.fields_len);
        for (0..pad) |_| assert(try reader.readByte() == 0x00);

        message.body_buf = try alloc.alloc(u8, message.header.body_len);
        errdefer alloc.free(message.body_buf.?);
        n = try reader.readAll(message.body_buf.?);
        if (n != message.header.body_len) return error.InvalidBody;
        try message.parseBody(alloc, null, null);

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

test "encode method call" {
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
                        .string = &[_]u8{
                            0x63, 0x6f, 0x6d, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x2e, 0x54, 0x65, 0x73, 0x74, 0x42, 0x75, 0x73
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
                    .inner = .{ .string = &[_]u8{0x3a, 0x31, 0x2e, 0x31, 0x39, 0x39, 0x33} }
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
    const alloc = std.testing.allocator;
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
    };
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

        // if (case.body) |_| {
        //     for (msg.values.?.values.items) |value| {
        //         const inner = value.inner;
        //         const t = std.meta.activeTag(inner);
        //         switch (t) {
        //             .string => {
        //                 std.debug.print("value: {s}\n", .{inner.string});
        //             },
        //             .uint32 => {
        //                 std.debug.print("value: {d}\n", .{inner.uint32});
        //             },
        //             else => {
        //                 std.debug.print("value: {any}\n", .{inner});
        //             }
        //         }
        //     }
        // }
    }
}

const TypeSignature = enum(u8) {
    null,
    byte = 'y',
    boolean = 'b',
    int16 = 'n',
    uint16 = 'q',
    int32 = 'i',
    uint32 = 'u',
    int64 = 'x',
    uint64 = 't',
    double = 'd',
    string = 's',
    object_path = 'o',
    signature = 'g',
    array = 'a',
    @"struct" = '(', // r
    variant = 'v',
    dict_entry = '{', // e
    unix_fd = 'h',

    /// get the Dbus spec alignment for the given type type
    fn alignOf(self: TypeSignature) usize {
        return switch (self) {
            .null, .signature, .variant, .byte => 1,
            .int16, .uint16 => 2,
            .int32, .uint32, .boolean, .string, .object_path, .array, .unix_fd => 4,
            .int64, .uint64, .double, .@"struct", .dict_entry => 8,
        };
    }

    /// get the offset to the next alignment for this type
    fn alignOffset(self: TypeSignature, index: usize) usize {
        if (index == 0) return 0;
        const alignment = self.alignOf();
        return (~index + 1) & (alignment - 1);
    }
};

const BytesIterator = struct {
    buffer: []const u8,
    index: usize = 0,
    const Self = @This();

    fn next(self: *Self, T: TypeSignature) ?[]const u8 {
        const result, const n = self.peek(T) orelse return null;
        self.index += n;
        return result;
    }

    fn peek(self: *Self, T: TypeSignature) ?struct{ []const u8, usize } {
        const offset = T.alignOffset(self.index);
        const alignment = self.index + offset;
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
                const len = mem.readInt(u32, slice, .little) + 1;
                // TODO: padding to contained type
                const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
                const n = offset + len + @sizeOf(u32) + 1;
                break :blk .{ ret, n };
            },
            .@"struct" => blk: {
                const slice = self.buffer[alignment..][0..@sizeOf(u32)];
                const len = mem.readInt(u32, slice, .little) + 1;
                const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
                const n = offset + len + @sizeOf(u32) + 1;
                break :blk .{ ret, n };
            },
            .dict_entry => blk: {
                const slice = self.buffer[alignment..][0..@sizeOf(u32)];
                const len = mem.readInt(u32, slice, .little) + 1;
                const ret = self.buffer[alignment+@sizeOf(u32)..][0..len];
                const n = offset + len + @sizeOf(u32) + 1;
                break :blk .{ ret, n };
            },
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

fn contains(b: u8, s: []const u8) bool {
    for (s) |c| if (b == c) return true;
    return false;
}

fn readContainerType(t: u8, sig: []const u8, stack_size: u8) ![]const u8 {
    if (stack_size == 64) return error.MaxDepthExceeded;
    if (!contains(sig[0], "a({")) return sig[0..1];

    var i: u8 = 0;
    var j: usize = 0;
    var stack: [64]u8 = undefined;

    if (t == '(') {
        stack[i] = ')';
        i += 1;
    }

    if (t == '{') {
        stack[i] = '}';
        i += 1;
    }

    while (j < sig.len) {
        switch (sig[j]) {
            'a' => {
                const arr_type = try readContainerType('a', sig[j + 1 ..], stack_size + i);
                j += arr_type.len;
            },
            '(' => {
                if (i > stack.len) return error.MaxDepthExceeded;
                stack[i] = ')';
                i += 1;
            },
            ')' => {
                if (stack[i - 1] == sig[j]) {
                    i -= 1;
                } else return error.InvalidSignature;
            },
            '{' => {
                if (i > stack.len) return error.MaxDepthExceeded;
                stack[i] = '}';
                i += 1;
            },
            '}' => {
                if (stack[i - 1] == sig[j]) {
                    i -= 1;
                } else return error.InvalidSignature;
            },
            else => {},
        }
        j += 1;
        if (i == 0) return sig[0..j];
    }

    return error.InvalidSignature;
}

test "array types" {
    const cases = [_]struct {
        sig: []const u8,
        expected: []const u8
    }{
        .{ .sig = "yaai", .expected = "y" },
        .{ .sig = "ayuu", .expected = "ay" },
        .{ .sig = "{ay}yy", .expected = "{ay}" },
        .{ .sig = "{a{ay}}aay", .expected = "{a{ay}}" },
        .{ .sig = "{a{a{ay}}}uu", .expected = "{a{a{ay}}}" },
        .{ .sig = "{a{a{a{ay}}}}xx", .expected = "{a{a{a{ay}}}}" }
    };
    for (cases) |c| {
        const arr_type = try readContainerType('a', c.sig, 0);
        try std.testing.expectEqualSlices(u8, c.expected, arr_type);
    }
}

const ValueUnion = union(enum) {
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    array: []ValueUnion,
    @"struct": []ValueUnion,
    variant: struct{[]const u8, *ValueUnion},
    dict_entry: struct{*ValueUnion, *ValueUnion},
};

pub const Value = struct {
    type: TypeSignature,
    inner: ValueUnion,
    contained_sig: ?[]const u8 = null,
    slice: ?[]const u8 = null,
};

const Values = struct {
    values: ArrayList(Value),

    const Self = @This();

    pub fn init(alloc: Allocator) Values {
        return .{
            .values = ArrayList(Value).init(alloc),
        };
    }

    fn free(alloc: Allocator, value: *ValueUnion) void {
        switch (value.*) {
            .array, .@"struct" => |val| {
                for (val) |*v| free(alloc, v);
                alloc.free(val);
            },
            .variant => |v| {
                free(alloc, v[1]);
                alloc.destroy(v[1]);
            },
            .dict_entry => |v| {
                free(alloc, v[0]);
                free(alloc, v[1]);
                alloc.destroy(v[0]);
                alloc.destroy(v[1]);
            },
            else => {},
        }
    }

    pub fn deinit(self: *Values, alloc: Allocator) void {
        for (self.values.items) |*value| {
            free(alloc, &value.inner);
            // TODO: don't want to have to allocate these
            // when generating the message
            // alloc.free(value.contained_sig);
            // alloc.free(value.slice);
        }
        self.values.deinit();
    }

    /// Get a reference to the value at the given index,
    /// returns null if the index is out of bounds.
    pub fn get(self: *Values, index: usize) ?*Value {
        if (index >= self.values.len) return null;
        return &self.values.items[index];
    }

    /// Append a new value to the values array.
    pub fn append(self: *Values, value: Value) !void {
        try self.values.append(value);
    }

    pub fn appendSlice(self: *Self, slice: []const Value) !void {
        try self.values.appendSlice(slice);
    }

    pub fn fromSlice(alloc: Allocator, slice: []const Value) !Values {
        var values = try ArrayList(Value).initCapacity(alloc, slice.len);
        values.insertSlice(0, slice) catch unreachable;
        return .{
            .values = values,
        };
    }
};

fn nest(alloc: Allocator, depth: u8) []ValueUnion {
    if (depth == 0) return blk: {
        const v = alloc.alloc(ValueUnion, 1) catch unreachable;
        v[0] = .{ .byte = 1 };
        break :blk v;
    };
    const v = alloc.alloc(ValueUnion, 1) catch unreachable;
    v[0] = .{ .array = nest(alloc, depth - 1) };
    return v;
}

test "values arrays" {
    const alloc = std.testing.allocator;
    var values = Values.init(alloc);
    try values.append(.{
        .type = .array,
        .inner = .{ .array = nest(alloc, 10) },
        .contained_sig = null,
        .slice = &[_]u8{}
    });
    values.deinit(alloc);
}
