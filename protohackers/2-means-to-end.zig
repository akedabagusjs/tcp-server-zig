const std = @import("std");
const print = std.debug.print;
const Connection = std.net.Server.Connection;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const db = struct {
    var incremental_id: u32 = undefined;
    var mutex: std.Thread.Mutex = undefined;
    var allocator: Allocator = undefined;
    var session: std.AutoHashMap(u32, std.AutoHashMap(i32, i32)) = undefined;

    pub fn init(alloc: Allocator) void {
        incremental_id = 1;
        mutex = Thread.Mutex{};
        allocator = alloc;
        session = std.AutoHashMap(
            u32,
            std.AutoHashMap(i32, i32)
        ).init(allocator);
    }

    pub fn deinit() void {
        var it = session.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.deinit();
        }
        session.deinit();
    }

    pub fn insertId(id: u32) !void {
        try session.put(id, std.AutoHashMap(i32, i32).init(allocator));
    }

    pub fn insertData(id: u32,  ts: i32, price: i32) !void {
        const dataPtr = session.getPtr(id).?;
        try dataPtr.*.put(ts, price);
    }

    pub fn query(id: u32, min: i32, max: i32) i32 {
        const data = session.get(id).?;

        var sum: i128 = 0;
        var len: usize = 0;
        var it = data.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.* >= min and kv.key_ptr.* <= max) {
                sum += @intCast(kv.value_ptr.*);
                len += 1;
            }
        }

        if (len == 0) return 0;
        return @as(i32, @truncate(@divFloor(sum, len)));
    }

    pub fn getId() u32 {
        mutex.lock();
        defer {
            incremental_id += 1;
            mutex.unlock();
        }

        return incremental_id;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    db.init(allocator);
    defer db.deinit();

    const addr = try std.net.Address.resolveIp("127.0.0.1", 9999);
    var server = try addr.listen(.{ .reuse_address = true });
    print("listening on {}\n", .{addr});

    while (true) {
        if (server.accept()) |conn| {
            const thread = try Thread.spawn(
                .{},
                handleConn,
                .{conn}
            );
            thread.detach();
        } else |e| {
            print("error accepting: {}\n", .{e});
        }
    }
}

fn handleConn(conn: Connection) !void {
    const id = db.getId();

    print("{}> connected from {}\n", .{id, conn.address});
    defer {
        print("{}> closed\n", .{id});
        conn.stream.close();
    }
    try db.insertId(id);

    while (true) {
        handleSession(id, conn) catch |e| switch(e) {
            error.EndOfStream => break,
            else => {
                print("{}> error: {}\n", .{id, e});
                break;
            },
        };
    }
}

fn handleSession(id: u32, conn: Connection) !void {
    const cmd = try conn.stream.reader().readByte();
    switch (cmd) {
        'Q' => try handleQuery(id, conn),
        'I' => try handleInsert(id, conn),
        else => {
            print("{}> unknown cmd\n", .{id});
        },
    }
}

fn handleInsert(id: u32, conn: Connection) !void {
    const ts = try conn.stream.reader().readInt(i32, .big);
    const price = try conn.stream.reader().readInt(i32, .big);

    try db.insertData(id, ts, price);
    print("{}> inserted {}: {}\n", .{id, ts, price});
}

fn handleQuery(id: u32, conn: Connection) !void {
    const min = try conn.stream.reader().readInt(i32, .big);
    const max = try conn.stream.reader().readInt(i32, .big);

    const res = db.query(id, min, max);
    print("{}> query({}, {}) = {}\n", .{id, min, max, res});

    try conn.stream.writer().writeInt(i32, res, .big);
}
