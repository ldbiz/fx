const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const deepseek = @import("deepseek.zig");
const deepseek_models = @import("deepseek_models.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewDeepSeek,
};

fn reviewDeepSeek(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = credentialSource(input),
        .model = deepseek_models.reviewer_model,
        .validate_fn = validateCredential,
        .build_fn = deepseek.buildReviewRequest,
        .send_fn = sendPrepared,
    });
}

fn credentialSource(input: permission_auto_classifier.ProviderInput) types.CredentialSource {
    return input.credential_source orelse .deepseek_api_key;
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    if (input.credential.len == 0) return error.MissingCredential;
    const source = credentialSource(input);
    if (source != .deepseek_api_key and source != .deepseek_stored_key) return error.InvalidCredential;
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return deepseek.streamPrepared(alloc, request, payload);
}

test "DeepSeek reviewer model remains catalog-selected deepseek-v4-flash" {
    try std.testing.expectEqualStrings("deepseek-v4-flash", deepseek_models.reviewer_model);
}

test "DeepSeek reviewer builds a direct Chat Completions request with deepseek-v4-flash" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User requested the change." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "call_review",
                .name = "write_file",
                .arguments_json = "{\"path\":\"a.txt\"}",
            }},
        },
        .{ .role = .system, .content = "Review the pending action." },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const body = try responses_reviewer.buildPayloadForTest(
        std.testing.allocator,
        deepseek_models.reviewer_model,
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(@import("../core/shared/io.zig").getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        deepseek.buildReviewRequest,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-v4-flash\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\"}") == null);
    try std.testing.expect(std.mem.find(u8, body, "ai-gateway") == null);
}
