const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub const io_mode = .evented;

var client_id_counter: u32 = 0;
var should_server_close: bool = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const addr = net.Address.parseIp("127.0.0.1", 0) catch unreachable;

    var server = try net.Address.listen(addr, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });

    const server_thread = try std.Thread.spawn(.{}, startServer, .{ allocator, &server });
    server_thread.detach();

    print("listening at {}\n", .{ server.listen_address });

    const in = std.io.getStdIn();
    var buf = std.io.bufferedReader(in.reader());
    var r = buf.reader();

    var msg_buf: [4096]u8 = undefined;

    while (true) {
        const msg = try r.readUntilDelimiterOrEof(&msg_buf, '\n');

        if (msg) |m| {
            if (std.mem.eql(u8, m, "exit")) {
                should_server_close = true;
                break;
            }
        }
    }
}

fn startServer(allocator: Allocator, server: *net.Server) !void {
    defer server.deinit();

    var room = Room.init(allocator);
    defer room.deinit();

    while (true) {
        if (should_server_close) {
            break;
        }

        if (server.accept()) |conn| {
            const client = try allocator.create(Client);
            client.* = Client.init(allocator, conn.stream, &room);
            room.add(client) catch |e| print("couldn't add user to room {any}", .{e});
            const thread = try std.Thread.spawn(.{}, Client.run, .{client});
            thread.detach();
        } else |err| {
            print("error accept connenction: {any}", .{err});
        }
    }
}

const Room = struct {
    lock: std.Thread.RwLock,
    clients: std.AutoHashMap(*Client, void),

    const Self = @This();

    pub fn init(allocator: Allocator) Room {
        return .{
            .lock = std.Thread.RwLock{},
            .clients = std.AutoHashMap(*Client, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.clients.deinit();
    }

    pub fn add(self: *Self, client: *Client) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.clients.put(client, {});
    }

    pub fn remove(self: *Self, client: *Client) !void {
        self.lock.lock();
        defer self.lock.unlock();
        self.clients.remove(client);
    }

    fn broadcast(self: *Self, msg: []const u8, sender: *Client) !void {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var iterator = self.clients.iterator();

        while (iterator.next()) |entry| {
            const client = entry.key_ptr.*;
            if (client == sender) continue;
            client.stream.writeAll(msg) catch |e| print("couldn't send a message: {any}", .{e});
        }
    }
};

const Client = struct {
    room: *Room,
    stream: net.Stream,
    arena_allocator: std.heap.ArenaAllocator,
    id: u32,
    messages_sent_count: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, stream: net.Stream, room: *Room) Client {
        client_id_counter += 1;
        return .{
            .room = room,
            .stream = stream,
            .id = client_id_counter,
            .arena_allocator = std.heap.ArenaAllocator.init(allocator),
            .messages_sent_count = 0,
        };
    }

    pub fn run(self: *Self) !void {
        defer self.stream.close();
        defer self.arena_allocator.deinit();

        try self.stream.writeAll("server: welcome to a chat server\n");

        while (true) {
            var buf: [1024]u8 = undefined;

            const n = try self.stream.read(&buf);
            if (n == 0) {
                print("exiting\n", .{});
                break;
            }

            const msg = try std.fmt.allocPrint(
                self.arena_allocator.allocator(),
                "client {d}> {s}",
                .{ self.id, buf[0..n] }
            );

            try self.room.broadcast(msg, self);

            if (self.messages_sent_count >= 100) {
                _ = self.arena_allocator.reset(.free_all);
            }
        }
    }
};
