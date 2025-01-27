const std = @import("std");
const print = std.debug.print;
const Thread = std.Thread;
const Connection = std.net.Server.Connection;
const Allocator = std.mem.Allocator;
const join = std.mem.join;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = try std.net.Address.resolveIp("127.0.0.1", 9999);
    var server = try addr.listen(.{ .reuse_address = true });

    var channel = Channel.init(allocator);
    defer channel.deinit();

    while (true) {
        if (server.accept()) |conn| {
            const thread = try Thread.spawn(.{}, handleConn, .{allocator, conn, &channel});
            thread.detach();
        } else |e| {
            print("error accepting connection: {}\n", .{e});
        }
    }
}

fn handleConn(allocator: Allocator, conn: Connection, channel: *Channel) !void {
    defer {
        print("{}> disconnected\n", .{conn.address});
        conn.stream.close();
    }

    print("{}> connected\n", .{conn.address});
    try conn.stream.writeAll("Welcome to budgetchat! What shall I call you?\n");

    var array = std.ArrayList(u8).init(allocator);
    conn.stream.reader().streamUntilDelimiter(array.writer(), '\n', null) catch |e| {
        print("{}> {}\n", .{conn.address, e});
        return;
    };

    if (!isValidUsername(array.items)) {
        try conn.stream.writeAll("invalid username\n");
        return;
    }

    const username = array.items;
    const user = try allocator.create(User);
    user.* = User.init(allocator, conn, channel, username);
    try user.joinChannel();
}

fn isValidUsername(username: []u8) bool {
    for (username) |char| {
        if (!std.ascii.isAlphanumeric(char)) return false;
    }
    return true;
}

const Channel = struct {
    lock: Thread.RwLock,
    users: std.AutoHashMap(*User, void),

    pub fn init(allocator: Allocator) Channel {
        return .{
            .lock = Thread.RwLock{},
            .users = std.AutoHashMap(*User, void).init(allocator),
        };
    }

    pub fn deinit(self: *Channel) void {
        self.users.deinit();
    }

    pub fn add(self: *Channel, user: *User) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.users.put(user, {});
    }

    pub fn remove(self: *Channel, user: *User) !void {
        self.lock.lock();
        defer self.lock.unlock();

        _ = self.users.remove(user);
    }

    pub fn broadcast(self: *Channel, sender: *User, msg: []const u8) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var it = self.users.iterator();
        while (it.next()) |kv| {
            const user = kv.key_ptr.*;
            if (user == sender) continue;
            user.conn.stream.writeAll(msg) catch |e| print("couldn't send broadcasted message: {}\n", .{e});
        }
    }
};

const User = struct {
    channel: *Channel,
    conn: Connection,
    arena_allocator: std.heap.ArenaAllocator,
    username: []const u8,

    pub fn init(allocator: Allocator, conn: Connection, channel: *Channel, username: []const u8) User {
        return .{
            .channel = channel,
            .conn = conn,
            .arena_allocator = std.heap.ArenaAllocator.init(allocator),
            .username = username,
        };
    }

    pub fn joinChannel(self: *User) !void {
        defer self.arena_allocator.deinit();

        try self.channel.add(self);
        print("{}> known as '{s}'\n", .{self.conn.address, self.username});

        try self.welcome();

        self.run() catch |e| {
            print("{s}> error: {}\n", .{self.username, e});
            try self.leave();
        };
    }

    fn welcome(self: *User) !void {
        const usernames = blk: {
            var list = std.ArrayList([]const u8).init(self.arena_allocator.allocator());
            defer list.deinit();

            var it = self.channel.users.iterator();
            while (it.next()) |kv| {
                const user = kv.key_ptr.*;
                if (user == self) continue;
                try list.append(user.username);
            }

            break :blk try join(self.arena_allocator.allocator(), ", ", list.items);
        };

        try self.conn.stream.writer().print("* The room contains: {s}\n", .{usernames});

        const msg = try std.fmt.allocPrint(
            self.arena_allocator.allocator(),
            "* {s} has entered the room\n",
            .{self.username},
        );
        try self.channel.broadcast(self, msg);
    }

    fn run(self: *User) !void {
        var buf = std.ArrayList(u8).init(self.arena_allocator.allocator());
        defer buf.deinit();

        while (true) {
            self.conn.stream.reader().streamUntilDelimiter(buf.writer(), '\n', null) catch |e| switch (e) {
                error.EndOfStream => {
                    try self.leave();
                    break;
                },
                else => unreachable,
            };

            const msg = try std.fmt.allocPrint(
                self.arena_allocator.allocator(),
                "[{s}] {s}\n",
                .{self.username, buf.items},
            );
            print("{s}> {s}\n", .{self.username, buf.items});
            try self.channel.broadcast(self, msg);

            buf.clearRetainingCapacity();
        }
    }

    pub fn leave(self: *User) !void {
        const msg = try std.fmt.allocPrint(
            self.arena_allocator.allocator(),
            "* {s} has left the room\n",
            .{self.username},
        );

        print("{s}> left channel\n", .{self.username});

        try self.channel.broadcast(self, msg);
        try self.channel.remove(self);
    }
};
