//! Scenario tests for Amethyst's layouts: tatami run with 'tatami default-config amethyst',
//! against the simulated OS with its faults off, so every frame is exact.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const tree = @import("tree.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const WindowId = engine_module.WindowId;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

/// The simulated laptop screen without its 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);

fn boot() *sim.Simulator {
    var config: config_module.Config = undefined;
    var buffer: [512]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    std.debug.assert(config.load(config_module.amethyst_source, &diagnostics));
    engine.init(&config);
    simulator.init(&engine, .{ .seed = 1, .faults = false });
    return &simulator;
}

fn open(os: *sim.Simulator, app: i32) WindowId {
    const id = os.window_open(app, .{});
    os.advance(1);
    os.settle();
    return id;
}

fn run(os: *sim.Simulator, text: []const u8) void {
    os.command_run(text);
    os.settle();
}

fn expect_frame(expected: Rect, id: WindowId) !void {
    const actual = simulator.window_find(id).?.frame;
    if (actual.eql(expected)) return;
    std.debug.print("window {d}: expected {any}, found {any}\n", .{ id, expected, actual });
    return error.TestUnexpectedResult;
}

fn workspace_of(monitor: u32) *engine_module.Workspace {
    return &engine.workspaces[engine.monitors[monitor].workspace];
}

test "tall: the first window is the main pane and the others share the right" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    try expect_frame(screen, a);
    const b = open(os, app);
    const c = open(os, app);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 539), b);
    try expect_frame(Rect.init(864, 577, 864, 540), c);
    // mod1-l and mod1-h: the main pane grows and shrinks by a twentieth of the screen.
    run(os, "main expand");
    try expect_frame(Rect.init(0, 38, 950, 1079), a);
    try expect_frame(Rect.init(950, 38, 778, 539), b);
    run(os, "main shrink");
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    // mod1-, and mod1-.: two windows in the main pane, then one again.
    run(os, "main more");
    try expect_frame(Rect.init(0, 38, 864, 539), a);
    try expect_frame(Rect.init(0, 577, 864, 540), b);
    try expect_frame(Rect.init(864, 38, 864, 1079), c);
    run(os, "main fewer");
    run(os, "main fewer"); // Never fewer than one.
    try testing.expectEqual(@as(u8, 1), workspace_of(0).main_count);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    // mod1-enter: the focused window goes to the main pane and keeps the focus.
    try testing.expectEqual(c, engine.focused_window);
    run(os, "main swap");
    try expect_frame(Rect.init(0, 38, 864, 1079), c);
    try expect_frame(Rect.init(864, 577, 864, 540), a);
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(c, os.focused);
    // From the main pane it trades with the next window.
    run(os, "main swap");
    try expect_frame(Rect.init(0, 38, 864, 1079), b);
    try expect_frame(Rect.init(864, 38, 864, 539), c);
}

test "focus and swap go around the layout order, as Amethyst's clockwise does" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    const c = open(os, app);
    run(os, "focus next --wrap");
    try testing.expectEqual(a, engine.focused_window);
    run(os, "focus prev --wrap");
    try testing.expectEqual(c, engine.focused_window);
    run(os, "main focus");
    try testing.expectEqual(a, engine.focused_window);
    // The last window swapped onward becomes the first.
    run(os, "focus 102");
    run(os, "swap next");
    try expect_frame(Rect.init(0, 38, 864, 1079), c);
    try expect_frame(Rect.init(864, 577, 864, 540), a);
    run(os, "swap prev");
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 577, 864, 540), c);
    try testing.expectEqual(c, engine.focused_window);
    // Directions still go by where the windows are.
    run(os, "focus north");
    try testing.expectEqual(b, engine.focused_window);
    run(os, "focus west");
    try testing.expectEqual(a, engine.focused_window);
}

test "mod1-space goes through the configured layouts, and the tree is kept underneath" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    const c = open(os, app);
    const workspace = workspace_of(0);
    try testing.expectEqual(engine_module.Tiling.tall, workspace.tiling);
    run(os, "layout next");
    try testing.expectEqual(engine_module.Tiling.wide, workspace.tiling);
    try expect_frame(Rect.init(0, 38, 1728, 540), a);
    try expect_frame(Rect.init(0, 578, 864, 539), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
    run(os, "layout 3column-middle");
    try expect_frame(Rect.init(432, 38, 864, 1079), a);
    try expect_frame(Rect.init(0, 38, 432, 1079), b);
    try expect_frame(Rect.init(1296, 38, 432, 1079), c);
    // Out of the cycle, the next layout is its first.
    run(os, "layout next");
    try testing.expectEqual(engine_module.Tiling.tall, workspace.tiling);
    run(os, "layout next");
    run(os, "layout next");
    try testing.expectEqual(engine_module.Tiling.fullscreen, workspace.tiling);
    for ([_]WindowId{ a, b, c }) |id| try expect_frame(screen, id);
    run(os, "layout next");
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 432, 1079), b);
    try expect_frame(Rect.init(1296, 38, 432, 1079), c);
    run(os, "layout next");
    try testing.expectEqual(engine_module.Tiling.tall, workspace.tiling);
    run(os, "layout prev");
    try testing.expectEqual(engine_module.Tiling.column, workspace.tiling);
    // A layout out of the cycle is still there by name, and so is the tree.
    run(os, "layout bsp");
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
    run(os, "layout tall-right");
    try expect_frame(Rect.init(864, 38, 864, 1079), a);
    try expect_frame(Rect.init(0, 38, 864, 539), b);
    const listed = engine_reply(os, "query workspaces");
    try testing.expect(std.mem.indexOf(u8, listed, "\ttall-right\tmain=1\t50%\n") != null);
    const json = engine_reply(os, "query workspaces --json");
    try testing.expect(std.mem.indexOf(u8, json, "\"tiling\":\"tall-right\"") != null);
}

fn engine_reply(os: *sim.Simulator, text: []const u8) []const u8 {
    os.command_run(text);
    return engine.reply();
}

test "every screen has a layout of its own, and windows thrown between them follow it" {
    const os = boot();
    os.monitors_set(1); // The laptop, and a 2560x1440 display on its right.
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    run(os, "focus-monitor 2");
    const c = open(os, app);
    const d = open(os, app);
    const e = open(os, app);
    run(os, "layout wide");
    try testing.expectEqual(engine_module.Tiling.tall, workspace_of(0).tiling);
    try testing.expectEqual(engine_module.Tiling.wide, workspace_of(1).tiling);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 1079), b);
    const external = Rect.init(1728, 38, 2560, 1402);
    try expect_frame(Rect.init(external.x, 38, 2560, 701), c);
    try expect_frame(Rect.init(external.x, 739, 1280, 701), d);
    try expect_frame(Rect.init(external.x + 1280, 739, 1280, 701), e);
    // mod2-w: throw the focused window to screen 1. It joins that screen's tall layout,
    // after the window that had focus there, and focus goes with it.
    try testing.expectEqual(e, engine.focused_window);
    run(os, "send-monitor 1 --follow");
    try testing.expectEqual(e, engine.focused_window);
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 539), b);
    try expect_frame(Rect.init(864, 577, 864, 540), e);
    try expect_frame(Rect.init(external.x, 38, 2560, 701), c);
    try expect_frame(Rect.init(external.x, 739, 2560, 701), d);
    // The main pane of one screen changes on its own.
    run(os, "main expand");
    try testing.expect(workspace_of(0).main_ratio > tree.ratio_half);
    try testing.expectEqual(tree.ratio_half, workspace_of(1).main_ratio);
    // mod1-n and mod1-p go from screen to screen.
    run(os, "focus-monitor next");
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    run(os, "focus-monitor prev");
    try testing.expectEqual(@as(u8, 0), engine.focused_monitor);
}

test "dragging a tile's edge with the mouse sizes the main pane" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    // The main window made wider: the pane follows it.
    os.window_drag(a, Rect.init(0, 38, 1100, 1079));
    os.settle();
    try expect_frame(Rect.init(0, 38, 1100, 1079), a);
    try expect_frame(Rect.init(1100, 38, 628, 1079), b);
    // The other window made wider: the main pane gives up what it takes.
    os.window_drag(b, Rect.init(900, 38, 828, 1079));
    os.settle();
    try expect_frame(Rect.init(0, 38, 900, 1079), a);
    try expect_frame(Rect.init(900, 38, 828, 1079), b);
    // A drop on the other tile trades places, as in the tree.
    os.window_drag(b, Rect.init(100, 100, 828, 1079));
    os.settle();
    try expect_frame(Rect.init(0, 38, 900, 1079), b);
    try expect_frame(Rect.init(900, 38, 828, 1079), a);
    // Keyboard resize moves the same edge.
    run(os, "resize right 100");
    try expect_frame(Rect.init(0, 38, 1000, 1079), b);
}

test "toggle accordion returns to the layout it left" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    run(os, "layout wide");
    run(os, "toggle accordion");
    try expect_frame(screen, a);
    try expect_frame(screen, b);
    run(os, "toggle accordion");
    try testing.expectEqual(engine_module.Tiling.wide, workspace_of(0).tiling);
    try expect_frame(Rect.init(0, 38, 1728, 540), a);
}

test "two-pane shows the main window and one other, the rest stacked behind it" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    const c = open(os, app);
    run(os, "layout two-pane");
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 1079), b);
    try expect_frame(Rect.init(864, 38, 864, 1079), c);
}

test "a reload that leaves the layout out of the cycle starts the workspace on its first" {
    const os = boot();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    _ = open(os, app);
    run(os, "layout row");
    var config: config_module.Config = undefined;
    var buffer: [512]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    // The same cycle again: a layout chosen by name stays.
    try testing.expect(config.load(config_module.amethyst_source, &diagnostics));
    engine.config_replace(&config);
    try testing.expectEqual(engine_module.Tiling.row, workspace_of(0).tiling);
    try testing.expect(config.load("layouts wide tall\n", &diagnostics));
    engine.config_replace(&config);
    os.command_run("retile");
    os.settle();
    try testing.expectEqual(engine_module.Tiling.wide, workspace_of(0).tiling);
    try expect_frame(Rect.init(0, 38, 1728, 540), a);
}

// Native Spaces: each macOS Space is a workspace, and macOS shows and hides them.

fn boot_native() *sim.Simulator {
    var source: [8 * 1024]u8 = undefined;
    const base = config_module.amethyst_source;
    const extra = "\nspaces native\n";
    @memcpy(source[0..base.len], base);
    @memcpy(source[base.len..][0..extra.len], extra);
    var config: config_module.Config = undefined;
    var buffer: [512]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    std.debug.assert(config.load(source[0 .. base.len + extra.len], &diagnostics));
    std.debug.assert(config.spaces_native);
    engine.init(&config);
    simulator.init(&engine, .{ .seed = 1, .faults = false });
    return &simulator;
}

fn space_show(os: *sim.Simulator, space: u64) void {
    const display = engine.monitors[0].display;
    const shown = [_]engine_module.SpaceShown{.{ .display = display, .space = space }};
    os.inject(.{ .spaces_shown = &shown });
    os.settle();
}

fn space_of(os: *sim.Simulator, id: WindowId, space: u64) void {
    os.inject(.{ .window_space = .{ .id = id, .space = space } });
    os.settle();
}

test "native Spaces: each Space has its own layout, and macOS hides the others" {
    const os = boot_native();
    space_show(os, 11);
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 1079), b);
    // A window that is on Space 22 leaves the layout of Space 11, and is not parked: it
    // is not on screen anyway.
    const c = open(os, app);
    space_of(os, c, 22);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(864, 38, 864, 1079), b);
    const c_frame = simulator.window_find(c).?.frame;
    try testing.expect(c_frame.x >= 0 and c_frame.x < 1728);
    try testing.expect(engine.window_find(c).?.workspace != engine.window_find(a).?.workspace);
    // Space 22 comes into view: its one window fills it, and Space 11's are left alone.
    space_show(os, 22);
    try expect_frame(screen, c);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    run(os, "layout wide");
    const d = open(os, app);
    try expect_frame(Rect.init(0, 38, 1728, 540), c);
    try expect_frame(Rect.init(0, 578, 1728, 539), d);
    // Back on Space 11: still tall, and nothing on it moved.
    space_show(os, 11);
    try testing.expectEqual(engine_module.Tiling.tall, workspace_of(0).tiling);
    try expect_frame(Rect.init(0, 38, 864, 1079), a);
    try expect_frame(Rect.init(0, 578, 1728, 539), d);
    // Space 22 kept its layout.
    space_show(os, 22);
    try testing.expectEqual(engine_module.Tiling.wide, workspace_of(0).tiling);
}

test "native Spaces: switching and throwing go to macOS, and the move comes back" {
    const os = boot_native();
    space_show(os, 11);
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    const b = open(os, app);
    var pool: @import("command.zig").StringPool = .{};
    // ctrl-alt-shift-2: throw b to desktop 2. tatami asks macOS and changes nothing yet.
    const send = try @import("command.zig").parse("send 2 --follow", &pool);
    _ = engine.step(.{ .command = send }, os.now_ms);
    const effects = engine.effects[0..engine.effects_count];
    try testing.expectEqual(@as(usize, 1), effects.len);
    try testing.expectEqual(b, effects[0].space_send.id);
    try testing.expectEqual(@as(u8, 2), effects[0].space_send.target.index);
    try testing.expectEqual(engine.window_find(a).?.workspace, engine.window_find(b).?.workspace);
    const switch_command = try @import("command.zig").parse("workspace next", &pool);
    _ = engine.step(.{ .command = switch_command }, os.now_ms);
    try testing.expect(engine.effects[0] == .space_switch);
    // macOS moved it and slid over: tatami follows.
    space_of(os, b, 22);
    space_show(os, 22);
    try expect_frame(screen, b);
    space_show(os, 11);
    try expect_frame(screen, a);
}

test "native Spaces: a Space that moves to another display brings its layout along" {
    const os = boot_native();
    os.monitors_set(1);
    const shown = [_]engine_module.SpaceShown{
        .{ .display = engine.monitors[0].display, .space = 11 },
        .{ .display = engine.monitors[1].display, .space = 33 },
    };
    os.inject(.{ .spaces_shown = &shown });
    os.settle();
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app);
    run(os, "focus-monitor 2");
    const b = open(os, app);
    const c = open(os, app);
    try expect_frame(Rect.init(1728, 38, 1280, 1402), b);
    try expect_frame(Rect.init(3008, 38, 1280, 1402), c);
    try expect_frame(screen, a);
    // mod2-w: thrown to screen 1, it joins the Space that shows there.
    run(os, "send-monitor 1 --follow");
    try expect_frame(Rect.init(864, 38, 864, 1079), c);
    try expect_frame(Rect.init(1728, 38, 2560, 1402), b);
}
