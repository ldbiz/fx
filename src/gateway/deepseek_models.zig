const std = @import("std");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const types = @import("../core/shared/types.zig");

/// DeepSeek publishes these two stable text models with identical documented
/// capability envelopes. This catalog deliberately has no network fetch: model
/// selection must stay available to direct BYOK users before their first paid
/// provider request, and it must not depend on another provider endpoint.
pub const model_catalog_provider = model_catalog.Provider{ .fetch_fn = fetchCatalog };
pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{ .fetch_fn = fetchCliCatalog };

const context_window: u32 = 1_000_000;
const max_output_tokens: u32 = 384_000;
const ids = [_][]const u8{ "deepseek-v4-flash", "deepseek-v4-pro" };

/// Fast direct model used for automatic permission review in auto mode.
pub const reviewer_model = "deepseek-v4-flash";

/// Public capability fallback used before catalog loading and in routes which
/// intentionally avoid a remote model-discovery call.
pub fn capabilitiesForModel(model: []const u8) model_capabilities.Capabilities {
    if (!isSupportedModel(model)) return .{};
    return .{
        .supports_reasoning = true,
        .reasoning_efforts = .fromSlice(&.{
            types.ReasoningEffort.literal("low"),
            types.ReasoningEffort.literal("high"),
            types.ReasoningEffort.literal("max"),
        }),
        .supports_tool_use = true,
        .context_window = context_window,
        .max_output_tokens = max_output_tokens,
    };
}

fn isSupportedModel(model: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, model, id)) return true;
    return false;
}

fn fetchCatalog(_: ?*anyopaque, alloc: std.mem.Allocator, input: model_catalog.FetchInput) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    var catalog = try buildCatalog(alloc);
    if (!reviewerModelAvailable(catalog.items)) {
        model_catalog.freeModelCatalog(alloc, &catalog);
        return .{ .failure = .{ .category = .malformed_response } };
    }
    return .{ .catalog = catalog };
}

fn reviewerModelAvailable(entries: []const model_catalog.ModelCatalogEntry) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, reviewer_model)) return true;
    }
    return false;
}

fn fetchCliCatalog(_: ?*anyopaque, alloc: std.mem.Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{
        .access = .init(input.access),
        .anonymous_fallback_used = false,
        .failure = .{ .category = .cancellation },
    } };
    var catalog = buildCatalog(alloc) catch return .{ .failure = .{
        .access = .init(input.access),
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    const projected = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
        .access = .init(input.access),
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
    return .{ .loaded = .{ .ids = projected, .provenance = .{ .access = .init(input.access) } } };
}

fn buildCatalog(alloc: std.mem.Allocator) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (ids) |id| try appendEntry(alloc, &catalog, id);
    return catalog;
}

fn appendEntry(alloc: std.mem.Allocator, catalog: *std.ArrayList(model_catalog.ModelCatalogEntry), id_value: []const u8) !void {
    const id = try alloc.dupe(u8, id_value);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    try efforts.appendSlice(alloc, &.{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
        types.ReasoningEffort.literal("max"),
    });
    const entry = model_catalog.ModelCatalogEntry{
        .id = id,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = true,
        .reasoning_efforts = efforts,
        .context_window = context_window,
        .max_tokens = max_output_tokens,
    };
    try catalog.append(alloc, entry);
    // Ownership moved into the catalog entry.
    efforts = .empty;
}

test "DeepSeek static catalog exposes only stable direct-BYOK models" {
    const result = try model_catalog_provider.fetch(std.testing.allocator, .{ .endpoint = "" });
    var catalog = switch (result) {
        .catalog => |value| value,
        .failure => return error.TestUnexpectedFailure,
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("deepseek-v4-flash", catalog.items[0].id);
    try std.testing.expectEqualStrings("deepseek-v4-pro", catalog.items[1].id);
    for (catalog.items) |entry| {
        try std.testing.expect(entry.has_tool_use and entry.has_reasoning);
        try std.testing.expectEqual(context_window, entry.context_window);
        try std.testing.expectEqual(max_output_tokens, entry.max_tokens);
        try std.testing.expectEqual(@as(usize, 3), entry.reasoning_efforts.items.len);
    }
}

test "DeepSeek static CLI catalog preserves direct model order" {
    const result = cli_model_catalog_provider.fetch(std.testing.allocator, .{ .endpoint = "" });
    var loaded = switch (result) {
        .loaded => |value| value,
        .failure => return error.TestUnexpectedFailure,
    };
    defer {
        for (loaded.ids.items) |id| std.testing.allocator.free(id);
        loaded.ids.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.ids.items.len);
    try std.testing.expectEqualStrings("deepseek-v4-flash", loaded.ids.items[0]);
    try std.testing.expectEqualStrings("deepseek-v4-pro", loaded.ids.items[1]);
}

test "DeepSeek static catalog includes the permission reviewer model" {
    const result = try model_catalog_provider.fetch(std.testing.allocator, .{ .endpoint = "" });
    var catalog = switch (result) {
        .catalog => |value| value,
        .failure => return error.TestUnexpectedFailure,
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expect(reviewerModelAvailable(catalog.items));
}

test "DeepSeek fallback capabilities match the static catalog" {
    const capabilities = capabilitiesForModel("deepseek-v4-flash");
    try std.testing.expect(capabilities.supports_reasoning);
    try std.testing.expect(capabilities.supports_tool_use);
    try std.testing.expectEqual(context_window, capabilities.context_window.?);
    try std.testing.expectEqual(max_output_tokens, capabilities.max_output_tokens.?);
    try std.testing.expectEqual(@as(usize, 3), capabilities.reasoning_efforts.len);
    try std.testing.expect(!capabilitiesForModel("deepseek-chat").supports_tool_use);
}
