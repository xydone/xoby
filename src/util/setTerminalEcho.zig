// https://ziggit.dev/t/get-password-input/12258/6
fn setEchoWindows(enable: bool) !void {
    const windows = std.os.windows;
    const kernel32 = windows.kernel32;

    const stdout_handle = kernel32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return error.StdHandleFailed;

    var mode: windows.DWORD = undefined;
    _ = kernel32.GetConsoleMode(stdout_handle, &mode);

    const ENABLE_ECHO_MODE: u32 = 0x0004;
    const new_mode = if (enable) mode | ENABLE_ECHO_MODE else mode & ~ENABLE_ECHO_MODE;
    _ = kernel32.SetConsoleMode(stdout_handle, new_mode);
}

fn setEchoPosix(enable: bool) !void {
    const fd = std.fs.File.stdin().handle;
    var termios: std.posix.termios = try std.posix.tcgetattr(fd);
    termios.lflag.ECHO = enable;
    try std.posix.tcsetattr(fd, .NOW, termios);
}

pub fn setEcho(enable: bool) !void {
    switch (builtin.os.tag) {
        .windows => setEchoWindows(enable) catch {},
        else => setEchoPosix(enable) catch {},
    }
}

const builtin = @import("builtin");
const std = @import("std");
