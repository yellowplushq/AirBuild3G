#import "ABLJSONParser.h"

#include <stdlib.h>

@interface ABLJSONParser () {
	NSString *_text;
	NSUInteger _index;
	NSUInteger _length;
	NSString *_errorDescription;
}

- (id)initWithData:(NSData *)data;
- (id)parse;

@end

@implementation ABLJSONParser

+ (id)objectWithData:(NSData *)data errorDescription:(NSString **)errorDescription {
	ABLJSONParser *parser = [[ABLJSONParser alloc] initWithData:data];
	id object = [parser parse];
	if (errorDescription != NULL) {
		*errorDescription = [[parser->_errorDescription copy] autorelease];
	}
	[parser release];
	return object;
}

- (id)initWithData:(NSData *)data {
	self = [super init];
	if (self != nil) {
		_text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		_length = [_text length];
	}
	return self;
}

- (void)fail:(NSString *)message {
	if (_errorDescription == nil) {
		_errorDescription = [[NSString alloc] initWithFormat:@"%@ at character %lu", message, (unsigned long)_index];
	}
}

- (void)skipWhitespace {
	while (_index < _length) {
		unichar character = [_text characterAtIndex:_index];
		if (character != ' ' && character != '\t' && character != '\r' && character != '\n') {
			break;
		}
		_index++;
	}
}

- (BOOL)consumeCharacter:(unichar)character {
	if (_index >= _length || [_text characterAtIndex:_index] != character) {
		return NO;
	}
	_index++;
	return YES;
}

- (BOOL)consumeWord:(NSString *)word {
	NSUInteger wordLength = [word length];
	if (wordLength > _length - _index) {
		return NO;
	}
	if ([[_text substringWithRange:NSMakeRange(_index, wordLength)] isEqualToString:word]) {
		_index += wordLength;
		return YES;
	}
	return NO;
}

- (NSInteger)hexValue:(unichar)character {
	if (character >= '0' && character <= '9') {
		return character - '0';
	}
	if (character >= 'a' && character <= 'f') {
		return character - 'a' + 10;
	}
	if (character >= 'A' && character <= 'F') {
		return character - 'A' + 10;
	}
	return -1;
}

- (BOOL)parseHexCodeUnit:(unichar *)codeUnit {
	if (4 > _length - _index) {
		[self fail:@"Incomplete Unicode escape"];
		return NO;
	}
	NSUInteger value = 0;
	for (NSUInteger offset = 0; offset < 4; offset++) {
		NSInteger digit = [self hexValue:[_text characterAtIndex:_index + offset]];
		if (digit < 0) {
			[self fail:@"Invalid Unicode escape"];
			return NO;
		}
		value = value * 16 + (NSUInteger)digit;
	}
	_index += 4;
	*codeUnit = (unichar)value;
	return YES;
}

- (NSString *)parseString {
	if (![self consumeCharacter:'"']) {
		[self fail:@"Expected string"];
		return nil;
	}

	NSMutableString *result = [NSMutableString string];
	while (_index < _length) {
		unichar character = [_text characterAtIndex:_index++];
		if (character == '"') {
			return result;
		}
		if (character < 0x20) {
			[self fail:@"Control character in string"];
			return nil;
		}
		if (character != '\\') {
			[result appendFormat:@"%C", character];
			continue;
		}
		if (_index >= _length) {
			[self fail:@"Incomplete escape"];
			return nil;
		}
		unichar escape = [_text characterAtIndex:_index++];
		switch (escape) {
			case '"': [result appendString:@"\""]; break;
			case '\\': [result appendString:@"\\"]; break;
			case '/': [result appendString:@"/"]; break;
			case 'b': [result appendString:@"\b"]; break;
			case 'f': [result appendString:@"\f"]; break;
			case 'n': [result appendString:@"\n"]; break;
			case 'r': [result appendString:@"\r"]; break;
			case 't': [result appendString:@"\t"]; break;
			case 'u': {
				unichar first;
				if (![self parseHexCodeUnit:&first]) {
					return nil;
				}
				if (first >= 0xD800 && first <= 0xDBFF) {
					if (_length - _index < 6 || [_text characterAtIndex:_index] != '\\' || [_text characterAtIndex:_index + 1] != 'u') {
						[self fail:@"Unpaired high surrogate"];
						return nil;
					}
					_index += 2;
					unichar second;
					if (![self parseHexCodeUnit:&second] || second < 0xDC00 || second > 0xDFFF) {
						[self fail:@"Invalid surrogate pair"];
						return nil;
					}
					unichar pair[] = { first, second };
					[result appendString:[NSString stringWithCharacters:pair length:2]];
				} else if (first >= 0xDC00 && first <= 0xDFFF) {
					[self fail:@"Unpaired low surrogate"];
					return nil;
				} else {
					[result appendFormat:@"%C", first];
				}
				break;
			}
			default:
				[self fail:@"Invalid escape"];
				return nil;
		}
	}
	[self fail:@"Unterminated string"];
	return nil;
}

- (NSNumber *)parseNumber {
	NSUInteger start = _index;
	if (_index < _length && [_text characterAtIndex:_index] == '-') {
		_index++;
	}
	if (_index >= _length) {
		[self fail:@"Incomplete number"];
		return nil;
	}
	unichar first = [_text characterAtIndex:_index];
	if (first == '0') {
		_index++;
	} else if (first >= '1' && first <= '9') {
		do {
			_index++;
		} while (_index < _length && [_text characterAtIndex:_index] >= '0' && [_text characterAtIndex:_index] <= '9');
	} else {
		[self fail:@"Invalid number"];
		return nil;
	}
	if (_index < _length && [_text characterAtIndex:_index] == '.') {
		_index++;
		NSUInteger fractionStart = _index;
		while (_index < _length && [_text characterAtIndex:_index] >= '0' && [_text characterAtIndex:_index] <= '9') {
			_index++;
		}
		if (_index == fractionStart) {
			[self fail:@"Missing fraction digits"];
			return nil;
		}
	}
	if (_index < _length) {
		unichar exponent = [_text characterAtIndex:_index];
		if (exponent == 'e' || exponent == 'E') {
			_index++;
			if (_index < _length) {
				unichar sign = [_text characterAtIndex:_index];
				if (sign == '+' || sign == '-') {
					_index++;
				}
			}
			NSUInteger exponentStart = _index;
			while (_index < _length && [_text characterAtIndex:_index] >= '0' && [_text characterAtIndex:_index] <= '9') {
				_index++;
			}
			if (_index == exponentStart) {
				[self fail:@"Missing exponent digits"];
				return nil;
			}
		}
	}
	NSString *raw = [_text substringWithRange:NSMakeRange(start, _index - start)];
	return [NSNumber numberWithDouble:strtod([raw UTF8String], NULL)];
}

- (id)parseValueAtDepth:(NSUInteger)depth {
	if (depth > 64) {
		[self fail:@"JSON is nested too deeply"];
		return nil;
	}
	[self skipWhitespace];
	if (_index >= _length) {
		[self fail:@"Expected value"];
		return nil;
	}

	unichar character = [_text characterAtIndex:_index];
	if (character == '"') {
		return [self parseString];
	}
	if (character == '-' || (character >= '0' && character <= '9')) {
		return [self parseNumber];
	}
	if ([self consumeWord:@"true"]) {
		return [NSNumber numberWithBool:YES];
	}
	if ([self consumeWord:@"false"]) {
		return [NSNumber numberWithBool:NO];
	}
	if ([self consumeWord:@"null"]) {
		return [NSNull null];
	}
	if ([self consumeCharacter:'[']) {
		NSMutableArray *array = [NSMutableArray array];
		[self skipWhitespace];
		if ([self consumeCharacter:']']) {
			return array;
		}
		while (_errorDescription == nil) {
			id value = [self parseValueAtDepth:depth + 1];
			if (value == nil) {
				return nil;
			}
			[array addObject:value];
			[self skipWhitespace];
			if ([self consumeCharacter:']']) {
				return array;
			}
			if (![self consumeCharacter:',']) {
				[self fail:@"Expected comma or closing bracket"];
				return nil;
			}
		}
		return nil;
	}
	if ([self consumeCharacter:'{']) {
		NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
		[self skipWhitespace];
		if ([self consumeCharacter:'}']) {
			return dictionary;
		}
		while (_errorDescription == nil) {
			[self skipWhitespace];
			NSString *key = [self parseString];
			if (key == nil) {
				return nil;
			}
			[self skipWhitespace];
			if (![self consumeCharacter:':']) {
				[self fail:@"Expected colon"];
				return nil;
			}
			id value = [self parseValueAtDepth:depth + 1];
			if (value == nil) {
				return nil;
			}
			[dictionary setObject:value forKey:key];
			[self skipWhitespace];
			if ([self consumeCharacter:'}']) {
				return dictionary;
			}
			if (![self consumeCharacter:',']) {
				[self fail:@"Expected comma or closing brace"];
				return nil;
			}
		}
		return nil;
	}
	[self fail:@"Unrecognized value"];
	return nil;
}

- (id)parse {
	if (_text == nil) {
		[self fail:@"Response is not UTF-8"];
		return nil;
	}
	id object = [self parseValueAtDepth:0];
	[self skipWhitespace];
	if (object != nil && _index != _length) {
		[self fail:@"Unexpected trailing content"];
		return nil;
	}
	return object;
}

- (void)dealloc {
	[_errorDescription release];
	[_text release];
	[super dealloc];
}

@end
