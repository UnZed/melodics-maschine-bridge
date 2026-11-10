#import "DeviceMonitor.h"
#import <IOKit/IOKitLib.h>
static CFMutableDictionaryRef matching(void){
    CFMutableDictionaryRef m=IOServiceMatching("IOUSBHostDevice");
    if(m)CFDictionarySetValue(m,CFSTR(kIOPropertyMatchKey),(__bridge CFDictionaryRef)@{@"idVendor":@0x17cc});
    return m;
}
NSArray *MLPConnectedDevices(void){
    io_iterator_t iterator=0;NSMutableArray *devices=[NSMutableArray new];
    if(IOServiceGetMatchingServices(kIOMainPortDefault,matching(),&iterator)!=KERN_SUCCESS)return devices;
    io_service_t service;while((service=IOIteratorNext(iterator))){
        CFMutableDictionaryRef props=NULL;uint64_t identifier=0;
        IORegistryEntryGetRegistryEntryID(service,&identifier);
        if(IORegistryEntryCreateCFProperties(service,&props,kCFAllocatorDefault,0)==KERN_SUCCESS){
            NSDictionary *p=CFBridgingRelease(props);int pid=[p[@"idProduct"]intValue];id serial=p[@"USB Serial Number"];
            if((pid==0x1600||pid==0x1820)&&[serial isKindOfClass:NSString.class])
                [devices addObject:@{@"pid":@(pid),@"serial":serial,@"registry_id":@(identifier),@"name":p[@"USB Product Name"]?:@"Maschine"}];
        }IOObjectRelease(service);
    }IOObjectRelease(iterator);return devices;
}
@interface MLPDeviceMonitor ()
@property(copy) dispatch_block_t change;
@end
static void changed(void *context,io_iterator_t iterator){
    io_service_t service;while((service=IOIteratorNext(iterator)))IOObjectRelease(service);
    MLPDeviceMonitor *monitor=(__bridge MLPDeviceMonitor *)context;if(monitor.change)monitor.change();
}
@implementation MLPDeviceMonitor {
    IONotificationPortRef _port;io_iterator_t _added,_removed;
}
- (instancetype)initWithChange:(dispatch_block_t)change{
    if((self=[super init])){
        _change=[change copy];_port=IONotificationPortCreate(kIOMainPortDefault);
        if(!_port)return self;
        IONotificationPortSetDispatchQueue(_port,dispatch_get_main_queue());
        kern_return_t a=IOServiceAddMatchingNotification(_port,kIOMatchedNotification,matching(),changed,(__bridge void *)self,&_added);
        kern_return_t r=IOServiceAddMatchingNotification(_port,kIOTerminatedNotification,matching(),changed,(__bridge void *)self,&_removed);
        if(a==KERN_SUCCESS)changed((__bridge void *)self,_added);
        if(r==KERN_SUCCESS)changed((__bridge void *)self,_removed);
    }return self;
}
- (void)stop{
    self.change=nil;if(_added){IOObjectRelease(_added);_added=0;}if(_removed){IOObjectRelease(_removed);_removed=0;}
    if(_port){IONotificationPortDestroy(_port);_port=NULL;}
}
- (void)dealloc{[self stop];}
@end
