//! Test root for `zig build test`: pulls in every ztest module so its
//! `test { ... }` blocks run. Not otherwise imported by anything.
pub const toml = @import("toml.zig");
pub const wire = @import("wire.zig");
pub const audit = @import("audit.zig");
pub const oliver = @import("oliver.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
