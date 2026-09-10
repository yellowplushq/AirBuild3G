#import <Foundation/Foundation.h>

#import "ABLChatClient.h"
#import "ABLConfig.h"
#import "ABLJSONParser.h"

#include <stdio.h>
#include <stdlib.h>

// A real conversation with the configured endpoint, driven the way
// ABLChatViewController drives it: send, stream, run the tool calls, send the
// results back, until the model stops asking for tools.
//
// The commands come from a remote model, so this harness — unlike the app on
// its own phone — only runs read-only ones and tells the model when it
// refused. Everything else is the app's own code path.
static const NSUInteger ABLEndToEndRoundLimit = 4;
static const NSTimeInterval ABLEndToEndTimeout = 180.0;

static BOOL ABLCommandIsReadOnly(NSString *command) {
	static NSString *allowed[] = {
		@"whoami", @"id", @"uname", @"sw_vers", @"hostname", @"pwd", @"date", @"echo", @"ls", @"sysctl", @"printenv"
	};
	if ([command rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@";|&$`><\n\r"]].location != NSNotFound) {
		return NO;
	}
	NSString *first = [[command componentsSeparatedByString:@" "] objectAtIndex:0];
	for (NSUInteger i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
		if ([first isEqualToString:allowed[i]]) {
			return YES;
		}
	}
	return NO;
}

static NSString *ABLRunReadOnlyCommand(NSString *command) {
	if (!ABLCommandIsReadOnly(command)) {
		return @"refused: this test harness only runs read-only commands (whoami, id, uname, sw_vers, hostname, pwd, date, echo, ls, sysctl, printenv) with no shell operators.";
	}
	FILE *pipe = popen([[command stringByAppendingString:@" 2>&1"] UTF8String], "r");
	if (pipe == NULL) {
		return @"exec failed";
	}
	NSMutableData *data = [NSMutableData data];
	char buffer[4096];
	size_t n;
	while ((n = fread(buffer, 1, sizeof(buffer), pipe)) > 0 && [data length] < 64 * 1024) {
		[data appendBytes:buffer length:n];
	}
	pclose(pipe);
	NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	return [text length] > 0 ? text : @"(no output)";
}

@interface ABLEndToEnd : NSObject <ABLChatClientDelegate> {
	ABLChatClient *_client;
	NSMutableArray *_messages;
	NSMutableString *_assistantText;
	NSUInteger _thinkingTokens;
	NSUInteger _contentTokens;
	NSUInteger _commandsRun;
	NSUInteger _round;
	BOOL _finished;
	BOOL _failed;
	NSString *_failure;
}
- (void)askQuestion:(NSString *)question;
- (void)failWith:(NSString *)reason;
@property(nonatomic, readonly) BOOL finished;
@property(nonatomic, readonly) BOOL failed;
@property(nonatomic, readonly) NSString *failure;
@property(nonatomic, readonly) NSMutableString *assistantText;
@property(nonatomic, readonly) NSUInteger thinkingTokens;
@property(nonatomic, readonly) NSUInteger contentTokens;
@property(nonatomic, readonly) NSUInteger commandsRun;
@end

@implementation ABLEndToEnd

@synthesize finished = _finished, failed = _failed, failure = _failure;
@synthesize assistantText = _assistantText, thinkingTokens = _thinkingTokens;
@synthesize contentTokens = _contentTokens, commandsRun = _commandsRun;

- (id)init {
	self = [super init];
	if (self != nil) {
		_client = [[ABLChatClient alloc] init];
		[_client setDelegate:self];
		_messages = [[NSMutableArray alloc] init];
		_assistantText = [[NSMutableString alloc] init];
	}
	return self;
}

- (void)failWith:(NSString *)reason {
	[_failure release];
	_failure = [reason retain];
	_failed = YES;
	_finished = YES;
}

- (void)askQuestion:(NSString *)question {
	printf("\n\033[1muser\033[0m  %s\n", [question UTF8String]);
	[_messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", question, @"content", nil]];
	[_client sendMessages:_messages];
}

- (void)chatClient:(ABLChatClient *)client didReceiveThinking:(NSString *)token {
	if (_thinkingTokens++ == 0) {
		printf("\n\033[90mthink \033[0m");
	}
	printf("\033[90m%s\033[0m", [token UTF8String]);
	fflush(stdout);
}

- (void)chatClient:(ABLChatClient *)client didReceiveToken:(NSString *)token {
	if (_contentTokens++ == 0) {
		printf("\n\033[1mmodel\033[0m ");
	}
	printf("%s", [token UTF8String]);
	fflush(stdout);
	[_assistantText appendString:token];
}

- (void)chatClient:(ABLChatClient *)client didFinishWithToolCalls:(NSArray *)toolCalls {
	printf("\n");
	if ([toolCalls count] == 0) {
		_finished = YES;
		return;
	}
	if (_round++ >= ABLEndToEndRoundLimit) {
		[self failWith:@"the tool loop hit the round limit"];
		return;
	}

	// A copy: the dictionary would otherwise hold the same mutable string the
	// next round streams into, and this turn would replay to the model as empty.
	[_messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:
		@"assistant", @"role", [[_assistantText copy] autorelease], @"content",
		toolCalls, @"tool_calls", nil]];
	[_assistantText setString:@""];

	for (NSDictionary *call in toolCalls) {
		NSString *arguments = [call objectForKey:@"arguments"];
		NSString *command = arguments;
		id object = [ABLJSONParser objectWithData:[arguments dataUsingEncoding:NSUTF8StringEncoding]
			errorDescription:NULL];
		if ([object isKindOfClass:[NSDictionary class]] && [[object objectForKey:@"command"] isKindOfClass:[NSString class]]) {
			command = [object objectForKey:@"command"];
		}
		printf("\033[33mexec\033[0m  %s\n", [command UTF8String]);
		NSString *output = ABLRunReadOnlyCommand(command);
		_commandsRun++;
		printf("\033[33m   →\033[0m  %s\n", [[output stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]] UTF8String]);
		[_messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:
			@"tool", @"role",
			[call objectForKey:@"id"], @"tool_call_id",
			[call objectForKey:@"name"], @"name",
			output, @"content", nil]];
	}
	[_client sendMessages:_messages];
}

- (void)chatClient:(ABLChatClient *)client didFailWithMessage:(NSString *)message {
	[self failWith:message];
}

- (void)dealloc {
	[_failure release];
	[_assistantText release];
	[_messages release];
	[_client setDelegate:nil];
	[_client cancel];
	[_client release];
	[super dealloc];
}

@end

static NSUInteger gFailures = 0;

static void expect(BOOL condition, NSString *what) {
	printf("%s %s\n", condition ? "\033[32m  ok  \033[0m" : "\033[31m FAIL \033[0m", [what UTF8String]);
	if (!condition) {
		gFailures++;
	}
}

int main(int argc, char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	// The same three settings the phone has, taken from the command line or
	// the environment so a key never has to be typed into a shell that keeps
	// history. Nothing is enrolled and nothing is registered: this harness is
	// a client of whatever endpoint it is pointed at, exactly like the app.
	//
	//   make e2e E2E_ARGS="https://api.anthropic.com/v1 $KEY claude-opus-5"
	//   ANTHROPIC_API_KEY=… make e2e
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSString *base = argc > 1 ? [NSString stringWithUTF8String:argv[1]]
		: [environment objectForKey:@"ABL_API_BASE"];
	NSString *key = argc > 2 ? [NSString stringWithUTF8String:argv[2]]
		: [environment objectForKey:@"ANTHROPIC_API_KEY"];
	NSString *model = argc > 3 ? [NSString stringWithUTF8String:argv[3]]
		: [environment objectForKey:@"ABL_MODEL"];
	if ([base length] > 0) {
		[defaults setObject:base forKey:ABLDefaultsAPIBaseKey];
	}
	if ([model length] > 0) {
		[defaults setObject:model forKey:ABLDefaultsModelKey];
	}
	if ([key length] == 0) {
		printf("usage: EndToEndTests [base-url [api-key [model]]]\n"
		       "       or set ANTHROPIC_API_KEY (and optionally ABL_API_BASE, ABL_MODEL)\n");
		[pool release];
		return 2;
	}
	[defaults setObject:key forKey:ABLDefaultsAPIKeyKey];
	NSString *usingBase = [base length] > 0 ? base : ABLDefaultAPIBase;
	NSString *usingModel = [model length] > 0 ? model : ABLDefaultModel;
	printf("endpoint %s, model %s\n", [usingBase UTF8String], [usingModel UTF8String]);

	ABLEndToEnd *conversation = [[ABLEndToEnd alloc] init];
	[conversation askQuestion:@"Which user am I running as, and what kernel is this? Use the exec tool, then answer in one sentence."];

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:ABLEndToEndTimeout];
	while (![conversation finished] && [deadline timeIntervalSinceNow] > 0.0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	}

	printf("\n");
	expect([conversation finished], @"the conversation finished before the timeout");
	expect(![conversation failed], [NSString stringWithFormat:@"no transport or server error (%@)",
		[conversation failure] != nil ? [conversation failure] : @"none"]);
	expect([conversation commandsRun] > 0, @"the model asked for at least one exec tool call");
	expect([conversation contentTokens] > 0, @"the model produced a spoken answer");
	expect([[conversation assistantText] rangeOfString:@"<tool_call>"].location == NSNotFound,
		@"no tool call markup leaked into the answer");
	expect([[conversation assistantText] rangeOfString:@"<think>"].location == NSNotFound,
		@"no think markup leaked into the answer");
	if ([conversation thinkingTokens] == 0) {
		printf("\033[90m  note  the model streamed no reasoning tokens this run\033[0m\n");
	}

	NSUInteger failures = gFailures;
	[conversation release];
	[pool release];
	if (failures > 0) {
		printf("\n\033[31mFAILED\033[0m %lu end-to-end assertions\n", (unsigned long)failures);
		return 1;
	}
	printf("\n\033[32mPASS\033[0m end-to-end against the live endpoint\n");
	return 0;
}
