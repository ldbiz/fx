const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const api_key_validator_contract = @import("../core/auth/api_key_validator.zig");

const Allocator = std.mem.Allocator;
const endpoint = "https://api.deepseek.com/chat/completions";
const e2e_endpoint_env = "FX_E2E_DEEPSEEK_CHAT_COMPLETIONS_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_reasoning_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
const models_endpoint = "https://api.deepseek.com/models";
const e2e_models_url_env = "FX_E2E_DEEPSEEK_MODELS_URL";

pub const api_key_validator = api_key_validator_contract.Provider{
    .validate_fn = validateStoredApiKey,
};

fn validateStoredApiKey(
    _: ?*anyopaque,
    alloc: Allocator,
    api_key: []const u8,
) api_key_validator_contract.Result {
    const url = io_mod.getenv(e2e_models_url_env) orelse models_endpoint;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return .unavailable;
    }

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const auth_header = std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key}) catch return .unavailable;
    defer secret.zeroAndFree(alloc, auth_header);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .accept_encoding = .omit,
            .user_agent = .{ .override = gateway_client.user_agent },
        },
        .redirect_behavior = .unhandled,
    }) catch return .unavailable;

    return switch (result.status) {
        .ok => .accepted,
        .unauthorized, .forbidden => .refused,
        else => .unavailable,
    };
}

pub const agent_stream_provider = stream_provider.Provider{ .stream_fn = streamCompletion };

fn validateModel(model: []const u8) !void {
    if (!std.mem.eql(u8, model, "deepseek-v4-flash") and !std.mem.eql(u8, model, "deepseek-v4-pro")) {
        return error.InvalidDeepSeekModel;
    }
}

const ThinkingType = enum {
    enabled,
    disabled,

    fn json(self: ThinkingType) []const u8 {
        return switch (self) {
            .enabled => "enabled",
            .disabled => "disabled",
        };
    }
};

/// Builds DeepSeek's native OpenAI Chat Completions request. `provider_state_json`
/// is deliberately strict: only the DeepSeek reasoning-state array produced by
/// this module can be replayed as `reasoning_content`.
pub fn buildRequest(alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    return buildRequestWithThinking(alloc, request, .enabled);
}

/// Permission review uses `tool_choice=required`, which DeepSeek rejects while
/// thinking is enabled. The main agent stream keeps thinking on.
pub fn buildReviewRequest(alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    return buildRequestWithThinking(alloc, request, .disabled);
}

fn buildRequestWithThinking(alloc: Allocator, request: stream_provider.RequestData, thinking: ThinkingType) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| if (budget.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    };
    if (request.verified_images) |images| if (images.len > 0) return error.DeepSeekVisionUnsupported;
    if (request.vision_mode == .required) return error.DeepSeekVisionUnsupported;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"thinking\":{\"type\":\"");
    try writer.writeAll(thinking.json());
    try writer.writeAll("\"}");
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(mapReasoningEffort(request.model, effort), .{}, writer);
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    try writer.writeAll(",\"messages\":[");
    try writeMessages(writer, alloc, request.messages);
    try writer.writeByte(']');
    const tool_count = try writeTools(writer, alloc, request.tools);
    if (tool_count > 0 and request.tool_choice != .auto) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn mapReasoningEffort(model: []const u8, effort: types.ReasoningEffort) []const u8 {
    const label = effort.label();
    if (std.mem.eql(u8, model, "deepseek-v4-pro")) {
        if (std.mem.eql(u8, label, "xhigh") or std.mem.eql(u8, label, "max")) return "max";
        return "high";
    }
    if (std.mem.eql(u8, label, "minimal") or std.mem.eql(u8, label, "low")) return "low";
    if (std.mem.eql(u8, label, "max")) return "max";
    // Flash maps high and xhigh to high. Unknown future FX labels retain the
    // provider default rather than causing a rejected request.
    return "high";
}

fn writeMessages(writer: *std.Io.Writer, alloc: Allocator, messages: []const types.ChatMessage) !void {
    var first = true;
    for (messages) |message| {
        if (!first) try writer.writeByte(',');
        first = false;
        switch (message.role) {
            .system, .user => {
                try writer.writeAll("{\"role\":");
                try std.json.Stringify.value(@tagName(message.role), .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
            .assistant => {
                try validateAssistantMessage(message);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                if (shouldReplayProviderState(message)) |state_json| {
                    const reasoning = try parseReasoningState(alloc, state_json);
                    defer alloc.free(reasoning);
                    try writer.writeAll(",\"reasoning_content\":");
                    try std.json.Stringify.value(reasoning, .{}, writer);
                } else if (message.tool_calls.len > 0) {
                    // Thinking mode requires this key on replayed tool-call
                    // turns. Synthetic reviewer messages have no provider
                    // state; the API accepts an empty string.
                    try writer.writeAll(",\"reasoning_content\":\"\"");
                }
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, index| {
                        if (index > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn shouldReplayProviderState(message: types.ChatMessage) ?[]const u8 {
    const state = message.provider_state_json orelse return null;
    const owner = message.provider_state_owner orelse return null;
    return if (owner == .deepseek) state else null;
}

fn validateAssistantMessage(message: types.ChatMessage) !void {
    if (message.tool_calls.len > max_tool_calls) return error.DeepSeekToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or call.name.len == 0 or call.name.len > max_tool_identity_bytes) return error.DeepSeekToolCallLimitExceeded;
        if (call.arguments_json.len > max_tool_arguments_bytes) return error.DeepSeekToolArgumentsTooLarge;
    }
}

/// Returns an owned exact copy of the `reasoning_content`; the caller frees it
/// with `alloc`. The parsed document is transient and must not leak its slices.
fn parseReasoningState(alloc: Allocator, state_json: []const u8) ![]u8 {
    if (state_json.len > max_reasoning_bytes) return error.DeepSeekProviderStateTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, state_json, .{}) catch return error.InvalidDeepSeekProviderState;
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len != 1) return error.InvalidDeepSeekProviderState;
    const item = parsed.value.array.items[0];
    if (item != .object or item.object.count() != 2) return error.InvalidDeepSeekProviderState;
    const type_value = item.object.get("type") orelse return error.InvalidDeepSeekProviderState;
    const reasoning_value = item.object.get("reasoning_content") orelse return error.InvalidDeepSeekProviderState;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "deepseek_reasoning") or reasoning_value != .string) return error.InvalidDeepSeekProviderState;
    if (reasoning_value.string.len > max_reasoning_bytes) return error.DeepSeekProviderStateTooLarge;
    return alloc.dupe(u8, reasoning_value.string);
}

fn writeTools(writer: *std.Io.Writer, alloc: Allocator, tools: stream_provider.ToolSelection) !usize {
    var count: usize = 0;
    var scratch: std.Io.Writer.Allocating = .init(alloc);
    defer scratch.deinit();
    try scratch.writer.writeAll(",\"tools\":[");
    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try scratch.writer.writeByte(',');
        try writeFunctionTool(&scratch.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try scratch.writer.writeByte(',');
        try writeFunctionTool(&scratch.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try scratch.writer.writeByte(',');
        try writeFunctionTool(&scratch.writer, alloc, tool.name, tool.description, .{ .dynamic = tool.input_schema });
        count += 1;
    }
    try scratch.writer.writeByte(']');
    if (count > 0) try writer.writeAll(scratch.written());
    return count;
}

const InputSchema = union(enum) { static: model_tool_schema.ObjectSchema, dynamic: std.json.Value };

fn writeFunctionTool(writer: *std.Io.Writer, alloc: Allocator, name: []const u8, description: []const u8, input_schema: InputSchema) !void {
    if (name.len == 0) return error.InvalidToolSchema;
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    if (description.len > 0) {
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, description);
    }
    try writer.writeAll(",\"parameters\":");
    switch (input_schema) {
        .static => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
        .dynamic => |schema| {
            if (schema != .object) return error.InvalidToolSchema;
            try std.json.Stringify.value(schema, .{}, writer);
        },
    }
    try writer.writeAll("}}");
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

fn streamCompletion(_: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source != .deepseek_api_key and request.credential.source != .deepseek_stored_key) return error.DeepSeekApiKeyRequired;
    try validateModel(request.model);
    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    return streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (deadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

fn deadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,
    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }
    fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: []const u8,
    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = self.auth_header }, .accept_encoding = .omit, .user_agent = .{ .override = gateway_client.user_agent } },
            .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

pub fn streamPrepared(alloc: Allocator, request: stream_provider.ModelRequest, payload: []const u8) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, auth_header);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EDeepSeekEndpoint;
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var operation = OpenRequestOperation{ .client = &client, .uri = uri, .auth_header = auth_header };
    var deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(connect_timeout_ms) });
    if (request.deadline) |requested| {
        if (std.Io.Clock.Timestamp.compare(requested, .lt, deadline)) deadline = requested;
    }
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(OpenedRequest, alloc, request.cancel_flag, deadline, &operation);
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const watcher = if (http_request.connection) |connection| if (request.deadline) |requested|
        try gateway_client.spawnHttpCancelWatcherBounded(&cancel_watch_done, request.cancel_flag, requested, connection.stream_writer.stream)
    else
        try gateway_client.spawnHttpCancelWatcher(&cancel_watch_done, request.cancel_flag, connection.stream_writer.stream) else null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) return .{ .failed = .{ .kind = failureKind(response.head.status), .detail = try readErrorBody(alloc, &response), .ownership = .owned } };
    var transfer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer);
    const completion = try consumeSse(alloc, reader, request.events, request.cancel_flag, request.content_capture_limit);
    return .{ .completed = .{ .completion = completion, .usage = .{ .immediate = null }, .ownership = .owned } };
}

fn readErrorBody(alloc: Allocator, response: *std.http.Client.Response) ![]u8 {
    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return try alloc.dupe(u8, "DeepSeek error response exceeded the local limit"),
        else => return err,
    };
    if (body.len <= max_error_body_bytes) return body;
    alloc.free(body);
    return try alloc.dupe(u8, "DeepSeek error response exceeded the local limit");
}

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

const ToolAccumulator = struct {
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,
    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        if (self.id) |v| alloc.free(v);
        if (self.name) |v| alloc.free(v);
        self.arguments.deinit(alloc);
    }
};

const Reducer = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    seen_terminal: bool = false,
    event_count: usize = 0,
    aggregate_bytes: usize = 0,

    fn deinit(self: *Reducer, alloc: Allocator) void {
        self.content.deinit(alloc);
        self.reasoning.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
    }
    fn apply(self: *Reducer, alloc: Allocator, json_text: []const u8, events: stream_provider.EventSink, cancel: *std.atomic.Value(bool), capture_limit: ?usize) !void {
        if (cancel.load(.seq_cst)) return error.Cancelled;
        self.event_count = try boundedAdd(self.event_count, 1, max_sse_events);
        self.aggregate_bytes = try boundedAdd(self.aggregate_bytes, json_text.len, max_sse_aggregate_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidDeepSeekSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDeepSeekSseEvent;
        const choices = parsed.value.object.get("choices") orelse return;
        if (choices != .array) return error.InvalidDeepSeekSseEvent;
        for (choices.array.items) |choice| {
            if (choice != .object) return error.InvalidDeepSeekSseEvent;
            if (choice.object.get("delta")) |delta| try self.applyDelta(alloc, delta, events, capture_limit);
            if (choice.object.get("finish_reason")) |finish_value| if (finish_value == .string and finish_value.string.len > 0) {
                self.finish_reason = parseFinishReason(finish_value.string);
                self.seen_terminal = true;
            };
        }
        if (parsed.value.object.get("usage")) |usage| self.usage = parseUsage(usage);
    }
    fn applyDelta(self: *Reducer, alloc: Allocator, delta: std.json.Value, events: stream_provider.EventSink, capture_limit: ?usize) !void {
        if (delta != .object) return error.InvalidDeepSeekSseEvent;
        if (stringField(delta.object, "reasoning_content")) |chunk| {
            _ = try boundedAdd(self.reasoning.items.len, chunk.len, max_reasoning_bytes);
            try self.reasoning.appendSlice(alloc, chunk);
            events.emit(.{ .reasoning_delta = chunk });
        }
        if (stringField(delta.object, "content")) |chunk| {
            try appendCaptured(alloc, &self.content, chunk, capture_limit);
            events.emit(.{ .content_delta = chunk });
        }
        if (delta.object.get("tool_calls")) |calls| {
            if (calls != .array) return error.InvalidDeepSeekSseEvent;
            for (calls.array.items) |call| try self.applyToolDelta(alloc, call, events);
        }
    }
    fn applyToolDelta(self: *Reducer, alloc: Allocator, value: std.json.Value, events: stream_provider.EventSink) !void {
        if (value != .object) return error.InvalidDeepSeekSseEvent;
        const index = unsignedField(value.object, "index") orelse return error.InvalidDeepSeekSseEvent;
        if (index >= max_tool_calls) return error.DeepSeekToolCallLimitExceeded;
        while (self.tools.items.len <= index) try self.tools.append(alloc, .{});
        var tool = &self.tools.items[index];
        if (stringField(value.object, "id")) |id| {
            if (id.len == 0 or id.len > max_tool_identity_bytes) return error.DeepSeekToolCallLimitExceeded;
            if (tool.id) |existing| {
                if (!std.mem.eql(u8, existing, id)) return error.DeepSeekToolCallLimitExceeded;
            } else tool.id = try alloc.dupe(u8, id);
            emitToolStarted(tool, events);
        }
        if (value.object.get("function")) |function| {
            if (function != .object) return error.InvalidDeepSeekSseEvent;
            if (stringField(function.object, "name")) |name| {
                if (name.len == 0 or name.len > max_tool_identity_bytes) return error.DeepSeekToolCallLimitExceeded;
                if (tool.name) |existing| {
                    if (!std.mem.eql(u8, existing, name)) return error.DeepSeekToolCallLimitExceeded;
                } else tool.name = try alloc.dupe(u8, name);
                emitToolStarted(tool, events);
            }
            if (stringField(function.object, "arguments")) |arguments| {
                _ = try boundedAdd(tool.arguments.items.len, arguments.len, max_tool_arguments_bytes);
                try tool.arguments.appendSlice(alloc, arguments);
                events.emit(.{ .tool_input_delta = arguments });
            }
        }
    }
    fn finish(self: *Reducer, alloc: Allocator, cancel: *std.atomic.Value(bool)) !types.ModelCompletion {
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (!self.seen_terminal) return error.DeepSeekStreamIncomplete;
        var calls = try alloc.alloc(types.ToolCall, self.tools.items.len);
        errdefer alloc.free(calls);
        var initialized: usize = 0;
        errdefer {
            for (calls[0..initialized]) |call| {
                alloc.free(@constCast(call.id));
                alloc.free(@constCast(call.name));
                alloc.free(@constCast(call.arguments_json));
            }
        }
        for (self.tools.items, 0..) |*tool, index| {
            const id = tool.id orelse return error.DeepSeekToolCallLimitExceeded;
            const name = tool.name orelse return error.DeepSeekToolCallLimitExceeded;
            if (tool.arguments.items.len == 0) return error.DeepSeekToolArgumentsTooLarge;
            const integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, tool.arguments.items);
            calls[index] = .{ .id = id, .name = name, .arguments_json = try tool.arguments.toOwnedSlice(alloc), .argument_integrity = integrity };
            tool.id = null;
            tool.name = null;
            initialized += 1;
        }
        const content = try self.content.toOwnedSlice(alloc);
        errdefer alloc.free(content);
        const state = if (self.reasoning.items.len > 0) try reasoningStateJson(alloc, self.reasoning.items) else null;
        return .{ .content = content, .tool_calls = calls, .provider_state_json = state, .finish_reason = self.finish_reason, .usage = self.usage };
    }
};

fn emitToolStarted(tool: *ToolAccumulator, events: stream_provider.EventSink) void {
    if (tool.started) return;
    const id = tool.id orelse return;
    const name = tool.name orelse return;
    events.emit(.{ .tool_started = .{ .id = id, .name = name } });
    tool.started = true;
}

fn reasoningStateJson(alloc: Allocator, reasoning: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("[{\"type\":\"deepseek_reasoning\",\"reasoning_content\":");
    try std.json.Stringify.value(reasoning, .{}, &out.writer);
    try out.writer.writeAll("}]");
    return out.toOwnedSlice();
}
fn boundedAdd(current: usize, extra: usize, max: usize) !usize {
    return responses_protocol.checkedAccumulatedSize(current, extra, max) catch return error.DeepSeekResourceLimitExceeded;
}
fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?usize {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(usize, value.integer);
}
fn parseUsage(value: std.json.Value) types.Usage {
    if (value != .object) return .{};
    return .{ .input_tokens = unsignedU64(value.object, "prompt_tokens"), .output_tokens = unsignedU64(value.object, "completion_tokens") };
}
fn unsignedU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}
fn parseFinishReason(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return .other;
}
fn appendCaptured(alloc: Allocator, content: *std.ArrayList(u8), chunk: []const u8, limit: ?usize) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else chunk.len;
    try content.appendSlice(alloc, chunk[0..@min(chunk.len, remaining)]);
}

const SseReader = struct {
    pending: std.ArrayList(u8) = .empty,
    aggregate: usize = 0,
    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending.deinit(alloc);
    }
    fn clear(self: *SseReader) void {
        self.pending.clearRetainingCapacity();
    }
    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            defer self.clear();
            self.aggregate = try boundedAdd(self.aggregate, line.len + 1, max_sse_aggregate_bytes);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':' or !std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed[5..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }
    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.DeepSeekSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending.items.len) return error.DeepSeekSseEventTooLarge;
                    try self.pending.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                else => return err,
            } orelse {
                if (self.pending.items.len == 0) return null;
                return self.pending.items;
            };
            if (fragment.len > max_sse_line_bytes - self.pending.items.len) return error.DeepSeekSseEventTooLarge;
            if (self.pending.items.len == 0) return fragment;
            try self.pending.appendSlice(alloc, fragment);
            return self.pending.items;
        }
    }
};

fn consumeSse(alloc: Allocator, reader: anytype, events: stream_provider.EventSink, cancel: *std.atomic.Value(bool), capture_limit: ?usize) !types.ModelCompletion {
    var reducer: Reducer = .{};
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    while (try sse.next(alloc, reader)) |data| {
        try reducer.apply(alloc, data, events, cancel, capture_limit);
    }
    return reducer.finish(alloc, cancel);
}

test "DeepSeek request uses direct Chat Completions messages tools and reasoning continuity" {
    const tool = model_tool_schema.FunctionSchema{ .name = "read_file", .description = "Read", .input_schema = .{} };
    const messages = [_]types.ChatMessage{ .{ .role = .system, .content = "Concise." }, .{ .role = .user, .content = "Read it." }, .{ .role = .assistant, .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }}, .provider_state_owner = .deepseek, .provider_state_json = "[{\"type\":\"deepseek_reasoning\",\"reasoning_content\":\"think exactly\"}]" }, .{ .role = .tool, .tool_call_id = "call_1", .content = "contents" } };
    const body = try buildRequest(std.testing.allocator, .{ .model = "deepseek-v4-flash", .messages = &messages, .tools = .{ .additional_functions = &.{tool} }, .tool_choice = .auto, .provider_options = .{ .reasoning = types.ReasoningEffort.literal("xhigh") } });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_content\":\"think exactly\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"assistant\",\"content\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\"") == null);
}

test "DeepSeek request emits tool_choice when tools are present and choice is required" {
    const tool = model_tool_schema.FunctionSchema{ .name = "read_file", .description = "Read", .input_schema = .{} };
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Read it." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{tool} },
        .tool_choice = .required,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
}

test "DeepSeek maps reasoning effort by V4 model" {
    const cases = [_]struct {
        model: []const u8,
        effort: types.ReasoningEffort,
        expected: []const u8,
    }{
        .{ .model = "deepseek-v4-flash", .effort = types.ReasoningEffort.literal("low"), .expected = "low" },
        .{ .model = "deepseek-v4-flash", .effort = types.ReasoningEffort.literal("high"), .expected = "high" },
        .{ .model = "deepseek-v4-flash", .effort = types.ReasoningEffort.literal("xhigh"), .expected = "high" },
        .{ .model = "deepseek-v4-flash", .effort = types.ReasoningEffort.literal("max"), .expected = "max" },
        .{ .model = "deepseek-v4-pro", .effort = types.ReasoningEffort.literal("low"), .expected = "high" },
        .{ .model = "deepseek-v4-pro", .effort = types.ReasoningEffort.literal("high"), .expected = "high" },
        .{ .model = "deepseek-v4-pro", .effort = types.ReasoningEffort.literal("xhigh"), .expected = "max" },
        .{ .model = "deepseek-v4-pro", .effort = types.ReasoningEffort.literal("max"), .expected = "max" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, mapReasoningEffort(case.model, case.effort));
    }
}

test "DeepSeek rejects malformed provider reasoning state" {
    const messages = [_]types.ChatMessage{.{ .role = .assistant, .content = "x", .provider_state_owner = .deepseek, .provider_state_json = "[{\"type\":\"deepseek_reasoning\",\"reasoning_content\":\"x\"},{\"type\":\"deepseek_reasoning\",\"reasoning_content\":\"y\"}]" }};
    try std.testing.expectError(error.InvalidDeepSeekProviderState, buildRequest(std.testing.allocator, .{ .model = "deepseek-v4-pro", .messages = &messages, .tool_choice = .none, .provider_options = .{} }));
}

test "DeepSeek request emits empty reasoning_content for tool calls without provider state" {
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "call_review",
            .name = "write_file",
            .arguments_json = "{\"path\":\"a.txt\"}",
        }},
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "deepseek_reasoning") == null);
}

test "DeepSeek emits empty reasoning_content for tool calls with foreign provider state" {
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "call_1",
            .name = "read_file",
            .arguments_json = "{\"path\":\"README.md\"}",
        }},
        .provider_state_owner = .codex,
        .provider_state_json = "not even JSON",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_content\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "not even JSON") == null);
}

test "DeepSeek review request disables thinking while keeping empty reasoning_content" {
    const tool = model_tool_schema.FunctionSchema{ .name = "permission_decision", .description = "Review", .input_schema = .{} };
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "call_review",
            .name = "write_file",
            .arguments_json = "{\"path\":\"a.txt\"}",
        }},
    }};
    const body = try buildReviewRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{tool} },
        .tool_choice = .required,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\"}") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_content\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
}

test "DeepSeek ignores foreign provider state without parsing or emitting it" {
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .content = "x",
        .provider_state_owner = .codex,
        .provider_state_json = "not even JSON",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-pro",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "reasoning_content") == null);
    try std.testing.expect(std.mem.find(u8, body, "not even JSON") == null);
}

test "DeepSeek SSE preserves interleaved reasoning content tools and usage" {
    const bytes = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{\"reasoning_content\":\"more\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\n";
    var reader: std.Io.Reader = .fixed(bytes);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        reasoning: std.ArrayList(u8) = .empty,
        content: std.ArrayList(u8) = .empty,
        tool_starts: usize = 0,
        tool_input: std.ArrayList(u8) = .empty,
        failed: bool = false,

        fn deinit(self: *@This()) void {
            self.reasoning.deinit(std.testing.allocator);
            self.content.deinit(std.testing.allocator);
            self.tool_input.deinit(std.testing.allocator);
        }

        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .reasoning_delta => |chunk| self.reasoning.appendSlice(std.testing.allocator, chunk) catch {
                    self.failed = true;
                },
                .content_delta => |chunk| self.content.appendSlice(std.testing.allocator, chunk) catch {
                    self.failed = true;
                },
                .tool_started => self.tool_starts += 1,
                .tool_input_delta => |chunk| self.tool_input.appendSlice(std.testing.allocator, chunk) catch {
                    self.failed = true;
                },
            }
        }
    };
    var capture: Capture = .{};
    defer capture.deinit();
    const completion = try consumeSse(std.testing.allocator, &reader, .{ .context = &capture, .emit_fn = Capture.emit }, &cancelled, null);
    defer {
        if (completion.content) |v| std.testing.allocator.free(@constCast(v));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.provider_state_json) |v| std.testing.allocator.free(@constCast(v));
    }
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("[{\"type\":\"deepseek_reasoning\",\"reasoning_content\":\"think more\"}]", completion.provider_state_json.?);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.input_tokens);
    try std.testing.expect(!capture.failed);
    try std.testing.expectEqualStrings("think more", capture.reasoning.items);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_starts);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", capture.tool_input.items);
}
