#import <Foundation/Foundation.h>

@interface ABLJSONParser : NSObject

+ (id)objectWithData:(NSData *)data errorDescription:(NSString **)errorDescription;

@end
