#import <Foundation/Foundation.h>

#import "ABLJSONParser.h"

#include <stdlib.h>

static void require(BOOL condition, NSString *message) {
	if (!condition) {
		NSLog(@"FAIL: %@", message);
		exit(1);
	}
}

static id parse(NSString *JSON, NSString **error) {
	NSData *data = [JSON dataUsingEncoding:NSUTF8StringEncoding];
	return [ABLJSONParser objectWithData:data errorDescription:error];
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	NSString *error = nil;
	NSDictionary *object = parse(@"{\"name\":\"AirBuild\",\"ready\":true,\"count\":2,\"items\":[null,\"A\\nB\",\"\\u65e5\\ud83c\\udf31\"]}", &error);
	require(object != nil && error == nil, @"valid JSON should parse");
	require([[object objectForKey:@"name"] isEqualToString:@"AirBuild"], @"string value should survive");
	require([[[object objectForKey:@"items"] objectAtIndex:1] isEqualToString:@"A\nB"], @"escape should decode");
	require([[[object objectForKey:@"items"] objectAtIndex:2] isEqualToString:@"日🌱"], @"Unicode should decode");
	require([[[object objectForKey:@"ready"] description] isEqualToString:@"1"], @"boolean should decode");

	error = nil;
	require(parse(@"{\"broken\": [1,]}", &error) == nil && error != nil, @"trailing comma should fail");
	error = nil;
	require(parse(@"01", &error) == nil && error != nil, @"leading zero should fail");
	error = nil;
	require(parse(@"\"\\ud800\"", &error) == nil && error != nil, @"unpaired surrogate should fail");

	error = nil;
	NSDictionary *toolCall = parse(@"{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"exec\",\"arguments\":\"{\\\"command\\\":\\\"id\\\"}\"}}]}}]}", &error);
	require(toolCall != nil && error == nil, @"tool_calls payload should parse");
	NSDictionary *delta = [[[toolCall objectForKey:@"choices"] objectAtIndex:0] objectForKey:@"delta"];
	NSDictionary *call = [[delta objectForKey:@"tool_calls"] objectAtIndex:0];
	require([[call objectForKey:@"id"] isEqualToString:@"call_1"], @"tool call id should survive");
	require([[[call objectForKey:@"function"] objectForKey:@"name"] isEqualToString:@"exec"], @"tool name should survive");
	require([[[call objectForKey:@"function"] objectForKey:@"arguments"] isEqualToString:@"{\"command\":\"id\"}"], @"tool arguments should survive");

	NSLog(@"PASS: JSON parser");
	[pool release];
	return 0;
}
