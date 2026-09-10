#import <UIKit/UIKit.h>

// Everything one install step printed. A step's row shows its last line; this
// is where the rest of it is.
@interface ABLLogViewController : UIViewController {
	UITextView *_textView;
	NSString *_text;
	UIFont *_font;
	id _liveSource;          // polled while the page is on screen
	SEL _liveSelector;       // returns the current text
	NSTimer *_liveTimer;
}

- (id)initWithTitle:(NSString *)title text:(NSString *)text;
// The same page for prose (a reply's full thinking): a body face instead of
// the terminal one.
- (id)initWithTitle:(NSString *)title text:(NSString *)text font:(UIFont *)font;
// Replaces the text while it is still growing (a reply's thinking, mid
// stream). The reader's scroll position is kept, not chased.
- (void)updateText:(NSString *)text;
// Polls `[source selector]` once a second while the page is showing and
// applies any change with -updateText:. For text another thread keeps
// appending to (an install step's log): the source hands back a snapshot.
- (void)followSource:(id)source selector:(SEL)selector;

@end
