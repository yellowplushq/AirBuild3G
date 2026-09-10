#import "ABLDetailCell.h"

static const CGFloat ABLDetailCellInset = 10.0f;

@implementation ABLDetailCell

@synthesize titleLabel = _titleLabel;
@synthesize detailLabel = _detailLabel;

- (id)initWithReuseIdentifier:(NSString *)reuseIdentifier layout:(ABLDetailCellLayout)layout {
	self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
	if (self != nil) {
		_layout = layout;
		_titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		[_titleLabel setFont:[UIFont boldSystemFontOfSize:17.0f]];
		[_titleLabel setBackgroundColor:[UIColor clearColor]];
		[_titleLabel setHighlightedTextColor:[UIColor whiteColor]];
		[[self contentView] addSubview:_titleLabel];
		_detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		[_detailLabel setFont:[UIFont systemFontOfSize:layout == ABLDetailCellValue ? 17.0f : 13.0f]];
		[_detailLabel setTextColor:layout == ABLDetailCellValue ? [UIColor darkGrayColor] : [UIColor grayColor]];
		[_detailLabel setTextAlignment:layout == ABLDetailCellValue ? UITextAlignmentRight : UITextAlignmentLeft];
		[_detailLabel setBackgroundColor:[UIColor clearColor]];
		[_detailLabel setHighlightedTextColor:[UIColor whiteColor]];
		[[self contentView] addSubview:_detailLabel];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect bounds = [[self contentView] bounds];
	CGFloat width = bounds.size.width - 2.0f * ABLDetailCellInset;
	if (_layout == ABLDetailCellValue) {
		// The title takes what it needs; the value has the rest, right-aligned.
		CGFloat titleWidth = [[_titleLabel text] sizeWithFont:[_titleLabel font]].width;
		titleWidth = MIN(titleWidth, width * 0.6f);
		[_titleLabel setFrame:CGRectMake(ABLDetailCellInset, 0.0f, titleWidth, bounds.size.height)];
		CGFloat valueX = ABLDetailCellInset + titleWidth + 8.0f;
		[_detailLabel setFrame:CGRectMake(valueX, 0.0f, bounds.size.width - valueX - ABLDetailCellInset, bounds.size.height)];
		return;
	}
	// The stock subtitle geometry: title on top, the smaller line under it.
	[_titleLabel setFrame:CGRectMake(ABLDetailCellInset, 6.0f, width, 21.0f)];
	[_detailLabel setFrame:CGRectMake(ABLDetailCellInset, 27.0f, width, 14.0f)];
}

// The labels are ours, so their highlight is ours to drive: white on the
// blue selection, like the stock ones.
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
	[super setHighlighted:highlighted animated:animated];
	[_titleLabel setHighlighted:highlighted];
	[_detailLabel setHighlighted:highlighted];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
	[super setSelected:selected animated:animated];
	[_titleLabel setHighlighted:selected];
	[_detailLabel setHighlighted:selected];
}

- (void)dealloc {
	[_titleLabel release];
	_titleLabel = nil;
	[_detailLabel release];
	_detailLabel = nil;
	[super dealloc];
}

@end
