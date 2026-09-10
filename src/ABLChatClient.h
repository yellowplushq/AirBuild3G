#import <Foundation/Foundation.h>

@class ABLChatClient;

// Always delivered on the main thread, in stream order.
@protocol ABLChatClientDelegate <NSObject>

- (void)chatClient:(ABLChatClient *)client didReceiveThinking:(NSString *)token;
- (void)chatClient:(ABLChatClient *)client didReceiveToken:(NSString *)token;
- (void)chatClient:(ABLChatClient *)client didFinishWithToolCalls:(NSArray *)toolCalls;
- (void)chatClient:(ABLChatClient *)client didFailWithMessage:(NSString *)message;

@end

// One OpenAI-style chat completion at a time. The request is built on the
// calling thread and then run on a thread of its own: connecting, decoding the
// event stream and splitting the reply all happen off the main thread, which
// only ever receives finished tokens.
//
// Server certificates are validated. TLS 1.2 comes from TLSFix (a CFNetwork
// Substrate tweak); iOS 4 still evaluates the chain with SecTrust before the
// NSURLConnection challenge, and ABLTrustAll.m can override that result -- but
// only while Settings -> Trust Any Certificate is on, which it is not by
// default. The same flag is what lets this class answer the server-trust
// challenge itself; with it off, Foundation handles the challenge as usual.
// The request carries the owner's API key, so do not make either unconditional.
//
// The client owns the whole reply-splitting contract: the delegate receives
// thinking and content as separate token streams, and tool calls only as
// normalized dictionaries. Markup the model uses to express either one
// (<think>, <tool_call>) never reaches the delegate.
@interface ABLChatClient : NSObject

@property(nonatomic, assign) id<ABLChatClientDelegate> delegate;

// messages: array of role dictionaries, oldest first. Thinking rows must
// already have been stripped by the caller. Read on the calling thread before
// this returns, never afterwards.
- (void)sendMessages:(NSArray *)messages;

// Abandons the reply in flight. No further delegate messages arrive for it.
- (void)cancel;

@end
