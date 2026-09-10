#import <UIKit/UIKit.h>

// A title with a second piece of text, laid out by this class. UIKit's own
// detailTextLabel is never laid out on the reference 4.2.1 3G — the label
// exists and carries the text, and the row draws as if it were empty, in
// every style — so the two labels here are the cell's own and every row
// that needs a subtitle or a right-hand value uses this.
typedef enum {
	ABLDetailCellSubtitle,   // detail under the title, small and grey
	ABLDetailCellValue       // detail on the right, the same size as the title
} ABLDetailCellLayout;

@interface ABLDetailCell : UITableViewCell {
	UILabel *_titleLabel;
	UILabel *_detailLabel;
	ABLDetailCellLayout _layout;
}

- (id)initWithReuseIdentifier:(NSString *)reuseIdentifier layout:(ABLDetailCellLayout)layout;

@property(nonatomic, readonly) UILabel *titleLabel;
@property(nonatomic, readonly) UILabel *detailLabel;

@end
