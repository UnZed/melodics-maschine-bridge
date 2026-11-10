#import <Foundation/Foundation.h>
// Output values are in logical pad order (1 = bottom-left).
NSDictionary *MLPPadLightState(NSDictionary *screens, BOOL noteContextValid, NSUInteger enabledPads);
// Validate the whole array before changing only the 16 pad slots of a 103-byte bank.
BOOL MLPApplyPadLEDs(NSMutableData *bank, id values);

@interface MLPPadWave : NSObject
@property BOOL enabled;
@property double tempoBPM; // Invalid/missing tempo falls back to 120 BPM.
@property (readonly) BOOL active;
- (BOOL)button:(BOOL)down;
- (void)hit:(NSUInteger)pad time:(double)time;
- (NSArray *)apply:(NSArray *)baseline time:(double)time;
- (void)reset;
@end
// Merge strip position and its two mode buttons without touching any other LED.
BOOL MLPApplyStripFeedback(NSMutableData *bank, id feedback);
