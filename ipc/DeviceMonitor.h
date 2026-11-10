#import <Foundation/Foundation.h>
NSArray *MLPConnectedDevices(void);
@interface MLPDeviceMonitor : NSObject
- (instancetype)initWithChange:(dispatch_block_t)change;
- (void)stop;
@end
