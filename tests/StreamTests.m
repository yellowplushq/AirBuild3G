#import <Foundation/Foundation.h>

#import "ABLChatClient.h"

#include <stdlib.h>

// The reply splitter and the tool-call normalizer, at the boundary where they
// own their contract. Both are fed the way a stream feeds them — in arbitrary
// chunks — because every interesting failure of this code is a tag landing
// across a packet boundary.
// ABLChatStream is private to ABLChatClient.m: one request, one thread, one
// copy of the splitting state. The tests drive it directly and let it deliver
// through the real main-thread path.
@interface ABLChatStream : NSObject
- (id)initWithRequest:(NSURLRequest *)request client:(ABLChatClient *)client generation:(NSUInteger)generation;
- (void)emitText:(NSString *)text;
- (void)flushPendingText;
- (void)mergeToolCallDelta:(NSDictionary *)call;
- (NSArray *)frozenToolCalls;
@end

// A stream is only current while the client agrees; a fresh client starts at
// generation 0, which is what these streams are built with.
static ABLChatStream *newStreamForClient(ABLChatClient *client) {
	return [[ABLChatStream alloc] initWithRequest:nil client:client generation:0];
}

// Lets the deliveries queued for the main thread actually run.
static void drainMainThread(void) {
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

@interface ABLStreamCollector : NSObject <ABLChatClientDelegate> {
	NSMutableString *_thinking;
	NSMutableString *_content;
}
@property(nonatomic, readonly) NSMutableString *thinking;
@property(nonatomic, readonly) NSMutableString *content;
@end

@implementation ABLStreamCollector

@synthesize thinking = _thinking, content = _content;

- (id)init {
	self = [super init];
	if (self != nil) {
		_thinking = [[NSMutableString alloc] init];
		_content = [[NSMutableString alloc] init];
	}
	return self;
}

- (void)chatClient:(ABLChatClient *)client didReceiveThinking:(NSString *)token {
	[_thinking appendString:token];
}

- (void)chatClient:(ABLChatClient *)client didReceiveToken:(NSString *)token {
	[_content appendString:token];
}

- (void)chatClient:(ABLChatClient *)client didFinishWithToolCalls:(NSArray *)toolCalls {
}

- (void)chatClient:(ABLChatClient *)client didFailWithMessage:(NSString *)message {
}

- (void)dealloc {
	[_content release];
	[_thinking release];
	[super dealloc];
}

@end

static NSUInteger gFailures = 0;

static void expectEqual(NSString *actual, NSString *expected, NSString *what) {
	if (![actual isEqualToString:expected]) {
		NSLog(@"FAIL: %@\n  expected: %@\n  actual:   %@", what, expected, actual);
		gFailures++;
	}
}

// Feeds `text` in chunks of `chunk` characters and returns thinking, content
// and the frozen tool calls as one comparable description.
static NSString *splitReply(NSString *text, NSUInteger chunk) {
	ABLChatClient *client = [[ABLChatClient alloc] init];
	ABLStreamCollector *collector = [[ABLStreamCollector alloc] init];
	[client setDelegate:collector];
	ABLChatStream *stream = newStreamForClient(client);
	for (NSUInteger i = 0; i < [text length]; i += chunk) {
		NSRange range = NSMakeRange(i, MIN(chunk, [text length] - i));
		[stream emitText:[text substringWithRange:range]];
	}
	[stream flushPendingText];
	drainMainThread();

	NSMutableString *description = [NSMutableString string];
	[description appendFormat:@"thinking=<%@> content=<%@>", [collector thinking], [collector content]];
	for (NSDictionary *call in [stream frozenToolCalls]) {
		[description appendFormat:@" call=<%@|%@>", [call objectForKey:@"name"], [call objectForKey:@"arguments"]];
	}
	[stream release];
	[collector release];
	[client release];
	return description;
}

// The same reply must split identically no matter where the packets land.
// Prime chunk sizes so the boundaries walk through the tags instead of
// landing on the same offsets every time.
static void expectSplit(NSString *text, NSString *expected, NSString *what) {
	static const NSUInteger chunks[] = { 1, 2, 3, 5, 7, 11 };
	expectEqual(splitReply(text, [text length]), expected, [NSString stringWithFormat:@"%@ (one chunk)", what]);
	for (NSUInteger i = 0; i < sizeof(chunks) / sizeof(chunks[0]); i++) {
		expectEqual(splitReply(text, chunks[i]), expected,
			[NSString stringWithFormat:@"%@ (chunks of %lu)", what, (unsigned long)chunks[i]]);
	}
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	expectSplit(@"  Hello from the 3G.  ",
		@"thinking=<> content=<Hello from the 3G.  >",
		@"plain text keeps its body and loses its leading whitespace");

	expectSplit(@"<think>I should answer.</think>The answer is 4.",
		@"thinking=<I should answer.> content=<The answer is 4.>",
		@"a think block becomes thinking, the rest becomes content");

	expectSplit(@"<think>one</think><think>two</think>done",
		@"thinking=<onetwo> content=<done>",
		@"a second think block is still thinking");

	expectSplit(@"3 < 4 and x <y> z",
		@"thinking=<> content=<3 < 4 and x <y> z>",
		@"angle brackets that are not tags survive");

	expectSplit(@"<tool_call>{\"name\":\"exec\",\"arguments\":{\"command\":\"id\"}}</tool_call>",
		@"thinking=<> content=<> call=<exec|{\"command\":\"id\"}>",
		@"tool call markup never reaches the transcript");

	expectSplit(@"Checking.<tool_call>{\"name\":\"exec\",\"arguments\":\"{\\\"command\\\":\\\"uname -a\\\"}\"}</tool_call> Done.",
		@"thinking=<> content=<Checking. Done.> call=<exec|{\"command\":\"uname -a\"}>",
		@"text around a tool call is still content, with string arguments");

	expectSplit(@"<think>plan</think><tool_call>{\"name\":\"exec\",\"arguments\":{\"command\":\"ls /\"}}</tool_call>",
		@"thinking=<plan> content=<> call=<exec|{\"command\":\"ls /\"}>",
		@"thinking and a tool call in one reply");

	expectSplit(@"a<tool_call>{\"name\":\"exec\",\"arguments\":{\"command\":\"x\"}}</tool_call>b<tool_call>{\"name\":\"exec\",\"arguments\":{\"command\":\"y\"}}</tool_call>",
		@"thinking=<> content=<ab> call=<exec|{\"command\":\"x\"}> call=<exec|{\"command\":\"y\"}>",
		@"two tool calls in one reply");

	expectSplit(@"Working<tool_call>{\"name\":\"exec\",",
		@"thinking=<> content=<Working{\"name\":\"exec\",>",
		@"a truncated tool call is surfaced rather than dropped");

	expectSplit(@"<think>cut off mid thought",
		@"thinking=<cut off mid thought> content=<>",
		@"a truncated think block is surfaced as thinking");

	// Streamed tool calls: the id arrives with the first fragment and the
	// arguments accumulate across the rest.
	ABLChatClient *client = [[ABLChatClient alloc] init];
	ABLChatStream *stream = newStreamForClient(client);
	[stream mergeToolCallDelta:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInt:0], @"index", @"call_abc", @"id",
		[NSDictionary dictionaryWithObjectsAndKeys:@"exec", @"name", @"{\"comm", @"arguments", nil], @"function", nil]];
	[stream mergeToolCallDelta:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInt:0], @"index",
		[NSDictionary dictionaryWithObjectsAndKeys:@"and\":\"id\"}", @"arguments", nil], @"function", nil]];
	NSArray *calls = [stream frozenToolCalls];
	expectEqual([NSString stringWithFormat:@"%lu", (unsigned long)[calls count]], @"1", @"delta fragments merge into one call");
	expectEqual([[calls objectAtIndex:0] objectForKey:@"id"], @"call_abc", @"the streamed id survives");
	expectEqual([[calls objectAtIndex:0] objectForKey:@"arguments"], @"{\"command\":\"id\"}", @"the streamed arguments concatenate");
	[stream release];

	// A delta that never carries arguments is not a call anybody can run.
	stream = newStreamForClient(client);
	[stream mergeToolCallDelta:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:0], @"index", nil]];
	expectEqual([NSString stringWithFormat:@"%lu", (unsigned long)[[stream frozenToolCalls] count]], @"0",
		@"an empty tool call slot is dropped");
	[stream release];
	[client release];

	if (gFailures > 0) {
		NSLog(@"FAILED: %lu stream assertions", (unsigned long)gFailures);
		[pool release];
		return 1;
	}
	NSLog(@"PASS: reply splitting and tool calls");
	[pool release];
	return 0;
}
