#import <Foundation/Foundation.h>

// The project's working tree flattened into one block of text — the file list
// and then every text file in it — for the system prompt.
//
// The model on this phone reads a 64 KB pipe at a time and gets sixteen tool
// rounds per turn. Spending the first four of them on `ls -R` and `cat` is a
// third of the turn gone before it has read anything, so the tree is handed
// over up front instead: it is a few kilobytes for a project of this size, and
// the alternative costs more tokens than it saves.
//
// A snapshot, taken when the project is opened. Anything the model writes
// afterwards it already knows about, and PatchFile and Execute read the disk.

// Files larger than this are listed but not quoted: a 200 KB generated file is
// not what the tree is for.
extern const NSUInteger ABLRepoDigestFileLimit;

// `root`'s tree as text, bounded by `budget` bytes. Directories that hold
// build output or version control history are skipped whole. Returns an empty
// string for an empty or unreadable tree.
NSString *ABLRepoDigest(NSString *root, NSUInteger budget);
