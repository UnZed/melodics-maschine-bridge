#import <Foundation/Foundation.h>

// Diagnostic interpretation inferred from local captures; no MIDI or velocity curve.
@interface MLPPadInspector : NSObject
@property (readonly) NSUInteger hits, releases, pressureUpdates, duplicates;
- (NSDictionary *)consume:(NSData *)packet time:(double)time;
- (NSArray<NSDictionary *> *)consumeBatch:(NSData *)packet time:(double)time;
- (void)reset;
@end
