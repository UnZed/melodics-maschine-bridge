#import "PadInspector.h"
#include <math.h>

static uint32_t readWord(NSData *data, NSUInteger offset) {
    uint32_t value; memcpy(&value, (const uint8_t *)data.bytes+offset, 4);
    return CFSwapInt32LittleToHost(value);
}
@implementation MLPPadInspector {
    BOOL _held[16];
    double _started[16];
    float _peak[16];
    NSUInteger _hits, _releases, _pressureUpdates, _duplicates;
}
- (NSUInteger)hits { return _hits; }
- (NSUInteger)releases { return _releases; }
- (NSUInteger)pressureUpdates { return _pressureUpdates; }
- (NSUInteger)duplicates { return _duplicates; }
- (void)reset { memset(_held,0,sizeof(_held)); memset(_peak,0,sizeof(_peak)); }
- (NSArray<NSDictionary *> *)consumeBatch:(NSData *)data time:(double)time {
    if(data.length<16 || readWord(data,0)!=0x03504e00)return nil;
    uint32_t count=readWord(data,12);
    if(count==0 || count>256 || data.length!=16+(NSUInteger)count*12)return nil;
    NSMutableArray *packets=[NSMutableArray array];
    // Validate the entire batch before changing per-pad state.
    for(uint32_t i=0;i<count;i++) {
        NSUInteger offset=16+i*12;uint32_t bits=readWord(data,offset+8);float value;memcpy(&value,&bits,4);
        if(readWord(data,offset)>=16 || readWord(data,offset+4)>4 || !isfinite(value) || value<0 || value>1 || !isfinite(time))return nil;
        NSMutableData *single=[[data subdataWithRange:NSMakeRange(0,16)]mutableCopy];
        uint32_t one=CFSwapInt32HostToLittle(1);[single replaceBytesInRange:NSMakeRange(12,4) withBytes:&one];
        [single appendData:[data subdataWithRange:NSMakeRange(offset,12)]];[packets addObject:single];
    }
    NSMutableArray *events=[NSMutableArray array];
    for(NSData *single in packets) { NSMutableDictionary *event=[[self consume:single time:time]mutableCopy];event[@"batch_count"]=@(count);[events addObject:event]; }
    return events;
}
- (NSDictionary *)consume:(NSData *)data time:(double)time {
    if(data.length!=28 || readWord(data,0)!=0x03504e00) return nil;
    uint32_t code=readWord(data,16),state=readWord(data,20),bits=readWord(data,24);
    float value; memcpy(&value,&bits,4);
    if(code>=16 || state>4 || !isfinite(value) || value<0 || value>1 || !isfinite(time)) return nil;
    NSString *type;
    if(state==4) { _pressureUpdates++; type=@"pressure"; if(_held[code])_peak[code]=fmaxf(_peak[code],value); }
    else if(state==0 || state==1) {
        if(value==0) type=@"invalid_attack";
        else if(_held[code]) { _duplicates++; type=@"duplicate_attack"; }
        else { _held[code]=YES; _started[code]=time; _peak[code]=value; _hits++; type=@"hit_candidate"; }
    } else {
        if(_held[code]) { _held[code]=NO; _releases++; type=@"release_candidate"; }
        else type=@"orphan_release";
    }
    NSMutableDictionary *result=[@{@"event":@"pad_decoded",@"interpretation":@"capture_inferred_v1",
        @"kind":type,@"pad":@((3-code/4)*4+code%4+1),@"raw_pad":@(code),
        @"raw_state":@(state),@"raw_value":@(value),@"held":@(_held[code]),
        @"hit_count":@(_hits),@"release_count":@(_releases)} mutableCopy];
    if([type isEqual:@"release_candidate"]) {
        result[@"hold_ms"]=@(fmax(0,(time-_started[code])*1000));
        result[@"pressure_peak"]=@(_peak[code]);
    }
    return result;
}
@end
