#import "NativePadLights.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

static NSDictionary *asDict(id value){return [value isKindOfClass:NSDictionary.class]?value:@{};}
static BOOL integer(id value,NSUInteger maximum){
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() &&
           isfinite([value doubleValue]) && [value doubleValue]>=0 && [value doubleValue]<=maximum &&
           [value doubleValue]==floor([value doubleValue]);
}
NSDictionary *MLPPadLightState(NSDictionary *screens,BOOL noteContextValid,NSUInteger enabledPads){
    NSDictionary *right=asDict(screens[@"right"]),*color=asDict(right[@"pad_color"]);
    id rgb=color[@"rgb"];BOOL available=[color[@"status"]isEqual:@"available"] && integer(rgb,0xFFFFFF);
    // NI's fixed hue families; centers are an approximation, not measured LED RGBs.
    const double centers[]={0,20,30,45,60,85,120,155,180,200,240,255,270,285,305,330};
    NSArray *names=@[@"red",@"orange",@"light_orange",@"warm_yellow",@"yellow",@"lime",@"green",@"mint",@"cyan",@"turquoise",@"blue",@"plum",@"violet",@"purple",@"magenta",@"fuchsia",@"white"];
    NSUInteger palette=17;NSString *method=available?@"neutral_white":@"missing_color_white";
    if(available){uint32_t value=[rgb unsignedIntValue];double r=((value>>16)&255)/255.,g=((value>>8)&255)/255.,b=(value&255)/255.;
        double hi=fmax(r,fmax(g,b)),lo=fmin(r,fmin(g,b)),range=hi-lo;
        if(hi>0 && range/hi>=.12){
            double hue=hi==r?60*fmod((g-b)/range,6):hi==g?60*((b-r)/range+2):60*((r-g)/range+4);
            if(hue<0)hue+=360;double nearest=361;
            for(NSUInteger i=0;i<16;i++){double distance=fabs(hue-centers[i]);distance=fmin(distance,360-distance);
                if(distance<nearest){nearest=distance;palette=i+1;}}
            method=@"nearest_hue";
        }
    }
    id rows=asDict(right[@"pad_map"])[@"pads"];
    BOOL active=noteContextValid && [screens[@"status"]isEqual:@"context_ready"] && [rows isKindOfClass:NSArray.class] && [rows count]==16;
    id guide=[screens[@"guide_enabled"]isEqual:@NO]?nil:screens[@"guide_pads"];
    NSArray *guidePads=[guide isKindOfClass:NSArray.class]?guide:@[];
    NSMutableArray *leds=[NSMutableArray arrayWithCapacity:16];
    for(NSUInteger i=0;i<16;i++){
        NSDictionary *pad=active?asDict(rows[i]):@{};
        BOOL playable=active && i<enabledPads && [pad[@"status"]isEqual:@"planned"] && integer(pad[@"input_midi"],127);
        BOOL root=[pad[@"is_root"]isKindOfClass:NSNumber.class] && [pad[@"is_root"]boolValue];
        NSUInteger brightness=root?3:1;
        BOOL guided=[guidePads containsObject:@(i+1)];
        NSUInteger led=guided?((17u<<2)|2u):((palette<<2)|brightness);
        [leds addObject:@(playable?led:0)];
    }
    return @{@"leds":leds,@"palette_id":@(palette),@"palette_name":names[palette-1],@"method":method,
             @"rgb":available?rgb:NSNull.null,@"source_chain_name":color[@"source_chain_name"]?:NSNull.null,
             @"source_chain_path":color[@"source_chain_path"]?:NSNull.null,@"active":@(active),
             @"root_brightness":@3,@"other_brightness":@1};
}
BOOL MLPApplyPadLEDs(NSMutableData *bank,id values){
    if(bank.length!=103 || ![values isKindOfClass:NSArray.class] || [values count]!=16)return NO;
    for(id item in values){if(!integer(item,71))return NO;
        NSUInteger value=[item unsignedIntegerValue];if(value && (!(value>>2)))return NO;}
    uint8_t *bytes=bank.mutableBytes;
    for(NSUInteger i=0;i<16;i++){
        NSUInteger raw=(3-i/4)*4+i%4;bytes[87+raw]=[values[i]unsignedCharValue];
    }
    return YES;
}

@implementation MLPPadWave {
    NSMutableArray *_hits;
    BOOL _down;
}
- (instancetype)init {if((self=[super init])){_hits=[NSMutableArray new];_tempoBPM=120;}return self;}
- (BOOL)active {return self.enabled && _hits.count>0;}
- (BOOL)button:(BOOL)down {
    BOOL edge=down&&!_down;_down=down;
    if(edge){self.enabled=!self.enabled;[self reset];}return edge;
}
- (void)reset {[_hits removeAllObjects];}
- (void)hit:(NSUInteger)pad time:(double)time {
    if(!self.enabled||pad<1||pad>16||!isfinite(time))return;
    if(_hits.count>=16)[_hits removeObjectAtIndex:0];
    double bpm=isfinite(self.tempoBPM)&&self.tempoBPM>=20&&self.tempoBPM<=999?self.tempoBPM:120;
    [_hits addObject:@{@"pad":@(pad-1),@"time":@(time),@"duration":@(60./bpm)}];
}
- (NSArray *)apply:(NSArray *)baseline time:(double)time {
    if(!self.enabled){[self reset];return baseline;}
    NSIndexSet *expired=[_hits indexesOfObjectsPassingTest:^BOOL(NSDictionary *h,NSUInteger i,BOOL *stop){double age=time-[h[@"time"]doubleValue];return age<0||age>=[h[@"duration"]doubleValue];}];
    [_hits removeObjectsAtIndexes:expired];
    if(baseline.count!=16||!_hits.count)return baseline;
    NSMutableArray *out=[baseline mutableCopy];
    for(NSUInteger i=0;i<16;i++){
        NSUInteger value=[baseline[i]unsignedIntegerValue];if(!value)continue;
        BOOL whitePeak=NO;
        NSUInteger coloredBrightness=value&3;
        for(NSDictionary *hit in _hits){NSUInteger origin=[hit[@"pad"]unsignedIntegerValue];
            double distance=hypot((double)(i%4)-(double)(origin%4),(double)(i/4)-(double)(origin/4));
            double duration=[hit[@"duration"]doubleValue];
            double age=time-[hit[@"time"]doubleValue],arrival=distance*duration*.15;
            if(age>=arrival&&age<arrival+duration*.30){
                // Keep the layer hue through the pulse; only its short peak uses dim white.
                double phase=(age-arrival)/(duration*.30);
                if(phase>=.45&&phase<.70)whitePeak=YES;
                NSUInteger level=(phase<.25||phase>=.85)?2:3;
                coloredBrightness=MAX(coloredBrightness,level);
            }
        }
        out[i]=whitePeak?@((17u<<2)|1u):@((value&~3u)|coloredBrightness);
    }return out;
}
@end

BOOL MLPApplyStripFeedback(NSMutableData *bank,id feedback){
    if(bank.length!=103||![feedback isKindOfClass:NSDictionary.class])return NO;
    NSString *mode=feedback[@"mode"];NSArray *leds=feedback[@"leds"];
    if(!([mode isEqual:@"pitch"]||[mode isEqual:@"mod"])||![leds isKindOfClass:NSArray.class]||leds.count!=25)return NO;
    for(id value in leds)if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||[value doubleValue]!=[value intValue]||[value intValue]<0||[value intValue]>127)return NO;
    uint8_t *bytes=bank.mutableBytes;for(int i=0;i<25;i++)bytes[62+i]=[leds[i]unsignedCharValue];
    bytes[25]=(17<<2)|([mode isEqual:@"pitch"]?3:1);bytes[26]=(17<<2)|([mode isEqual:@"mod"]?3:1);return YES;
}
