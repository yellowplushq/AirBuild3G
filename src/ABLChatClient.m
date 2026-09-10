#import "ABLChatClient.h"
#import "ABLTrustAll.h"
#import "ABLConfig.h"
#import "ABLJSONParser.h"
#import "ABLTools.h"

#include <stdio.h>
#include <string.h>

static const NSUInteger ABLMaximumResponseBytes = 4 * 1024 * 1024;
static const NSUInteger ABLMaximumToolCallIndex = 32;

static NSString *ABLThinkingOpenTag = @"<think>";
static NSString *ABLThinkingCloseTag = @"</think>";
static NSString *ABLToolCallOpenTag = @"<tool_call>";
static NSString *ABLToolCallCloseTag = @"</tool_call>";

static NSString *ABLSetting(NSString *key, NSString *fallback) {
	NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:key];
	value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return [value length] > 0 ? value : fallback;
}

static NSString *ABLTrimmed(NSString *string) {
	return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Length of the trailing run of `text` that could still grow into `tag`, so a
// tag split across two stream packets is never emitted as ordinary text.
static NSUInteger ABLPartialTagLength(NSString *text, NSString *tag) {
	NSUInteger longest = MIN([text length], [tag length] - 1);
	for (NSUInteger length = longest; length > 0; length--) {
		if ([tag hasPrefix:[text substringFromIndex:[text length] - length]]) {
			return length;
		}
	}
	return 0;
}

static NSString *ABLToolsJSON = ABLToolsJSONLiteral;

// The request body is built straight into UTF-8 bytes rather than assembled as
// a string and converted at the end. A turn carries up to twenty messages and
// an exec result may be 64 KB, so the string route had the whole conversation
// in flight four times over — once as an NSMutableString (UTF-16, twice the
// bytes), once as the escaped copy of it, once as the NSData that
// -dataUsingEncoding: made, and once as the copy NSURLRequest takes. On a
// phone with 128 MB and no swap that is the largest allocation the app makes,
// and it happens on the main thread on every send. Appending bytes as they are
// produced leaves only the finished body.
#define ABLAppendLiteral(out, literal) [(out) appendBytes:(literal) length:sizeof(literal) - 1]

// `range` of `string` as UTF-8, through a fixed buffer, allocating nothing.
static void ABLAppendUTF8Range(NSMutableData *out, NSString *string, NSRange range) {
	unsigned char buffer[4096];
	while (range.length > 0) {
		NSUInteger used = 0;
		NSRange remaining = NSMakeRange(NSMaxRange(range), 0);
		[string getBytes:buffer maxLength:sizeof(buffer) usedLength:&used
			encoding:NSUTF8StringEncoding options:0 range:range remainingRange:&remaining];
		if (used == 0) {
			// An unpaired surrogate — a character the reply splitter cut in
			// half — cannot be encoded. Step over it: losing one character is
			// better than losing the rest of the message, and stopping here
			// would truncate the body mid-string and make the JSON invalid.
			range = NSMakeRange(range.location + 1, range.length - 1);
			continue;
		}
		[out appendBytes:buffer length:used];
		range = remaining;
	}
}

// iOS 4 has no JSON writer either; strings are the only thing we need to escape.
// Runs that need no escaping are handed to ABLAppendUTF8Range whole, so the
// per-character work is a comparison rather than an -appendFormat:.
static void ABLAppendJSONString(NSMutableData *out, NSString *string) {
	ABLAppendLiteral(out, "\"");
	NSUInteger length = [string length];
	unichar chunk[256];
	NSUInteger plainStart = 0;
	for (NSUInteger base = 0; base < length; base += 256) {
		NSUInteger count = MIN((NSUInteger)256, length - base);
		[string getCharacters:chunk range:NSMakeRange(base, count)];
		for (NSUInteger i = 0; i < count; i++) {
			unichar c = chunk[i];
			if (c >= 0x20 && c != '"' && c != '\\') {
				continue;
			}
			// Every character that needs escaping is ASCII, so a run never
			// ends in the middle of a surrogate pair.
			NSUInteger at = base + i;
			if (at > plainStart) {
				ABLAppendUTF8Range(out, string, NSMakeRange(plainStart, at - plainStart));
			}
			switch (c) {
				case '"': ABLAppendLiteral(out, "\\\""); break;
				case '\\': ABLAppendLiteral(out, "\\\\"); break;
				case '\n': ABLAppendLiteral(out, "\\n"); break;
				case '\r': ABLAppendLiteral(out, "\\r"); break;
				case '\t': ABLAppendLiteral(out, "\\t"); break;
				default: {
					char escape[8];
					snprintf(escape, sizeof(escape), "\\u%04x", (unsigned)c);
					[out appendBytes:escape length:6];
					break;
				}
			}
			plainStart = at + 1;
		}
	}
	if (length > plainStart) {
		ABLAppendUTF8Range(out, string, NSMakeRange(plainStart, length - plainStart));
	}
	ABLAppendLiteral(out, "\"");
}

// A parsed JSON value written back out. Only the markup path needs this — a
// model that expressed its call as <tool_call>{"name":…,"arguments":{…}}</…>
// hands over the arguments as an object, and every tool below Execute has more
// than one of them, so pulling out a single "command" key and rebuilding the
// string around it lost the rest of the call.
static void ABLAppendJSONValue(NSMutableData *out, id value) {
	if ([value isKindOfClass:[NSString class]]) {
		ABLAppendJSONString(out, value);
	} else if ([value isKindOfClass:[NSDictionary class]]) {
		ABLAppendLiteral(out, "{");
		NSUInteger index = 0;
		for (id key in value) {
			if (index++ > 0) {
				ABLAppendLiteral(out, ",");
			}
			ABLAppendJSONString(out, [key description]);
			ABLAppendLiteral(out, ":");
			ABLAppendJSONValue(out, [value objectForKey:key]);
		}
		ABLAppendLiteral(out, "}");
	} else if ([value isKindOfClass:[NSArray class]]) {
		ABLAppendLiteral(out, "[");
		NSUInteger index = 0;
		for (id element in value) {
			if (index++ > 0) {
				ABLAppendLiteral(out, ",");
			}
			ABLAppendJSONValue(out, element);
		}
		ABLAppendLiteral(out, "]");
	} else if ([value isKindOfClass:[NSNumber class]]) {
		// The parser hands booleans back as NSNumber, and "true" is not "1"
		// to a server reading replace_all.
		if (strcmp([value objCType], @encode(BOOL)) == 0) {
			if ([value boolValue]) {
				ABLAppendLiteral(out, "true");
			} else {
				ABLAppendLiteral(out, "false");
			}
		} else {
			NSString *number = [value stringValue];
			ABLAppendUTF8Range(out, number, NSMakeRange(0, [number length]));
		}
	} else {
		ABLAppendLiteral(out, "null");
	}
}

// A parsed value as a JSON string. Short values only — a tool call's
// arguments, never a transcript.
static NSString *ABLJSONFromObject(id value) {
	NSMutableData *out = [NSMutableData data];
	ABLAppendJSONValue(out, value);
	return [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] autorelease];
}

// iOS 4 has no base64 in Foundation. Encoded in place, four output bytes at a
// time: a 640-pixel photo is around 60 KB, and the string form of its base64
// was another 160 KB of UTF-16 on top of the copy inside the body.
static void ABLAppendBase64(NSMutableData *out, NSData *data) {
	static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	const unsigned char *bytes = [data bytes];
	NSUInteger length = [data length];
	char buffer[4096];   // a multiple of 4, so a quantum never straddles a flush
	NSUInteger fill = 0;
	NSUInteger i;
	for (i = 0; i + 2 < length; i += 3) {
		unsigned v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
		buffer[fill++] = table[(v >> 18) & 63]; buffer[fill++] = table[(v >> 12) & 63];
		buffer[fill++] = table[(v >> 6) & 63]; buffer[fill++] = table[v & 63];
		if (fill + 4 > sizeof(buffer)) {
			[out appendBytes:buffer length:fill];
			fill = 0;
		}
	}
	if (i < length) {
		unsigned v = bytes[i] << 16;
		if (i + 1 < length) {
			v |= bytes[i + 1] << 8;
		}
		buffer[fill++] = table[(v >> 18) & 63]; buffer[fill++] = table[(v >> 12) & 63];
		buffer[fill++] = i + 1 < length ? table[(v >> 6) & 63] : '=';
		buffer[fill++] = '=';
	}
	if (fill > 0) {
		[out appendBytes:buffer length:fill];
	}
}

// Serializes one transcript row. Every field is already a string: the rows are
// built by ABLChatViewController from -frozenToolCalls below, which is the one
// place tool-call shapes are normalized.
static void ABLAppendJSONForMessage(NSMutableData *out, NSDictionary *message) {
	ABLAppendLiteral(out, "{\"role\":");
	ABLAppendJSONString(out, [message objectForKey:@"role"]);

	NSString *content = [message objectForKey:@"content"];
	NSArray *toolCalls = [message objectForKey:@"tool_calls"];
	NSData *image = [message objectForKey:@"image"];
	if ([image isKindOfClass:[NSData class]]) {
		// A photo rides along as an OpenAI-style content part list.
		ABLAppendLiteral(out, ",\"content\":[");
		if ([content length] > 0) {
			ABLAppendLiteral(out, "{\"type\":\"text\",\"text\":");
			ABLAppendJSONString(out, content);
			ABLAppendLiteral(out, "},");
		}
		ABLAppendLiteral(out, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,");
		ABLAppendBase64(out, image);
		ABLAppendLiteral(out, "\"}}]");
	} else if ([content length] > 0) {
		ABLAppendLiteral(out, ",\"content\":");
		ABLAppendJSONString(out, content);
	} else if ([toolCalls count] > 0) {
		ABLAppendLiteral(out, ",\"content\":null");
	} else {
		ABLAppendLiteral(out, ",\"content\":\"\"");
	}

	NSString *callId = [message objectForKey:@"tool_call_id"];
	if ([callId length] > 0) {
		ABLAppendLiteral(out, ",\"tool_call_id\":");
		ABLAppendJSONString(out, callId);
	}
	NSString *name = [message objectForKey:@"name"];
	if ([name length] > 0) {
		ABLAppendLiteral(out, ",\"name\":");
		ABLAppendJSONString(out, name);
	}
	if ([toolCalls count] > 0) {
		ABLAppendLiteral(out, ",\"tool_calls\":[");
		NSUInteger index = 0;
		for (NSDictionary *call in toolCalls) {
			if (index++ > 0) {
				ABLAppendLiteral(out, ",");
			}
			ABLAppendLiteral(out, "{\"id\":");
			ABLAppendJSONString(out, [call objectForKey:@"id"]);
			ABLAppendLiteral(out, ",\"type\":\"function\",\"function\":{\"name\":");
			ABLAppendJSONString(out, [call objectForKey:@"name"]);
			ABLAppendLiteral(out, ",\"arguments\":");
			ABLAppendJSONString(out, [call objectForKey:@"arguments"]);
			ABLAppendLiteral(out, "}}");
		}
		ABLAppendLiteral(out, "]");
	}
	ABLAppendLiteral(out, "}");
}

// Byte offset of the blank line that ends an event. Searching the bytes keeps
// the cost proportional to what arrived, instead of decoding the whole
// unconsumed buffer again on every packet.
static NSUInteger ABLEventSeparatorIndex(NSData *data) {
	const char *bytes = (const char *)[data bytes];
	NSUInteger length = [data length];
	for (NSUInteger i = 0; i + 1 < length; i++) {
		if (bytes[i] == '\n' && bytes[i + 1] == '\n') {
			return i;
		}
	}
	return NSNotFound;
}

// How often a running stream checks whether its generation is still the one
// the app wants. The connection also wakes the loop, so this is only the
// upper bound on noticing a cancel.
static const NSTimeInterval ABLCancelPollInterval = 0.25;

@interface ABLChatClient ()

- (BOOL)isGenerationCurrent:(NSUInteger)generation;
- (void)deliverThinking:(NSDictionary *)event;
- (void)deliverToken:(NSDictionary *)event;
- (void)deliverToolCalls:(NSDictionary *)event;
- (void)deliverFailure:(NSDictionary *)event;

@end

// One request, on one thread, owning every byte of its own state. Nothing here
// is shared with the main thread except the finished tokens it hands over, so
// abandoning a stream never has to reach into it and tear it down.
@interface ABLChatStream : NSObject {
	ABLChatClient *_client;
	NSUInteger _generation;
	NSURLRequest *_request;
	NSURLConnection *_connection;
	NSMutableData *_responseData;
	NSMutableString *_pendingText;
	NSMutableArray *_toolCalls;
	NSInteger _statusCode;
	BOOL _inThinking;
	BOOL _inToolCall;
	BOOL _startedReply;
	BOOL _finished;
}

- (id)initWithRequest:(NSURLRequest *)request client:(ABLChatClient *)client generation:(NSUInteger)generation;
- (void)run;

@end

@implementation ABLChatStream

- (id)initWithRequest:(NSURLRequest *)request client:(ABLChatClient *)client generation:(NSUInteger)generation {
	self = [super init];
	if (self != nil) {
		// The client outlives every stream it starts, so delivering to it from
		// this thread is always safe.
		_client = [client retain];
		_generation = generation;
		_request = [request retain];
		_responseData = [[NSMutableData alloc] init];
		_pendingText = [[NSMutableString alloc] init];
		_toolCalls = [[NSMutableArray alloc] init];
	}
	return self;
}

#pragma mark - Delivery

// Queued, never waited on: the transcript decides for itself how often to
// redraw, so this thread's only job is to keep reading the socket. Common
// modes, so tokens keep arriving while the transcript is scrolled.
- (void)handOff:(SEL)selector value:(id)value {
	[_client performSelectorOnMainThread:selector
		withObject:[NSDictionary dictionaryWithObjectsAndKeys:
			value, @"value",
			[NSNumber numberWithUnsignedInteger:_generation], @"generation", nil]
		waitUntilDone:NO modes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
}

- (void)emitThinking:(NSString *)text {
	if ([text length] > 0) {
		[self handOff:@selector(deliverThinking:) value:text];
	}
}

- (void)emitContent:(NSString *)text {
	if ([text length] > 0) {
		[self handOff:@selector(deliverToken:) value:text];
	}
}

// The first failure ends the stream. A connection that is still delivering
// when the limit is hit would otherwise report the same failure once per
// packet, and the delegate raises an alert for each one.
- (void)failWithMessage:(NSString *)message {
	if (_finished) {
		return;
	}
	_finished = YES;
	[self handOff:@selector(deliverFailure:) value:message];
}

#pragma mark - Reply splitting

// Models express reasoning and tool calls either through dedicated stream
// fields or, on this endpoint's Qwen builds, as <think> and <tool_call> markup
// inside the reply text. Both spellings are resolved here, while the text is
// still a stream, so the markup never reaches the transcript and never gets
// echoed back to the model as assistant content beside the structured call.
- (void)emitText:(NSString *)text {
	[_pendingText appendString:text];
	while ([_pendingText length] > 0) {
		if (_inThinking) {
			NSRange close = [_pendingText rangeOfString:ABLThinkingCloseTag];
			if (close.location == NSNotFound) {
				NSUInteger hold = ABLPartialTagLength(_pendingText, ABLThinkingCloseTag);
				NSRange emit = NSMakeRange(0, [_pendingText length] - hold);
				[self emitThinking:[_pendingText substringWithRange:emit]];
				[_pendingText deleteCharactersInRange:emit];
				return;
			}
			[self emitThinking:[_pendingText substringToIndex:close.location]];
			[_pendingText deleteCharactersInRange:NSMakeRange(0, close.location + close.length)];
			_inThinking = NO;
			continue;
		}

		if (_inToolCall) {
			NSRange close = [_pendingText rangeOfString:ABLToolCallCloseTag];
			if (close.location == NSNotFound) {
				return; // hold the whole call until it is complete
			}
			[self consumeToolCallMarkup:ABLTrimmed([_pendingText substringToIndex:close.location])];
			[_pendingText deleteCharactersInRange:NSMakeRange(0, close.location + close.length)];
			_inToolCall = NO;
			continue;
		}

		if (!_startedReply) {
			// Only the whitespace before the reply starts is dropped. Trimming
			// the other end here would make the output depend on where the
			// stream happened to be cut into packets.
			NSRange first = [_pendingText rangeOfCharacterFromSet:
				[[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet]];
			if (first.location == NSNotFound) {
				[_pendingText setString:@""];
				return;
			}
			[_pendingText deleteCharactersInRange:NSMakeRange(0, first.location)];
			if ([_pendingText hasPrefix:ABLThinkingOpenTag]) {
				[_pendingText deleteCharactersInRange:NSMakeRange(0, [ABLThinkingOpenTag length])];
				_inThinking = YES;
				continue;
			}
			if ([ABLThinkingOpenTag hasPrefix:_pendingText]) {
				return; // could still become a think tag
			}
			_startedReply = YES;
		}

		NSRange open = [_pendingText rangeOfString:ABLToolCallOpenTag];
		if (open.location != NSNotFound) {
			[self emitContent:[_pendingText substringToIndex:open.location]];
			[_pendingText deleteCharactersInRange:NSMakeRange(0, open.location + open.length)];
			_inToolCall = YES;
			continue;
		}
		NSUInteger hold = ABLPartialTagLength(_pendingText, ABLToolCallOpenTag);
		NSRange emit = NSMakeRange(0, [_pendingText length] - hold);
		[self emitContent:[_pendingText substringWithRange:emit]];
		[_pendingText deleteCharactersInRange:emit];
		return;
	}
}

// End of stream: whatever was held back waiting for a tag that never closed is
// surfaced rather than dropped.
- (void)flushPendingText {
	if ([_pendingText length] == 0) {
		return;
	}
	NSString *rest = [[_pendingText copy] autorelease];
	[_pendingText setString:@""];
	if (_inThinking) {
		[self emitThinking:rest];
		return;
	}
	_inToolCall = NO;
	_startedReply = YES;
	[self emitContent:rest];
}

#pragma mark - Tool calls

- (NSMutableDictionary *)toolCallSlotAtIndex:(NSUInteger)index {
	while ([_toolCalls count] <= index) {
		NSMutableDictionary *slot = [NSMutableDictionary dictionary];
		[slot setObject:[NSString stringWithFormat:@"call_%lu", (unsigned long)[_toolCalls count]] forKey:@"id"];
		[slot setObject:@"Execute" forKey:@"name"];
		[slot setObject:[NSMutableString string] forKey:@"arguments"];
		[_toolCalls addObject:slot];
	}
	return [_toolCalls objectAtIndex:index];
}

- (void)mergeToolCallDelta:(NSDictionary *)call {
	if (![call isKindOfClass:[NSDictionary class]]) {
		return;
	}
	NSUInteger index = 0;
	id indexValue = [call objectForKey:@"index"];
	if ([indexValue respondsToSelector:@selector(unsignedIntegerValue)]) {
		index = [indexValue unsignedIntegerValue];
	}
	if (index > ABLMaximumToolCallIndex) {
		return;
	}
	NSMutableDictionary *slot = [self toolCallSlotAtIndex:index];
	NSString *callId = [call objectForKey:@"id"];
	if ([callId isKindOfClass:[NSString class]] && [callId length] > 0) {
		[slot setObject:callId forKey:@"id"];
	}
	NSDictionary *function = [call objectForKey:@"function"];
	if (![function isKindOfClass:[NSDictionary class]]) {
		return;
	}
	NSString *name = [function objectForKey:@"name"];
	if ([name isKindOfClass:[NSString class]] && [name length] > 0) {
		[slot setObject:name forKey:@"name"];
	}
	NSString *arguments = [function objectForKey:@"arguments"];
	if ([arguments isKindOfClass:[NSString class]] && [arguments length] > 0) {
		[(NSMutableString *)[slot objectForKey:@"arguments"] appendString:arguments];
	}
}

// The body of one <tool_call> block: a JSON object naming the tool, with the
// arguments given either as a JSON string or as an inline object.
- (void)consumeToolCallMarkup:(NSString *)inner {
	NSMutableDictionary *slot = [self toolCallSlotAtIndex:[_toolCalls count]];
	NSString *arguments = inner;
	id object = [ABLJSONParser objectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding] errorDescription:NULL];
	if ([object isKindOfClass:[NSDictionary class]]) {
		NSString *name = [object objectForKey:@"name"];
		if ([name isKindOfClass:[NSString class]] && [name length] > 0) {
			[slot setObject:name forKey:@"name"];
		}
		id parsedArguments = [object objectForKey:@"arguments"];
		if ([parsedArguments isKindOfClass:[NSString class]]) {
			arguments = parsedArguments;
		} else if ([parsedArguments isKindOfClass:[NSDictionary class]]) {
			arguments = ABLJSONFromObject(parsedArguments);
		}
	}
	[(NSMutableString *)[slot objectForKey:@"arguments"] appendString:arguments];
}

// The one place tool calls become the shape the rest of the app relies on:
// every entry has a non-empty id and name and a string arguments payload.
- (NSArray *)frozenToolCalls {
	NSMutableArray *frozen = [NSMutableArray array];
	for (NSDictionary *call in _toolCalls) {
		NSString *arguments = [call objectForKey:@"arguments"];
		if ([arguments length] == 0) {
			continue;
		}
		[frozen addObject:[NSDictionary dictionaryWithObjectsAndKeys:
			[[[call objectForKey:@"id"] copy] autorelease], @"id",
			[[[call objectForKey:@"name"] copy] autorelease], @"name",
			[[arguments copy] autorelease], @"arguments", nil]];
	}
	return frozen;
}

#pragma mark - Stream decoding

- (void)handlePiece:(NSDictionary *)piece {
	NSString *reasoning = [piece objectForKey:@"reasoning_content"];
	if (![reasoning isKindOfClass:[NSString class]]) {
		reasoning = [piece objectForKey:@"reasoning"];
	}
	if ([reasoning isKindOfClass:[NSString class]]) {
		[self emitThinking:reasoning];
	}
	NSString *content = [piece objectForKey:@"content"];
	if ([content isKindOfClass:[NSString class]]) {
		[self emitText:content];
	}
	NSArray *toolCalls = [piece objectForKey:@"tool_calls"];
	if ([toolCalls isKindOfClass:[NSArray class]]) {
		for (NSDictionary *call in toolCalls) {
			[self mergeToolCallDelta:call];
		}
	}
}

- (void)handleEvent:(NSString *)event {
	// One SSE event: "data: {...}" lines (a JSON object) or "data: [DONE]".
	NSMutableString *payload = [NSMutableString string];
	for (NSString *line in [event componentsSeparatedByString:@"\n"]) {
		if ([line hasPrefix:@"data:"]) {
			NSString *value = [line substringFromIndex:5];
			if ([value hasPrefix:@" "]) {
				value = [value substringFromIndex:1];
			}
			[payload appendString:value];
		}
	}
	if ([payload length] == 0 || [payload isEqualToString:@"[DONE]"]) {
		return;
	}
	id object = [ABLJSONParser objectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] errorDescription:NULL];
	if (![object isKindOfClass:[NSDictionary class]]) {
		return;
	}
	NSArray *choices = [object objectForKey:@"choices"];
	if (![choices isKindOfClass:[NSArray class]] || [choices count] == 0) {
		return;
	}
	NSDictionary *delta = [[choices objectAtIndex:0] objectForKey:@"delta"];
	if ([delta isKindOfClass:[NSDictionary class]]) {
		[self handlePiece:delta];
	}
}

- (void)drainEventsFinal:(BOOL)final {
	while (YES) {
		NSUInteger separator = ABLEventSeparatorIndex(_responseData);
		NSUInteger eventLength;
		NSUInteger consumed;
		if (separator != NSNotFound) {
			eventLength = separator;
			consumed = separator + 2;
		} else if (final && [_responseData length] > 0) {
			eventLength = [_responseData length];
			consumed = eventLength;
		} else {
			return;
		}
		NSData *eventData = [_responseData subdataWithRange:NSMakeRange(0, eventLength)];
		[_responseData replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
		NSString *event = [[[NSString alloc] initWithData:eventData encoding:NSUTF8StringEncoding] autorelease];
		if (event != nil) {
			[self handleEvent:event];
		}
	}
}

#pragma mark - The stream's own thread

- (void)run {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	_connection = [[NSURLConnection alloc] initWithRequest:_request delegate:self startImmediately:NO];
	if (_connection == nil) {
		[self failWithMessage:@"The request could not be started."];
	} else {
		[_connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		[_connection start];
		while (!_finished && [_client isGenerationCurrent:_generation]) {
			NSAutoreleasePool *iteration = [[NSAutoreleasePool alloc] init];
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:ABLCancelPollInterval]];
			[iteration release];
		}
		[_connection cancel];
	}
	[pool release];
}

#pragma mark - NSURLConnection delegate

// Only claimed when the owner has asked for it. Answering NO leaves the
// challenge to Foundation, which evaluates the chain the ordinary way — which
// is what should happen to a request carrying someone's API key.
- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)space {
	return ABLTrustAnyCertificate()
		&& [[space authenticationMethod] isEqualToString:NSURLAuthenticationMethodServerTrust];
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	// Reached only with Trust Any Certificate on: accept what was presented.
	[[challenge sender] useCredential:[NSURLCredential credentialForTrust:[[challenge protectionSpace] serverTrust]]
		forAuthenticationChallenge:challenge];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
		_statusCode = [(NSHTTPURLResponse *)response statusCode];
	}
	[_responseData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	if (_finished) {
		return;
	}
	if ([_responseData length] + [data length] > ABLMaximumResponseBytes) {
		[self failWithMessage:@"The server response is too large."];
		return;
	}
	[_responseData appendData:data];
	if (_statusCode >= 200 && _statusCode < 300) {
		[self drainEventsFinal:NO];
	}
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	[self failWithMessage:[NSString stringWithFormat:@"Could not reach the server: %@", [error localizedDescription]]];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	if (_finished) {
		return; // already failed; the connection is cancelled on the next pass
	}
	if (_statusCode < 200 || _statusCode >= 300) {
		id object = [ABLJSONParser objectWithData:_responseData errorDescription:NULL];
		NSDictionary *error = [object isKindOfClass:[NSDictionary class]] ? [object objectForKey:@"error"] : nil;
		NSString *code = [error isKindOfClass:[NSDictionary class]] ? [error objectForKey:@"code"] : nil;
		NSString *message = [error isKindOfClass:[NSDictionary class]] ? [error objectForKey:@"message"] : nil;
		// 401 is the one the owner can act on, and the provider's own wording
		// for it ("invalid x-api-key") does not say where to go on a phone.
		if (_statusCode == 401 || _statusCode == 403 ||
				([code isKindOfClass:[NSString class]] && [code isEqualToString:@"authentication_error"])) {
			message = @"The endpoint rejected the API key. Check it in Settings.";
		}
		if (![message isKindOfClass:[NSString class]] || [message length] == 0) {
			message = @"The server could not complete the request. Try again in a moment.";
		}
		[self failWithMessage:message];
		return;
	}
	[self drainEventsFinal:YES];
	[self flushPendingText];
	_finished = YES;
	[self handOff:@selector(deliverToolCalls:) value:[self frozenToolCalls]];
}

- (void)dealloc {
	[_connection cancel];
	[_connection release];
	[_toolCalls release];
	[_pendingText release];
	[_responseData release];
	[_request release];
	[_client release];
	[super dealloc];
}

@end

@implementation ABLChatClient {
	id<ABLChatClientDelegate> _delegate;
	// Bumped on the main thread for every send and every cancel. A stream
	// whose generation is no longer current stops itself, and anything it
	// already handed to the main thread is dropped on arrival.
	volatile NSUInteger _generation;
}

@synthesize delegate = _delegate;

- (void)sendMessages:(NSArray *)messages {
	_generation++;

	NSString *base = ABLSetting(ABLDefaultsAPIBaseKey, ABLDefaultAPIBase);
	while ([base hasSuffix:@"/"]) {
		base = [base substringToIndex:[base length] - 1];
	}
	NSURL *URL = [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
	if (URL == nil || [URL host] == nil) {
		[_delegate chatClient:self didFailWithMessage:
			@"That is not a valid endpoint address. Fix Base URL in Settings."];
		return;
	}
	NSString *key = ABLSetting(ABLDefaultsAPIKeyKey, nil);
	if ([key length] == 0) {
		// Said here rather than blocked at launch: the transcript is where the
		// person already is, and Settings is one tap from it.
		[_delegate chatClient:self didFailWithMessage:
			@"No API key yet. Open Settings and put one in."];
		return;
	}
	NSString *model = ABLSetting(ABLDefaultsModelKey, ABLDefaultModel);

	ABLLoadTLSFix(); // installed since launch? pick it up now

	// Serialized here, on the caller's thread, so the transcript rows are read
	// while the caller still owns them. Straight into bytes, and each message
	// released as it is written, so the peak is the body itself rather than
	// several copies of the conversation at once.
	NSMutableData *body = [NSMutableData dataWithCapacity:16 * 1024];
	ABLAppendLiteral(body, "{\"model\":");
	ABLAppendJSONString(body, model);
	ABLAppendLiteral(body, ",\"stream\":true,\"tool_choice\":\"auto\",\"tools\":");
	ABLAppendUTF8Range(body, ABLToolsJSON, NSMakeRange(0, [ABLToolsJSON length]));
	ABLAppendLiteral(body, ",\"messages\":[");
	NSUInteger index = 0;
	for (NSDictionary *message in messages) {
		if (index++ > 0) {
			ABLAppendLiteral(body, ",");
		}
		NSAutoreleasePool *messagePool = [[NSAutoreleasePool alloc] init];
		ABLAppendJSONForMessage(body, message);
		[messagePool release];
	}
	ABLAppendLiteral(body, "]}");

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300.0];
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	// Bearer, and nothing else: no device identifier, no app version, nothing
	// that would let an endpoint tell one phone from another.
	[request setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
	[request setHTTPBody:body];

	ABLChatStream *stream = [[ABLChatStream alloc] initWithRequest:request client:self generation:_generation];
	[NSThread detachNewThreadSelector:@selector(run) toTarget:stream withObject:nil];
	[stream release];
}

- (void)cancel {
	_generation++;
}

- (BOOL)isGenerationCurrent:(NSUInteger)generation {
	return generation == _generation;
}

#pragma mark - Main-thread delivery

- (BOOL)isCurrentEvent:(NSDictionary *)event {
	return [[event objectForKey:@"generation"] unsignedIntegerValue] == _generation;
}

- (void)deliverThinking:(NSDictionary *)event {
	if ([self isCurrentEvent:event]) {
		[_delegate chatClient:self didReceiveThinking:[event objectForKey:@"value"]];
	}
}

- (void)deliverToken:(NSDictionary *)event {
	if ([self isCurrentEvent:event]) {
		[_delegate chatClient:self didReceiveToken:[event objectForKey:@"value"]];
	}
}

- (void)deliverToolCalls:(NSDictionary *)event {
	if ([self isCurrentEvent:event]) {
		[_delegate chatClient:self didFinishWithToolCalls:[event objectForKey:@"value"]];
	}
}

- (void)deliverFailure:(NSDictionary *)event {
	if ([self isCurrentEvent:event]) {
		[_delegate chatClient:self didFailWithMessage:[event objectForKey:@"value"]];
	}
}

@end
