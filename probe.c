#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static MIDIEndpointRef source, destination;
static MIDIPortRef testOutput;
static int replyEnabled = 1, selfTest, padInput;
static UInt8 sysex[4096];
static size_t length;

static void check(OSStatus status, const char *operation) {
    if (status) {
        fprintf(stderr, "%s: OSStatus %d\n", operation, (int)status);
        exit(1);
    }
}

static void logBytes(const char *label, const UInt8 *bytes, size_t count) {
    struct timeval now;
    gettimeofday(&now, NULL);
    flockfile(stdout);
    printf("%lld.%03ld %s", (long long)now.tv_sec, (long)(now.tv_usec / 1000), label);
    for (size_t i = 0; i < count; i++) printf(" %02X", bytes[i]);
    puts("");
    funlockfile(stdout);
}

static void sendBytes(MIDIPortRef output, MIDIEndpointRef endpoint,
                      const UInt8 *bytes, size_t count) {
    MIDIPacketList list;
    MIDIPacket *packet = MIDIPacketListInit(&list);
    if (!MIDIPacketListAdd(&list, sizeof list, packet, 0, count, bytes)) exit(1);
    check(output ? MIDISend(output, endpoint, &list) : MIDIReceived(endpoint, &list),
          output ? "MIDISend" : "MIDIReceived");
}

static void *readPadInput(void *unused) {
    (void)unused;
    char line[128];
    unsigned channel, note, velocity;
    while (fgets(line, sizeof line, stdin)) {
        if (sscanf(line, "%u %u %u", &channel, &note, &velocity) != 3 ||
            channel < 1 || channel > 16 || note > 127 || velocity > 127) continue;
        UInt8 bytes[] = {(UInt8)((velocity ? 0x90 : 0x80) | (channel - 1)), note, velocity};
        logBytes("PAD TX", bytes, sizeof bytes);
        sendBytes(0, source, bytes, sizeof bytes);
    }
    return NULL;
}

static MIDIEndpointRef mk3;
static MIDIPortRef mk3Output;
static int dryRun, ipcGrid;

static void translate(const MIDIPacket *packet) {
    for (UInt16 i = 0; i + 2 < packet->length; i++) {
        const UInt8 *msg = packet->data + i;
        if ((msg[0] != 0x90 && msg[0] != 0x80) || msg[2] >= 0x80) continue;
        int row = msg[1] / 10, column = msg[1] % 10;
        if (row < 1 || row > 4 || column < 1 || column > 4) continue;
        if (!ipcGrid && (row != 1 || column > 2)) continue;
        i += 2;
        UInt8 color;
        if (msg[0] == 0x80 || msg[2] == 0) color = 0;
        else if (msg[2] == 0x48 || msg[2] == 0x15) color = 46;
        else if (msg[2] == 0x03) color = 6;
        else continue;
        UInt8 out[] = {0x90, (UInt8)(36 + (row - 1) * 4 + column - 1), color};
        if (mk3) sendBytes(mk3Output, mk3, out, sizeof out);
        logBytes(mk3 ? "MK3 TX" : "MK3 DRY RUN", out, sizeof out);
    }
}

static void configureOutput(MIDIClientRef client, const char *name) {
    unsigned matches = 0;
    for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++) {
        MIDIEndpointRef endpoint = MIDIGetDestination(i);
        CFStringRef label = NULL;
        if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &label) || !label)
            continue;
        char display[1024];
        if (CFStringGetCString(label, display, sizeof display, kCFStringEncodingUTF8)) {
            if (!name) puts(display);
            else if (!strcmp(display, name)) {
                mk3 = endpoint;
                matches++;
            }
        }
        CFRelease(label);
    }
    if (!name) return;
    if (matches != 1) {
        fprintf(stderr, "Expected one destination named %s, found %u. Use --list-outputs.\n",
                name, matches);
        exit(1);
    }
    check(MIDIOutputPortCreate(client, CFSTR("MK3 LED output"), &mk3Output), "MK3 output");
}

static const UInt8 inquiry[] = {0xf0, 0x7e, 0x7f, 6, 1, 0xf7};
static UInt8 identity[] = {
    0xf0, 0x7e, 1, 6, 2, 0, 0x20, 0x29, 0x69, 0, 0, 0, 0, 1, 3, 8, 0xf7
};

static void receive(const MIDIPacketList *list, void *context, void *connection) {
    (void)context;
    (void)connection;
    const MIDIPacket *packet = &list->packet[0];
    for (UInt32 p = 0; p < list->numPackets; p++, packet = MIDIPacketNext(packet)) {
        logBytes(selfTest ? "TEST RX packet" : "RX packet", packet->data, packet->length);
        if (mk3 || dryRun) translate(packet);
        for (UInt16 i = 0; i < packet->length; i++) {
            UInt8 byte = packet->data[i];
            if (byte >= 0xf8) continue;
            if (byte == 0xf0) length = 0;
            else if (!length) continue;
            else if ((byte & 0x80) && byte != 0xf7) { length = 0; continue; }
            if (length == sizeof sysex) { length = 0; continue; }
            sysex[length++] = byte;
            if (byte != 0xf7) continue;
            logBytes("RX SysEx", sysex, length);
            if (length == sizeof inquiry && !memcmp(sysex, inquiry, 2) &&
                (sysex[2] == inquiry[2] || sysex[2] == identity[2]) &&
                !memcmp(sysex + 3, inquiry + 3, 3)) {
                if (replyEnabled) {
                    logBytes("TX Identity Reply", identity, sizeof identity);
                    sendBytes(0, source, identity, sizeof identity);
                } else {
                    puts("Identity Reply disabled");
                }
            }
            length = 0;
        }
    }
}

static void verify(const MIDIPacketList *list, void *context, void *connection) {
    (void)context;
    (void)connection;
    const MIDIPacket *packet = &list->packet[0];
    for (UInt32 p = 0; p < list->numPackets; p++, packet = MIDIPacketNext(packet)) {
        logBytes("TEST observed source", packet->data, packet->length);
        if (padInput) {
            static unsigned observed;
            const UInt8 hit[] = {0x90, 12, 64}, release[] = {0x80, 12, 0};
            for (UInt16 i = 0; i + 2 < packet->length; i += 3) {
                if (!memcmp(packet->data + i, observed ? release : hit, 3) && ++observed == 2) {
                    puts("PASS: pad hit and release observed on virtual source");
                    exit(0);
                }
            }
            continue;
        }
        if (packet->length == sizeof identity && !memcmp(packet->data, identity, sizeof identity)) {
            puts("PASS: virtual destination -> inquiry -> virtual source");
            fflush(stdout);
            exit(0);
        }
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *outputName = NULL;
    int listOutputs = 0;
    const char *name = "Launchpad MK2";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-reply")) replyEnabled = 0;
        else if (!strcmp(argv[i], "--list-outputs")) listOutputs = 1;
        else if (!strcmp(argv[i], "--mk3-dry-run")) dryRun = 1;
        else if (!strcmp(argv[i], "--ipc-grid")) ipcGrid = dryRun = 1;
        else if (!strcmp(argv[i], "--mk3-out") && i + 1 < argc) outputName = argv[++i];
        else if (!strcmp(argv[i], "--pad-input")) padInput = 1;
        else if (!strcmp(argv[i], "--self-test")) selfTest = 1;
        else if (!strcmp(argv[i], "--id") && i + 1 < argc) {
            char *end;
            long id = strtol(argv[++i], &end, 0);
            if (end == argv[i] || *end || id < 0 || id > 126) return 2;
            identity[2] = (UInt8)id;
        }
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else {
            fprintf(stderr, "Usage: %s [--name NAME] [--id ID] [--pad-input] [--no-reply | --self-test] [--list-outputs | --mk3-dry-run | --ipc-grid | --mk3-out NAME]\n", argv[0]);
            return 2;
        }
    }
    if ((selfTest && (!replyEnabled || outputName)) || (dryRun && outputName)) return 2;
    if (selfTest) name = "Launchpad MK2 Probe Self Test";
    CFStringRef portName = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!portName) return 2;
    MIDIClientRef client;
    check(MIDIClientCreate(CFSTR("Launchpad MK2 Probe"), NULL, NULL, &client), "MIDIClientCreate");
    if (listOutputs) {
        configureOutput(client, NULL);
        CFRelease(portName);
        return 0;
    }
    if (outputName) configureOutput(client, outputName);
    check(MIDISourceCreate(client, portName, &source), "MIDISourceCreate");
    check(MIDIDestinationCreate(client, portName, receive, NULL, &destination), "MIDIDestinationCreate");
    CFRelease(portName);
    MIDIEntityRef sourceEntity = 0, destinationEntity = 0;
    OSStatus srcStatus = MIDIEndpointGetEntity(source, &sourceEntity);
    OSStatus dstStatus = MIDIEndpointGetEntity(destination, &destinationEntity);
    printf("READY: %s | source entity=%u (status=%d) | destination entity=%u (status=%d)"
           " | identity reply=%s, ID=%02X\n",
           name, sourceEntity, (int)srcStatus, destinationEntity, (int)dstStatus,
           replyEnabled ? "on" : "off", identity[2]);
    if (selfTest) {
        MIDIClientRef tester;
        MIDIPortRef input;
        check(MIDIClientCreate(CFSTR("Probe Loopback Test"), NULL, NULL, &tester), "test client");
        check(MIDIInputPortCreate(tester, CFSTR("Verify"), verify, NULL, &input), "test input");
        check(MIDIPortConnectSource(input, source, NULL), "connect test input");
        check(MIDIOutputPortCreate(tester, CFSTR("Send"), &testOutput), "test output");
        if (!padInput) {
            const UInt8 led[] = {0x90, 0x58, 0x15};
            sendBytes(testOutput, destination, led, sizeof led);
            if (dryRun) {
                const UInt8 sample[] = {
                    0x90, 0x0b, 0x03, 0x90, 0x0c, 0x03,
                    0x90, 0x0b, 0x15, 0x90, 0x0b, 0x03,
                    0x90, 0x0c, 0x15, 0x90, 0x0c, 0x03
                };
                sendBytes(testOutput, destination, sample, sizeof sample);
            }
            sendBytes(testOutput, destination, inquiry, sizeof inquiry);
        }
    }
    if (padInput) {
        pthread_t reader;
        if (pthread_create(&reader, NULL, readPadInput, NULL) != 0) return 1;
        pthread_detach(reader);
    }
    if (selfTest) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3, false);
        fputs("FAIL: expected virtual source messages not observed\n", stderr);
        return 1;
    }
    puts("Listening. Ctrl-C to stop.");
    CFRunLoopRun();
    return 0;
}
