//! macOS Spaces, for 'spaces native': which Space each display shows, which Space a
//! window is on, and moving a window to another Space the way Amethyst does.
//!
//! None of this has a public interface. The calls are SkyLight's (the window server's
//! client library, which yabai and Amethyst use too), looked up when tatami starts, so a
//! macOS without them still runs tatami with its own workspaces. Moving a window is not a
//! call at all: the window is held by its title bar with the mouse while Mission Control's
//! "Switch to Desktop N" shortcut is pressed, and macOS carries it along.
const std = @import("std");
const c = @import("c.zig");
const ax = @import("ax.zig");
const engine_module = @import("../engine.zig");

const Ref = c.Ref;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn CFUUIDCreateString(allocator: Ref, uuid: Ref) Ref;
extern "c" fn CFArrayCreate(
    allocator: Ref,
    values: [*]const Ref,
    count: c.CFIndex,
    callbacks: ?*const anyopaque,
) Ref;
extern "c" fn CFNumberCreate(allocator: Ref, number_type: c.CFIndex, value: *const anyopaque) Ref;
extern "c" const kCFTypeArrayCallBacks: u8;
extern "c" fn CGEventCreateMouseEvent(source: Ref, kind: u32, point: c.CGPoint, button: u32) Ref;
extern "c" fn CGEventCreateKeyboardEvent(source: Ref, key: u16, down: bool) Ref;
extern "c" fn CGEventSetFlags(event: Ref, flags: u64) void;
extern "c" fn CGEventPost(tap: u32, event: Ref) void;

const number_sint64: c.CFIndex = 4;
const all_spaces_mask: c_int = 7;
/// A Space of the desktop, as opposed to one that a fullscreen window has to itself.
const space_type_user: i64 = 0;
/// "Switch to Desktop 1" among Mission Control's shortcuts; Desktop N is one more each.
const hot_key_desktop_first: c_int = 118;
const desktops_max: u32 = 16;

const MainConnection = *const fn () callconv(.c) c_int;
const CopyDisplaySpaces = *const fn (c_int) callconv(.c) Ref;
const CopySpacesForWindows = *const fn (c_int, c_int, Ref) callconv(.c) Ref;
const GetHotKey = *const fn (c_int, ?*u16, *u16, *u64) callconv(.c) i32;
const HotKeyEnabled = *const fn (c_int) callconv(.c) bool;
const SetHotKeyEnabled = *const fn (c_int, bool) callconv(.c) i32;

var connection: c_int = 0;
var copy_display_spaces: ?CopyDisplaySpaces = null;
var copy_spaces_for_windows: ?CopySpacesForWindows = null;
var get_hot_key: ?GetHotKey = null;
var hot_key_enabled: ?HotKeyEnabled = null;
var set_hot_key_enabled: ?SetHotKeyEnabled = null;

fn symbol(handle: ?*anyopaque, comptime T: type, names: []const [*:0]const u8) ?T {
    for (names) |name| {
        if (dlsym(handle, name)) |found| return @ptrCast(@alignCast(found));
    }
    return null;
}

/// Looks the calls up. False when this macOS does not have them.
pub fn init() bool {
    const path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
    const handle = dlopen(path, 1) orelse return false;
    const names_main = [_][*:0]const u8{ "SLSMainConnectionID", "CGSMainConnectionID" };
    const main = symbol(handle, MainConnection, &names_main) orelse return false;
    connection = main();
    copy_display_spaces = symbol(handle, CopyDisplaySpaces, &.{
        "SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces",
    });
    copy_spaces_for_windows = symbol(handle, CopySpacesForWindows, &.{
        "SLSCopySpacesForWindows", "CGSCopySpacesForWindows",
    });
    get_hot_key = symbol(handle, GetHotKey, &.{
        "CGSGetSymbolicHotKeyValue", "SLSGetSymbolicHotKeyValue",
    });
    hot_key_enabled = symbol(handle, HotKeyEnabled, &.{
        "CGSIsSymbolicHotKeyEnabled", "SLSIsSymbolicHotKeyEnabled",
    });
    set_hot_key_enabled = symbol(handle, SetHotKeyEnabled, &.{
        "CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled",
    });
    return copy_display_spaces != null and copy_spaces_for_windows != null;
}

/// What the Spaces are right now.
pub const Snapshot = struct {
    /// The Space each display shows.
    shown: [engine_module.monitors_max]engine_module.SpaceShown = undefined,
    shown_count: u32 = 0,
    /// Every desktop Space, numbered as Mission Control numbers them: display after
    /// display, in order. Fullscreen Spaces are not among them.
    desktops: [desktops_max]u64 = undefined,
    desktops_count: u32 = 0,

    pub fn shown_slice(snapshot: *const Snapshot) []const engine_module.SpaceShown {
        return snapshot.shown[0..snapshot.shown_count];
    }

    pub fn is_desktop(snapshot: *const Snapshot, space: u64) bool {
        for (snapshot.desktops[0..snapshot.desktops_count]) |desktop| {
            if (desktop == space) return true;
        }
        return false;
    }

    /// Where a Space is in Mission Control's numbering, counting from 1, or 0.
    pub fn desktop_number(snapshot: *const Snapshot, space: u64) u32 {
        for (snapshot.desktops[0..snapshot.desktops_count], 0..) |desktop, index| {
            if (desktop == space) return @intCast(index + 1);
        }
        return 0;
    }

    pub fn same(a: *const Snapshot, b: *const Snapshot) bool {
        if (a.shown_count != b.shown_count or a.desktops_count != b.desktops_count) return false;
        for (a.shown_slice(), b.shown_slice()) |x, y| {
            if (x.display != y.display or x.space != y.space) return false;
        }
        return std.mem.eql(u64, a.desktops[0..a.desktops_count], b.desktops[0..b.desktops_count]);
    }
};

fn dictionary_number(dictionary: Ref, key: [*:0]const u8) ?i64 {
    const name = c.CFStringCreateWithCString(null, key, c.string_encoding_utf8);
    defer c.CFRelease(name);
    const value = c.CFDictionaryGetValue(dictionary, name);
    if (value == null) return null;
    var number: i64 = 0;
    if (c.CFNumberGetValue(value, number_sint64, &number) == 0) return null;
    return number;
}

fn dictionary_value(dictionary: Ref, key: [*:0]const u8) Ref {
    const name = c.CFStringCreateWithCString(null, key, c.string_encoding_utf8);
    defer c.CFRelease(name);
    return c.CFDictionaryGetValue(dictionary, name);
}

/// The display that macOS names by this identifier: a UUID, or "Main" when the
/// displays share their Spaces.
fn display_of(identifier: Ref, identity: *const fn (c.CGDirectDisplayID) u32) u32 {
    var ids: [engine_module.monitors_max]c.CGDirectDisplayID = undefined;
    var count: u32 = 0;
    if (c.CGGetActiveDisplayList(ids.len, &ids, &count) != 0) return 0;
    for (ids[0..count]) |id| {
        const uuid = c.CGDisplayCreateUUIDFromDisplayID(id);
        if (uuid == null) continue;
        defer c.CFRelease(uuid);
        const text = CFUUIDCreateString(null, uuid);
        if (text == null) continue;
        defer c.CFRelease(text);
        if (c.CFEqual(text, identifier) != 0) return identity(id);
    }
    return identity(c.CGMainDisplayID());
}

/// Reads which Space every display shows, and the desktops in Mission Control's order.
pub fn read(snapshot: *Snapshot, identity: *const fn (c.CGDirectDisplayID) u32) bool {
    snapshot.* = .{};
    const copy = copy_display_spaces orelse return false;
    const displays = copy(connection);
    if (displays == null) return false;
    defer c.CFRelease(displays);
    const count: usize = @intCast(c.CFArrayGetCount(displays));
    for (0..count) |index| {
        const display = c.CFArrayGetValueAtIndex(displays, @intCast(index));
        const identifier = dictionary_value(display, "Display Identifier");
        if (identifier == null) continue;
        const spaces = dictionary_value(display, "Spaces");
        if (spaces != null) {
            const spaces_count: usize = @intCast(c.CFArrayGetCount(spaces));
            for (0..spaces_count) |at| {
                const space = c.CFArrayGetValueAtIndex(spaces, @intCast(at));
                const kind = dictionary_number(space, "type") orelse continue;
                if (kind != space_type_user) continue;
                const id = dictionary_number(space, "id64") orelse
                    dictionary_number(space, "ManagedSpaceID") orelse continue;
                if (snapshot.desktops_count == desktops_max) continue;
                snapshot.desktops[snapshot.desktops_count] = @bitCast(id);
                snapshot.desktops_count += 1;
            }
        }
        const current = dictionary_value(display, "Current Space");
        if (current == null or snapshot.shown_count == snapshot.shown.len) continue;
        const id = dictionary_number(current, "id64") orelse
            dictionary_number(current, "ManagedSpaceID") orelse continue;
        snapshot.shown[snapshot.shown_count] = .{
            .display = display_of(identifier, identity),
            .space = @bitCast(id),
        };
        snapshot.shown_count += 1;
    }
    return snapshot.shown_count > 0;
}

/// The desktop Space each window is on, 0 for one on a fullscreen Space, on every Space,
/// or not known. One call to the window server for all of them.
pub fn windows_spaces(snapshot: *const Snapshot, ids: []const u32, out: []u64) void {
    std.debug.assert(out.len >= ids.len);
    for (out[0..ids.len]) |*space| space.* = 0;
    const copy = copy_spaces_for_windows orelse return;
    for (ids, 0..) |id, index| {
        // One window at a time: the answer for several is one list for all of them.
        const value: i64 = id;
        const number = CFNumberCreate(null, number_sint64, &value);
        defer c.CFRelease(number);
        const values = [_]Ref{number};
        const list = CFArrayCreate(null, &values, 1, &kCFTypeArrayCallBacks);
        defer c.CFRelease(list);
        const spaces = copy(connection, all_spaces_mask, list);
        if (spaces == null) continue;
        defer c.CFRelease(spaces);
        if (c.CFArrayGetCount(spaces) != 1) continue;
        var space: i64 = 0;
        const first = c.CFArrayGetValueAtIndex(spaces, 0);
        if (c.CFNumberGetValue(first, number_sint64, &space) == 0) continue;
        const found: u64 = @bitCast(space);
        if (snapshot.is_desktop(found)) out[index] = found;
    }
}

/// Mission Control's shortcut for "Switch to Desktop N": its key and modifiers, switched on
/// if it was off, as Amethyst does.
const Shortcut = struct { key: u16, flags: u64 };

/// For 'tatami check': whether desktop N has a shortcut, and whether it is on. Changes
/// nothing.
pub fn shortcut_state(number: u32) enum { missing, off, on } {
    const get = get_hot_key orelse return .missing;
    const hot_key: c_int = hot_key_desktop_first + @as(c_int, @intCast(number)) - 1;
    var character: u16 = 0;
    var key: u16 = 0;
    var flags: u64 = 0;
    if (get(hot_key, &character, &key, &flags) != 0) return .missing;
    const enabled = hot_key_enabled orelse return .on;
    return if (enabled(hot_key)) .on else .off;
}

fn desktop_shortcut(number: u32) ?Shortcut {
    if (number < 1 or number > desktops_max) return null;
    const get = get_hot_key orelse return null;
    const hot_key: c_int = hot_key_desktop_first + @as(c_int, @intCast(number)) - 1;
    var character: u16 = 0;
    var key: u16 = 0;
    var flags: u64 = 0;
    if (get(hot_key, &character, &key, &flags) != 0) return null;
    if (hot_key_enabled) |enabled| {
        if (!enabled(hot_key)) {
            if (set_hot_key_enabled) |set| _ = set(hot_key, true);
        }
    }
    return .{ .key = key, .flags = flags & 0xffff_ffff };
}

fn post_key(shortcut: Shortcut) void {
    const down = CGEventCreateKeyboardEvent(null, shortcut.key, true);
    defer c.CFRelease(down);
    CGEventSetFlags(down, shortcut.flags);
    CGEventPost(0, down);
    const up = CGEventCreateKeyboardEvent(null, shortcut.key, false);
    defer c.CFRelease(up);
    CGEventSetFlags(up, 0);
    CGEventPost(0, up);
}

/// Shows desktop N. False when Mission Control has no shortcut for it.
pub fn switch_to(number: u32) bool {
    const shortcut = desktop_shortcut(number) orelse return false;
    post_key(shortcut);
    return true;
}

fn post_mouse(kind: u32, point: c.CGPoint) void {
    const event = CGEventCreateMouseEvent(null, kind, point, 0);
    defer c.CFRelease(event);
    CGEventSetFlags(event, 0);
    CGEventPost(0, event);
}

const mouse_down: u32 = 1;
const mouse_up: u32 = 2;
const mouse_moved: u32 = 5;
const mouse_dragged: u32 = 6;

/// A window on its way to another desktop: held by the title bar until the switch is done.
pub const Carry = struct {
    stage: enum { idle, holding, switched } = .idle,
    at_ms: u64 = 0,
    point: c.CGPoint = .{ .x = 0, .y = 0 },
    /// Where the pointer was, to put it back.
    pointer: c.CGPoint = .{ .x = 0, .y = 0 },
    shortcut: Shortcut = .{ .key = 0, .flags = 0 },
};

/// Grabs the window by its title bar, beside the minimize button as Amethyst does, and
/// gets ready to switch to desktop N. The rest happens in carry_step.
pub fn carry_begin(carry: *Carry, element: Ref, number: u32, now_ms: u64) bool {
    if (carry.stage != .idle) return false;
    const shortcut = desktop_shortcut(number) orelse return false;
    const frame = ax.frame_get(element) catch return false;
    var x: f64 = @floatFromInt(frame.x + 5);
    var y: f64 = @floatFromInt(frame.y + 10);
    if (ax.copy(element, ax.names.minimize_button)) |button| {
        defer c.CFRelease(button);
        if (ax.frame_get(button)) |rect| {
            x = @floatFromInt(rect.x + @divTrunc(rect.w, 2));
            y = @floatFromInt(frame.y + @divTrunc(rect.y - frame.y + rect.h, 2));
        } else |_| {}
    } else |_| {}
    const here = c.CGEventCreate(null);
    defer c.CFRelease(here);
    carry.* = .{
        .stage = .holding,
        .at_ms = now_ms + 50,
        .point = .{ .x = x, .y = y },
        .pointer = c.CGEventGetLocation(here),
        .shortcut = shortcut,
    };
    post_mouse(mouse_moved, carry.point);
    post_mouse(mouse_down, carry.point);
    post_mouse(mouse_dragged, carry.point);
    return true;
}

/// Goes on with a carry whose time has come: presses the shortcut, then, once the Space
/// has slid over, lets go and puts the pointer back.
pub fn carry_step(carry: *Carry, now_ms: u64) void {
    if (carry.stage == .idle or carry.at_ms > now_ms) return;
    switch (carry.stage) {
        .idle => {},
        .holding => {
            post_key(carry.shortcut);
            carry.stage = .switched;
            carry.at_ms = now_ms + 400;
        },
        .switched => {
            post_mouse(mouse_up, carry.point);
            _ = c.CGWarpMouseCursorPosition(carry.pointer);
            carry.* = .{};
        },
    }
}
