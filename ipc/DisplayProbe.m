#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import "NativePadLights.h"
#import "PadInspector.h"
#import "DeviceMonitor.h"
#include <stdatomic.h>

static atomic_bool serverStop;
static MLPPadInspector *padInspector;

// Independent, bounded diagnostic using NI's local agent IPC.
// Wire format reference: terminar/rebellion (see display/README.md).
static void emit(NSDictionary *value) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout); fflush(stdout);
}
static NSData *words(const uint32_t *values,size_t count) {
    NSMutableData *data=[NSMutableData data];
    for(size_t i=0;i<count;i++){uint32_t x=CFSwapInt32HostToLittle(values[i]);[data appendBytes:&x length:4];}
    return data;
}
static NSData *request(CFMessagePortRef port,NSData *data,NSString *stage) {
    CFDataRef reply=NULL;
    SInt32 status=CFMessagePortSendRequest(port,0,(__bridge CFDataRef)data,2,2,kCFRunLoopDefaultMode,&reply);
    NSData *result=CFBridgingRelease(reply);
    uint32_t first=0;if(result.length>=4)memcpy(&first,result.bytes,4);
    emit(@{@"event":@"request",@"stage":stage,@"status":@(status),@"reply_bytes":@(result.length),@"reply_word":@(CFSwapInt32LittleToHost(first))});
    return status==kCFMessagePortSuccess ? result : nil;
}
static uint32_t read32(NSData *data,NSUInteger offset) {
    uint32_t x=0;if(offset+4<=data.length)memcpy(&x,(const uint8_t *)data.bytes+offset,4);
    return CFSwapInt32LittleToHost(x);
}
static NSArray *ports(NSData *reply) {
    if(reply.length<12||read32(reply,0)!=0x74727565)return nil;
    uint32_t a=read32(reply,4);
    if(a<2||a>4096||8+a+4>reply.length)return nil;
    uint32_t b=read32(reply,8+a);
    if(b<2||b>4096||12+a+b>reply.length)return nil;
    NSString *first=[[NSString alloc]initWithBytes:(const uint8_t *)reply.bytes+8 length:a-1 encoding:NSUTF8StringEncoding];
    NSString *second=[[NSString alloc]initWithBytes:(const uint8_t *)reply.bytes+12+a length:b-1 encoding:NSUTF8StringEncoding];
    return first&&second ? @[first,second] : nil;
}
static CFDataRef notification(CFMessagePortRef port,SInt32 msgid,CFDataRef data,void *info) {
    NSData *packet=(__bridge NSData *)data;
    uint32_t kind=read32(packet,0);
    if(info&&packet.length<=4096&&(kind==0x03504e00||kind==0x03734e00||kind==0x03654e00||kind==0x03774e00||kind==0x03744e00))
        emit(@{@"event":@"hardware",@"message_id":@(kind),@"packet":[packet base64EncodedStringWithOptions:0]});
    else emit(@{@"event":@"notification",@"bytes":@(packet.length)});
    if(info && kind==0x03504e00 && padInspector) {
        for(NSDictionary *event in [padInspector consumeBatch:packet time:NSProcessInfo.processInfo.systemUptime]) {
            NSString *type=event[@"kind"];
            if([type isEqual:@"hit_candidate"] || [type isEqual:@"release_candidate"]) emit(event);
        }
    }
    uint32_t yes=CFSwapInt32HostToLittle(0x74727565);
    return CFDataCreate(NULL,(const UInt8 *)&yes,4);
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==2 && strcmp(argv[1],"--list-devices")==0) {
        emit(@{@"devices": MLPConnectedDevices()});
        return 0;
    }
    if((argc==5||argc==6)&&(strcmp(argv[1],"--send")==0||strcmp(argv[1],"--native")==0||strcmp(argv[1],"--status")==0||strcmp(argv[1],"--serve")==0||strcmp(argv[1],"--led-only")==0)) {
        BOOL ledOnly=strcmp(argv[1],"--led-only")==0;
        if(ledOnly) padInspector=[MLPPadInspector new];
        BOOL serve=ledOnly||strcmp(argv[1],"--serve")==0;
        BOOL native=strcmp(argv[1],"--native")==0||serve;
        BOOL statusOnly=strcmp(argv[1],"--status")==0;
        int hold=argc==6?atoi(argv[5]):3;if(hold<1||hold>60)return 1;
        uint32_t pid=(uint32_t)strtoul(argv[2],NULL,16);
        if(pid!=0x1820&&pid!=0x1600){emit(@{@"event":@"error",@"reason":@"Unsupported device"});return 1;}
        NSData *serial=[[NSString stringWithUTF8String:argv[3]] dataUsingEncoding:NSASCIIStringEncoding];
        NSData *frame=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[4]]];
        if(!serial.length||serial.length>128||(!ledOnly&&!frame.length)||frame.length>300000)return 1;
        CFMessagePortRef agent=CFMessagePortCreateRemote(NULL,CFSTR("com.native-instruments.NIHostIntegrationAgent"));
        if(!agent){emit(@{@"event":@"error",@"reason":@"NI agent unavailable"});return 1;}
        uint32_t deviceHello[]={0x03447500,pid,0x4e694d32,0x70726d79,0};
        NSArray *deviceNames=ports(request(agent,words(deviceHello,5),@"device_connect"));
        if(!deviceNames){CFRelease(agent);emit(@{@"event":@"error",@"reason":@"Agent refused device session"});return 1;}
        CFMessagePortContext deviceContext={0,NULL,NULL,NULL,NULL};Boolean deviceFree=false;
        CFMessagePortRef deviceLocal=CFMessagePortCreateLocal(NULL,(__bridge CFStringRef)deviceNames[1],notification,&deviceContext,&deviceFree);
        CFMessagePortRef deviceRemote=CFMessagePortCreateRemote(NULL,(__bridge CFStringRef)deviceNames[0]);
        if(!deviceLocal||!deviceRemote){CFRelease(agent);return 1;}
        CFRunLoopSourceRef deviceSource=CFMessagePortCreateRunLoopSource(NULL,deviceLocal,0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(),deviceSource,kCFRunLoopDefaultMode);
        NSData *deviceName=[deviceNames[1] dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t deviceAck[]={0x03404300,0x74727565,0,(uint32_t)deviceName.length};
        NSMutableData *deviceAckData=[words(deviceAck,4) mutableCopy];[deviceAckData appendData:deviceName];uint8_t deviceZero=0;[deviceAckData appendBytes:&deviceZero length:1];
        request(deviceRemote,deviceAckData,@"device_notification_ack");
        uint32_t deviceState=0x03447143;request(deviceRemote,words(&deviceState,1),@"device_state");
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,.25,false);
        uint32_t connect[]={0x03444900,pid,0x4e694d32,0x70726d79,(uint32_t)serial.length+1};
        NSMutableData *hello=[words(connect,5) mutableCopy];[hello appendData:serial];uint8_t serialZero=0;[hello appendBytes:&serialZero length:1];
        NSArray *names=ports(request(agent,hello,@"serial_connect"));CFRelease(agent);
        if(!names){emit(@{@"event":@"error",@"reason":@"Agent refused display session"});return 1;}
        CFMessagePortContext context={0,(void *)1,NULL,NULL,NULL};Boolean shouldFree=false;
        CFMessagePortRef local=CFMessagePortCreateLocal(NULL,(__bridge CFStringRef)names[1],notification,&context,&shouldFree);
        CFMessagePortRef remote=CFMessagePortCreateRemote(NULL,(__bridge CFStringRef)names[0]);
        if(!local||!remote){if(local)CFRelease(local);if(remote)CFRelease(remote);return 1;}
        CFRunLoopSourceRef source=CFMessagePortCreateRunLoopSource(NULL,local,0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(),source,kCFRunLoopDefaultMode);
        NSData *name=[names[1] dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t ack[]={0x03404300,0x74727565,0,(uint32_t)name.length};
        NSMutableData *ackdata=[words(ack,4) mutableCopy];[ackdata appendData:name];uint8_t zero=0;[ackdata appendBytes:&zero length:1];
        request(remote,ackdata,@"notification_ack");
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,.25,false);
        uint32_t mode[]={0x0344674d,pid};NSData *modeReply=request(remote,words(mode,2),@"mode_query");
        emit(@{@"event":@"mode",@"value":@(read32(modeReply,0))});
        if(native) {
            uint32_t keycount[]={0x03566775,0x4b657973};request(remote,words(keycount,2),@"key_count");
            uint32_t rkeys[]={0x03566775,0x524b6579};request(remote,words(rkeys,2),@"rotary_count");
            NSData *label=[@"MLP display test" dataUsingEncoding:NSASCIIStringEncoding];
            uint32_t labelHeader[]={0x0349734e,0x70001006,0xf6b24000,(uint32_t)label.length+1};
            NSMutableData *labelData=[words(labelHeader,4) mutableCopy];[labelData appendData:label];[labelData appendBytes:&zero length:1];
            request(remote,labelData,@"instance_name");
            uint32_t start[]={0x03434300,0x73747274};request(remote,words(start,2),@"native_start");
            uint32_t tsi[]={0x03497354,0};request(remote,words(tsi,2),@"instance_setup");
            uint32_t focus=0x03436746;request(remote,words(&focus,1),@"focus_request");
            uint32_t active[]={0x03497374,0x74727565};request(remote,words(active,2),@"instance_active");
            uint32_t rd[]={0x03445200,2};request(remote,words(rd,2),@"device_setup");
            uint32_t ad[]={0x03444100,3,0,0x04e297b0};request(remote,words(ad,4),@"application_setup");
            CFRunLoopRunInMode(kCFRunLoopDefaultMode,.5,false);
            NSData *after=request(remote,words(mode,2),@"mode_after_focus");
            emit(@{@"event":@"native_mode",@"value":@(read32(after,0))});
        }
        uint32_t header[]={0x03647344,0,0,0x01e00110,(uint32_t)frame.length};
        NSMutableData *message=[words(header,5) mutableCopy];[message appendData:frame];
        NSData *response=(statusOnly||ledOnly)?nil:request(remote,message,@"left_display");
        BOOL accepted=ledOnly||(response.length>=4&&read32(response,0)==0x74727565);
        if(!statusOnly&&!ledOnly)emit(@{@"event":@"display_attempt",@"transport_reply":@(response!=nil),@"agent_accepted":@(accepted),@"visual_confirmation_required":@YES});
        if(serve&&accepted) {
            atomic_store(&serverStop,false);
            CFRunLoopRef mainLoop=CFRunLoopGetCurrent();
            // MLP owns the native LED bank. MK3/Plus: 62 button + 25 strip + 16 pad slots.
            NSMutableData *ledBank=[NSMutableData dataWithLength:103];
            // NI IPC values encode color and intensity, not intensity alone.
            // Establish dim white button/pad feedback; the unbound touchstrip remains off.
            uint8_t *baseline=ledBank.mutableBytes;
            for(int i=0;i<62;i++)baseline[i]=(17<<2)|1;
            for(int i=87;i<103;i++)baseline[i]=(17<<2)|1;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                char *line=NULL;size_t capacity=0;
                while(getline(&line,&capacity,stdin)>0) {@autoreleasepool {
                    NSData *json=[[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *command=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
                    if(![command isKindOfClass:[NSDictionary class]])continue;
                    if([command[@"quit"] boolValue])break;
                    id padLEDs=command[@"pad_leds"];
                    if(padLEDs && (pid==0x1600 || pid==0x1820)){
                        NSNumber *identifier=command[@"request_id"]?:@0;
                        if(!MLPApplyPadLEDs([NSMutableData dataWithLength:103],padLEDs)){
                            emit(@{@"event":@"pad_led_update",@"request_id":identifier,@"transport_success":@NO,@"reason":@"Invalid complete pad LED array"});continue;
                        }
                        CFRunLoopPerformBlock(mainLoop,kCFRunLoopDefaultMode,^{
                            // Merge into the latest bank so FIXED VEL/button feedback survives.
                            MLPApplyPadLEDs(ledBank,padLEDs);
                            uint32_t h[]={0x036c7500,(uint32_t)ledBank.length};
                            NSMutableData *body=[words(h,2)mutableCopy];[body appendData:ledBank];
                            CFDataRef response=NULL;
                            SInt32 status=CFMessagePortSendRequest(remote,0,(__bridge CFDataRef)body,2,2,kCFRunLoopDefaultMode,&response);
                            NSData *answer=CFBridgingRelease(response);
                            emit(@{@"event":@"pad_led_update",@"request_id":identifier,@"leds":padLEDs,
                                   @"transport_success":@(status==kCFMessagePortSuccess),@"status":@(status),
                                   @"reply_bytes":@(answer.length),@"reply_word":@(read32(answer,0))});
                        });CFRunLoopWakeUp(mainLoop);continue;
                    }
                    if(ledOnly)continue;
                    id stripFeedback=command[@"strip_feedback"];
                    if(stripFeedback&&(pid==0x1600||pid==0x1820)){
                        NSNumber *identifier=command[@"request_id"]?:@0;
                        if(!MLPApplyStripFeedback([NSMutableData dataWithLength:103],stripFeedback)){
                            emit(@{@"event":@"strip_led_update",@"request_id":identifier,@"transport_success":@NO});continue;
                        }
                        CFRunLoopPerformBlock(mainLoop,kCFRunLoopDefaultMode,^{
                            MLPApplyStripFeedback(ledBank,stripFeedback);
                            uint32_t h[]={0x036c7500,(uint32_t)ledBank.length};NSMutableData *body=[words(h,2)mutableCopy];[body appendData:ledBank];CFDataRef reply=NULL;
                            SInt32 status=CFMessagePortSendRequest(remote,0,(__bridge CFDataRef)body,2,2,kCFRunLoopDefaultMode,&reply);
                            if(reply)CFRelease(reply);
                            emit(@{@"event":@"strip_led_update",@"request_id":identifier,@"transport_success":@(status==kCFMessagePortSuccess),@"status":@(status)});
                        });CFRunLoopWakeUp(mainLoop);continue;
                    }
                    BOOL playCommand=command[@"play_led"]!=nil;
                    BOOL stepCommand=command[@"step_led"]!=nil;
                    BOOL mixerCommand=command[@"mixer_led"]!=nil;
                    BOOL muteCommand=command[@"mute_led"]!=nil;
                    BOOL soloCommand=command[@"solo_led"]!=nil;
                    BOOL selectCommand=command[@"select_led"]!=nil;
                    NSNumber *fixedLED=playCommand?command[@"play_led"]:stepCommand?command[@"step_led"]:mixerCommand?command[@"mixer_led"]:muteCommand?command[@"mute_led"]:soloCommand?command[@"solo_led"]:selectCommand?command[@"select_led"]:command[@"fixed_vel_led"];
                    NSUInteger ledSlot=playCommand?41:stepCommand?49:mixerCommand?3:muteCommand?57:soloCommand?56:selectCommand?55:45;
                    if([fixedLED isKindOfClass:NSNumber.class] && (pid==0x1600 || pid==0x1820) &&
                       ((playCommand||soloCommand||selectCommand)?(fixedLED.doubleValue==0 || fixedLED.doubleValue==3|| ((soloCommand||selectCommand)&&fixedLED.doubleValue==1)):(fixedLED.doubleValue==1 || fixedLED.doubleValue==3))) {
                        CFRunLoopPerformBlock(mainLoop,kCFRunLoopDefaultMode,^{
                            // STEP is slot 49, FIXED VEL is 45; slot 44 belongs to SHIFT.
                            // Button input codes and LED slots are independent.
                            uint8_t encoded=playCommand?(fixedLED.intValue?((7<<2)|3):0):(fixedLED.intValue?((17<<2)|fixedLED.unsignedCharValue):0);
                            ((uint8_t *)ledBank.mutableBytes)[ledSlot]=encoded;
                            uint32_t h[]={0x036c7500,(uint32_t)ledBank.length};
                            NSMutableData *body=[words(h,2)mutableCopy];[body appendData:ledBank];
                            CFDataRef response=NULL;
                            SInt32 status=CFMessagePortSendRequest(remote,0,(__bridge CFDataRef)body,2,2,kCFRunLoopDefaultMode,&response);
                            NSData *answer=CFBridgingRelease(response);
                            emit(@{@"event":@"led_update",@"led_slot":@(ledSlot),@"brightness":fixedLED,@"encoded_value":@(encoded),@"baseline":@"dim_white_buttons_pads",
                                   @"transport_success":@(status==kCFMessagePortSuccess),@"status":@(status),
                                   @"reply_bytes":@(answer.length),@"reply_word":@(read32(answer,0))});
                        });CFRunLoopWakeUp(mainLoop);continue;
                    }
                    NSString *path=command[@"frame"];NSNumber *screen=command[@"screen"];
                    if(![path isKindOfClass:[NSString class]]||![screen isKindOfClass:[NSNumber class]]||screen.intValue<0||screen.intValue>1)continue;
                    NSData *next=[NSData dataWithContentsOfFile:path];
                    if(next.length<24||next.length>300000||((const uint8_t *)next.bytes)[2]!=screen.intValue)continue;
                    NSNumber *identifier=command[@"request_id"]?:@0;
                    CFRunLoopPerformBlock(mainLoop,kCFRunLoopDefaultMode,^{
                        CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
                        uint32_t h[]={0x03647344,(uint32_t)screen.intValue,0,0x01e00110,(uint32_t)next.length};
                        NSMutableData *body=[words(h,5) mutableCopy];[body appendData:next];
                        NSData *answer=request(remote,body,@"screen_update");
                        emit(@{@"event":@"screen_update",@"screen":screen,@"request_id":identifier,@"accepted":@(read32(answer,0)==0x74727565),@"request_ms":@((CFAbsoluteTimeGetCurrent()-began)*1000)});
                    });CFRunLoopWakeUp(mainLoop);
                }}
                free(line);atomic_store(&serverStop,true);CFRunLoopWakeUp(mainLoop);
            });
            emit(@{@"event":@"ready",@"mode":@"APP",@"native":@YES});
            while(!atomic_load(&serverStop)&&CFMessagePortIsValid(remote))CFRunLoopRunInMode(kCFRunLoopDefaultMode,.2,false);
            emit(@{@"event":@"closed",@"midi_restore":@"manual_shift_channel"});
        }
        CFAbsoluteTime until=CFAbsoluteTimeGetCurrent()+(statusOnly?0:hold);
        while(!serve&&CFAbsoluteTimeGetCurrent()<until) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode,1,false);
            if(!CFMessagePortIsValid(remote))break;
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),source,kCFRunLoopDefaultMode);
        CFMessagePortInvalidate(local);CFRelease(source);CFRelease(local);CFRelease(remote);
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),deviceSource,kCFRunLoopDefaultMode);
        CFMessagePortInvalidate(deviceLocal);CFRelease(deviceSource);CFRelease(deviceLocal);CFRelease(deviceRemote);
        return statusOnly||accepted?0:1;
    }
    for(NSString *name in @[@"com.native-instruments.NIHostIntegrationAgent",@"NIHWMainHandler"]) {
        CFMessagePortRef port=CFMessagePortCreateRemote(NULL,(__bridge CFStringRef)name);
        emit(@{@"event":@"agent",@"name":name,@"available":@(port!=NULL)});
        if(port){uint32_t version=0x03536756;request(port,words(&version,1),@"version");CFRelease(port);}
    }
    return 0;
}}
