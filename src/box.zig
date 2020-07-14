const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const prim = @import("prim.zig");

// promote some primitive ops
pub const size = prim.size;
pub const ignoreSignalInput = prim.ignoreSignalInput;
pub const handleSignalInput = prim.handleSignalInput;
pub const cursorShow = prim.cursorShow;
pub const cursorHide = prim.cursorHide;
pub const nextEvent = prim.nextEvent;
pub const clear = prim.clear;
pub const Event = prim.Event;

usingnamespace @import("util.zig");

/// must be called before any buffers are `push`ed to the terminal.
pub fn init(allocator: *Allocator, in: prim.InTty, out: prim.OutTty) !void {
    front = try Buffer.init(allocator, 24, 80);
    errdefer front.deinit();
    try prim.setup(allocator, in, out);
}

/// should be called prior to program exit
pub fn deinit() void {
    front.deinit();
    prim.teardown();
}

/// compare state of input buffer to a buffer tracking display state
/// and send changes to the terminal.
pub fn push(buffer: Buffer) !void {
    const size_ = Size{ .height = buffer.height, .width = buffer.width };

    // resizing the front buffer naively can lead to artifacting
    // if we do not clear the terminal here.
    if (!std.meta.eql(size_, last_size)) {
        try prim.clear();
        front.clear();
    }
    last_size = size_;

    try front.resize(size_.height, size_.width);
    var row: usize = 1;
    //try prim.beginSync();
    while (row <= size_.height) : (row += 1) {
        var col: usize = 1;
        var last_touched: usize = 0; // out of bounds, can't match col
        while (col <= size_.width) : (col += 1) {

            // go to the next character if these are the same.
            if (Cell.eql(
                front.cell(row, col),
                buffer.cell(row, col),
            )) continue;

            // only send cursor movement sequence if the last modified
            // cell was not the immediately previous cell in this row
            if (last_touched != col)
                try prim.cursorTo(row, col);

            last_touched = col;

            const cell = buffer.cell(row, col);
            front.cellRef(row, col).* = cell;

            var codepoint: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(cell.char, &codepoint);

            try prim.send(codepoint[0..len]);
        }
    }
    //try prim.endSync();

    try prim.flush();
}

//TODO: attributes? Color?
/// structure that represents a single textual character on screen
pub const Cell = struct {
    char: u21 = ' ',
    fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char;
    }
};

/// structure on which terminal drawing and printing operations are performed.
pub const Buffer = struct {
    data: []Cell,
    height: usize,
    width: usize,

    allocator: *Allocator,

    pub const Writer = std.io.Writer(
        *WriteCursor,
        WriteCursor.Error,
        WriteCursor.writeFn,
    );

    /// State tracking for an `io.Writer` into a `Buffer`. Buffers do not hold onto
    /// any information about cursor position, so a sequential operations like writing to
    /// it is not well defined without a helper like this.
    pub const WriteCursor = struct {
        row_num: usize,
        col_num: usize,
        /// wr determines how to continue writing when the the text meets
        /// the last column in a row. In truncate mode, the text until the next newline
        /// is dropped, in wrap mode, input is moved to the first column of the next row.
        wrap: bool = false,

        attribs: void = {}, // will eventually get filled in with color/display attributes
        buffer: *Buffer,

        const Error = error{ InvalidUtf8, InvalidCharacter };

        fn writeFn(self: *WriteCursor, bytes: []const u8) Error!usize {
            if (self.row_num > self.buffer.height) return 0;

            var cp_iter = (try std.unicode.Utf8View.init(bytes)).iterator();
            var bytes_written: usize = 0;
            while (cp_iter.nextCodepoint()) |cp| {
                if (self.col_num > self.buffer.width and self.wrap) {
                    self.col_num = 1;
                    self.row_num += 1;
                }
                if (self.row_num > self.buffer.height) return bytes_written;

                switch (cp) {
                    //TODO: handle other line endings and return an error when
                    // encountering unpritable or width-breaking codepoints.
                    '\n' => {
                        self.col_num = 1;
                        self.row_num += 1;
                    },
                    else => {
                        if (self.col_num <= self.buffer.width)
                            self.buffer.cellRef(self.row_num, self.col_num).*.char = cp;
                        self.col_num += 1;
                    },
                }
                bytes_written = cp_iter.i;
            }
            return bytes_written;
        }

        pub fn writer(self: *WriteCursor) Writer {
            return .{ .context = self };
        }
    };

    /// constructs a `WriteCursor` for the buffer at a given offset.
    pub fn cursorAt(self: *Buffer, row_num: usize, col_num: usize) WriteCursor {
        return .{
            .row_num = row_num,
            .col_num = col_num,
            .buffer = self,
        };
    }
    /// constructs a `WriteCursor` for the buffer at a given offset. data written
    /// through a wrapped cursor wraps around to the next line when it reaches the right
    /// edge of the row.
    pub fn wrappedCursorAt(self: *Buffer, row_num: usize, col_num: usize) WriteCursor {
        var cursor = self.cursorAt(row_num, col_num);
        cursor.wrap = true;
        return cursor;
    }

    pub fn clear(self: *Buffer) void {
        mem.set(Cell, self.data, .{});
    }
    pub fn init(allocator: *Allocator, height: usize, width: usize) !Buffer {
        var self = Buffer{
            .data = try allocator.alloc(Cell, width * height),
            .width = width,
            .height = height,
            .allocator = allocator,
        };
        self.clear();
        return self;
    }
    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
    }
    /// return a slice representing a row at a given context. Generic over the constness
    /// of self; if the buffer is const, the slice elements are const.
    pub fn row(self: anytype, row_num: usize) RowType: {
        switch (@typeInfo(@TypeOf(self))) {
            .Pointer => |p| {
                if (p.child != Buffer) @compileError("expected Buffer");
                if (p.is_const)
                    break :RowType []const Cell
                else
                    break :RowType []Cell;
            },
            else => {
                if (@TypeOf(self) != Buffer) @compileError("expected Buffer");
                break :RowType []const Cell;
            },
        }
    } {
        assert(row_num <= self.height);
        assert(row_num > 0);
        const row_idx = (row_num - 1) * self.width;
        return self.data[row_idx .. row_idx + self.width];
    }

    /// return a reference to the cell at the given row and column number. generic over
    /// the constness of self; if self is const, the cell pointed to is also const.
    pub fn cellRef(self: anytype, row_num: usize, col_num: usize) RefType: {
        switch (@typeInfo(@TypeOf(self))) {
            .Pointer => |p| {
                if (p.child != Buffer) @compileError("expected Buffer");
                if (p.is_const)
                    break :RefType *const Cell
                else
                    break :RefType *Cell;
            },
            else => {
                if (@TypeOf(self) != Buffer) @compileError("expected Buffer");
                break :RefType *const Cell;
            },
        }
    } {
        assert(col_num <= self.width);
        assert(col_num > 0);
        return &self.row(row_num)[col_num - 1];
    }
    /// return a copy of the cell at a given offset
    pub fn cell(self: Buffer, row_num: usize, col_num: usize) Cell {
        assert(col_num <= self.width);
        assert(col_num > 0);
        return self.row(row_num)[col_num - 1];
    }

    /// fill a buffer with the given cell
    pub fn fill(self: *Buffer, a_cell: Cell) void {
        mem.set(Cell, self.data, a_cell);
    }

    /// grows or shrinks a cell buffer ensuring alignment by line and column
    /// data is lost in shrunk dimensions, and new space is initialized
    /// as the default cell in grown dimensions.
    pub fn resize(self: *Buffer, height: usize, width: usize) !void {
        if (self.height == height and self.width == width) return;
        //TODO: figure out more ways to minimize unnecessary reallocation and
        //redrawing here. for instance:
        // `if self.width < width and self.height < self.height` no redraw or
        // realloc required
        // more difficult:
        // `if self.width * self.height >= width * height` requires redraw
        // but could possibly use some sort of scratch buffer thing.
        const old = self.*;
        self.* = .{
            .allocator = old.allocator,
            .width = width,
            .height = height,
            .data = try old.allocator.alloc(Cell, width * height),
        };

        if (width > old.width or
            height > old.height) self.clear();

        const min_height = math.min(old.height, height);
        const min_width = math.min(old.width, width);

        var n: usize = 1;
        while (n <= min_height) : (n += 1) {
            mem.copy(Cell, self.row(n), old.row(n)[0..min_width]);
        }
        self.allocator.free(old.data);
    }

    // draw the contents of 'other' on top of the contents of self at the provided
    // offset. anything out of bounds of the destination is ignored. row_num and col_num
    // are still 1-indexed; this means 0 is out of bounds by 1, and -1 is out of bounds
    // by 2. This may change.
    pub fn blit(self: *Buffer, other: Buffer, row_num: isize, col_num: isize) void {
        var self_row_idx = row_num;
        var other_row_idx: usize = 1;

        while (self_row_idx <= self.height and other_row_idx <= other.height) : ({
            self_row_idx += 1;
            other_row_idx += 1;
        }) {
            if (self_row_idx < 1) continue;

            var self_col_idx = col_num;
            var other_col_idx: usize = 1;

            while (self_col_idx <= self.width and other_col_idx <= other.width) : ({
                self_col_idx += 1;
                other_col_idx += 1;
            }) {
                if (self_col_idx < 1) continue;

                self.cellRef(
                    @intCast(usize, self_row_idx),
                    @intCast(usize, self_col_idx),
                ).* = other.cell(other_row_idx, other_col_idx);
            }
        }
    }

    // std.fmt compatibility for debugging
    pub fn format(
        self: Buffer,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var row_num: usize = 1;

        try writer.print("\n\x1B[4m|", .{});
        while (row_num <= self.height) : (row_num += 1) {
            for (self.row(row_num)) |this_cell| {
                var utf8Seq: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(this_cell.char, &utf8Seq) catch unreachable;
                try writer.print("{}|", .{utf8Seq[0..len]});
            }
            if (row_num != self.height)
                try writer.print("\n|", .{});
        }
        try writer.print("\x1B[0m\n", .{});
    }
};

const Size = struct {
    height: usize,
    width: usize,
};
/// represents the last drawn state of the terminal
var front: Buffer = undefined;
var last_size = Size{ .height = 0, .width = 0 };

test "Buffer.resize()" {
    var buffer = try Buffer.init(std.testing.allocator, 10, 10);
    defer buffer.deinit();

    // newly initialized buffer should have all cells set to default value
    for (buffer.data) |cell| {
        std.testing.expectEqual(Cell{}, cell);
    }
    for (buffer.row(5)[0..3]) |*cell| {
        cell.char = '.';
    }

    try buffer.resize(5, 12);

    // make sure data is preserved between resizes
    for (buffer.row(5)[0..3]) |cell| {
        std.testing.expectEqual(@as(u21, '.'), cell.char);
    }

    // ensure nothing weird was written to expanded rows
    for (buffer.row(3)[3..]) |cell| {
        std.testing.expectEqual(Cell{}, cell);
    }
}

// most useful tests of this are function tests
// see `examples/`
test "buffer.cellRef()" {
    var buffer = try Buffer.init(std.testing.allocator, 1, 1);
    defer buffer.deinit();

    const ref = buffer.cellRef(1, 1);
    ref.* = Cell{ .char = '.' };

    std.testing.expectEqual(@as(u21, '.'), buffer.cell(1, 1).char);
}

test "buffer.cursorAt()" {
    var buffer = try Buffer.init(std.testing.allocator, 10, 10);
    defer buffer.deinit();

    var cursor = buffer.cursorAt(10, 6);
    const n = try cursor.writer().write("hello!!!!!\n!!!!");

    std.debug.print("{}", .{buffer});

    std.testing.expectEqual(@as(usize, 11), n);
}

test "Buffer.blit()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var alloc = &arena.allocator;
    var buffer1 = try Buffer.init(alloc, 10, 10);
    var buffer2 = try Buffer.init(alloc, 5, 5);
    buffer2.fill(.{ .char = '#' });
    std.debug.print("{}", .{buffer2});
    std.debug.print("blit(-3,7)", .{});
    buffer1.blit(buffer2, -3, 7);
    std.debug.print("{}", .{buffer1});
}

test "wrappedWrite" {
    var buffer = try Buffer.init(std.testing.allocator, 5, 5);
    defer buffer.deinit();

    var cursor = buffer.wrappedCursorAt(5, 1);

    const n = try cursor.writer().write("hello!!!!!");

    std.debug.print("{}", .{buffer});

    std.testing.expectEqual(@as(usize, 5), n);
}

test "static anal" {
    std.meta.refAllDecls(@This());
    std.meta.refAllDecls(Cell);
    std.meta.refAllDecls(Buffer);
    std.meta.refAllDecls(Buffer.WriteCursor);
}
