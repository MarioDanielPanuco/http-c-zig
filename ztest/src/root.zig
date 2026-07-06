//! Test root for `zig build test`: pulls in every ztest module so its
//! `test { ... }` blocks run. Also the root of the shared `ztest` module
//! every Zig tool in this repo imports.
pub const toml = @import("toml.zig");
pub const wire = @import("wire.zig");
pub const events = @import("events.zig");
pub const audit = @import("audit.zig");
pub const oliver = @import("oliver.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
