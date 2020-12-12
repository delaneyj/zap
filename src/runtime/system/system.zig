const zap = @import("../../zap.zig");
const target = zap.runtime.target;

pub usingnamespace
    if (target.is_windows)
        @import("./windows.zig")
    else if (target.is_linux)
        @import("./linux.zig")
    else if (target.is_darwin)
        @import("./darwin.zig")
    else if (target.is_bsd)
        @import("./bsd.zig")
    else
        @compileError("Operating system not supported yet");