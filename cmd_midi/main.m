//
//  main.m
//  cmd_midi
//
//  Created by bowdidge on 12/21/17.
//  Copyright © 2017 none. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>

#include <mach/mach_time.h>

enum MIDICommands {
    KEY_UP = 0x80,
    KEY_DOWN = 0x90,
    CONT = 0xb0,
    PROGRAM_CHANGE = 0xc0,
    STATUS = 0xf0,
};

@class MIDIControl;
MIDIControl *circuit;
MIDIControl *yamaha;

// Dumps out a MIDI packet in human readable form.
NSString *StringFromPacket(const MIDIPacket *packet)
{
    // Note - this is not an example of MIDI parsing. I'm just dumping
    // some bytes for diagnostics.
    // See comments in PGMidiSourceDelegate for an example of how to
    // interpret the MIDIPacket structure.
    int cmd = packet->data[0] & 0xf0;
    int channel = 1 + packet->data[0] & 0xf;
    switch (cmd) {
        case KEY_DOWN:
            return [NSString stringWithFormat: @"DN ch %d note 0x%02x weight 0x%02x",  channel, packet->data[1], packet->data[2]];
            break;
        case KEY_UP:
            return [NSString stringWithFormat: @"UP ch %d note 0x%02x ", channel, packet->data[1]];
            break;
        case PROGRAM_CHANGE:
            return [NSString stringWithFormat: @"CHANGE ch %d controller %d patch %d",
                    channel, packet->data[1], packet->data[2]];
            break;
        case CONT:
            return [NSString stringWithFormat: @"CONT ch %d knob 0x%02x value 0x%02x ", channel, packet->data[1], packet->data[2]];
        default:
            return [NSString stringWithFormat:@"  %u bytes: [%02x,%02x,%02x]",
                    packet->length,
                    (packet->length > 0) ? packet->data[0] : 0,
                    (packet->length > 1) ? packet->data[1] : 0,
                    (packet->length > 2) ? packet->data[2] : 0
                    ];
    }
}

// Handles sending a stream of events out a MIDI interface.
@interface MIDIOut : NSObject {
    // Note buffer.
};

- (id) initWithClient: (MIDIClientRef) client endpoint: (MIDIEndpointRef) endpoint;
- (void) sendDownNote: (uint8_t) note weight: (uint8_t) weight duration: (uint64_t) duration toChannel: (uint8_t) channel;
- (void) stop;
- (void) runThread;
@end

struct MIDIHandler {
    void (*read)(const MIDIPacketList *packetList, void *readProcRefCon, void *srcConnRefCon);
    void (*notify)(const MIDINotification *message, void *refCon);
};


// Implements a simple interface for controlling a MIDI device.
// TODO(bowdidge): Be able to queue up notes at particular times to schedule playback.
// TODO(bowdidge): Get CC parameters working.
// TODO(bowdidge): Be able to read patches.
// TODO(bowdidge): Route from one device to another.
@interface MIDIControl : NSObject {
    MIDIClientRef client;
    MIDIPortRef inputPort;
    MIDIPortRef outputPort;
    MIDIEndpointRef source;
    MIDIEndpointRef destination;
    
    BOOL dumpEvents;
};

- (id) initWithDeviceNamed: (NSString*) name handler: (struct MIDIHandler) handler;
- (void) sendUpNote: (uint8_t) note channel: (uint8_t) channel;
- (void) sendDownNote: (uint8_t) note weight: (uint8_t) weight channel: (uint8_t) channel;
- (void) sendProgram: (uint8_t) controller  channel: (uint8_t) channel;

- (void) setDumpEvents: (BOOL) dump;
@end

@implementation MIDIControl

- (void) readPackets: (const MIDIPacketList*) packetList {
    const MIDIPacket *packet = &packetList->packet[0];
    static int rise = 0;
    static int weight = 0x7f;
    for (int i=0; i < packetList->numPackets; i++) {
        if (packet->length == 1) {
            // Do nothing.
        } else {
            printf("%s\n", [StringFromPacket(packet) UTF8String]);
        }
        
        // For each key down.
        
        if ((packet->data[0] & 0xf0) == KEY_DOWN) {
            [self sendDownNote: packet->data[1] + rise weight: weight channel: 2];
        } else if ((packet->data[0] & 0xf0) == KEY_UP) {
            [self sendUpNote: packet->data[1] + rise channel: 2];

        } else if ((packet->data[0] & 0xf0) == CONT) {
            if (packet->data[1] == 0x50) {
                rise = packet->data[2];
            } else if (packet->data[1] == 0x51) {
                weight = packet->data[2];
            }
        }
        
        packet = MIDIPacketNext(packet);
    }
    
}

- (void) redirectPackets: (const MIDIPacketList*) packetList  to: (MIDIControl*) other {
    const MIDIPacket *packet = &packetList->packet[0];
    for (int i=0; i < packetList->numPackets; i++) {
        if (packet->length == 1) {
            // Do nothing.
        } else {
            printf("%s\n", [StringFromPacket(packet) UTF8String]);
        }
        
        // For each key down.
        
        if ((packet->data[0] & 0xf0) == KEY_DOWN) {
            [other sendDownNote: packet->data[1] weight: packet->data[2] channel: 1];
        } else if ((packet->data[0] & 0xf0) == KEY_UP) {
            [other sendUpNote: packet->data[1] channel: 1];
        }
        packet = MIDIPacketNext(packet);
    }
}

// Function called when packets arrive.
void ReadFunc(const MIDIPacketList *packetList, void *readProcRefCon, void *srcConnRefCon) {
    MIDIControl* me = (__bridge MIDIControl*) readProcRefCon;
    [me readPackets: packetList];
}

void RedirectReadFunc(const MIDIPacketList *packetList, void *readProcRefCon, void *srcConnRefCon) {
    MIDIControl* me = (__bridge MIDIControl*) readProcRefCon;
    [me redirectPackets: packetList to: circuit];
}

    
// Function called when a MIDI notification arrived.
void NotifyFunc(const MIDINotification *message, void *refCon) {
    printf("notify!\n");
}

struct MIDIHandler default_handler = {ReadFunc, NotifyFunc};

struct MIDIHandler redirect_to_circuit = {RedirectReadFunc, NotifyFunc };

- (id) initWithDeviceNamed: (NSString*) name handler: (struct MIDIHandler) handler {
    bool foundSource = false;
    bool foundDest = false;
    NSString *input_name = [NSString stringWithFormat: @"%@Input", name];
    NSString *output_name = [NSString stringWithFormat: @"%@Output", name];
    CFStringRef name_str = (__bridge CFStringRef) name;
    
    OSStatus s = MIDIClientCreate((__bridge CFStringRef) name, handler.notify, (void*) 0, &client);
    if (s != noErr) {
        printf("MIDIClientCreate failed.\n");
        exit(1);
    }
    s = MIDIInputPortCreate(client, (__bridge CFStringRef) input_name, handler.read, (__bridge void*) self, &inputPort);
    if (s != noErr) {
        printf("MIDI port create failed.\n");
    }
    s = MIDIOutputPortCreate(client, (__bridge CFStringRef) output_name, &outputPort);
    if (s != noErr) {
        printf("MIDI port create failed.\n");
    }
    
    const ItemCount dest_count = MIDIGetNumberOfDestinations();
    const ItemCount source_count = MIDIGetNumberOfSources();
    
    for (ItemCount index = 0; index < source_count; ++index)
    {
        MIDIEndpointRef endpoint = MIDIGetSource(index);
        CFStringRef result = CFSTR("");
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &result);
        printf("Found %s\n", CFStringGetCStringPtr(result, kCFStringEncodingMacRoman));
        if (CFStringCompare(result, name_str, kCFCompareCaseInsensitive) == 0) {
            foundSource = true;
            OSStatus s = MIDIPortConnectSource(inputPort, endpoint, 0);
            if (s != noErr) {
                printf("connect failed.\n");
            }
        }
    }
    
    for (ItemCount index = 0; index < dest_count; ++index)
    {
        MIDIEndpointRef endpoint = MIDIGetDestination(index);
        if (!endpoint) continue;
        
        CFStringRef result = CFSTR("");
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &result);
        
        if (CFStringCompare(result, name_str, kCFCompareCaseInsensitive) == 0) {
            foundDest = true;
            destination = endpoint;
        }
    }
    
    if (!foundSource || !foundDest) {
        return nil;
    }
    return self;
}

- (void) sendUpNote: (uint8_t) note channel: (uint8_t) channel {
    const Byte data[3] = {KEY_UP | (channel - 1), note, 0};
    Byte packetBuffer[256];
    MIDIPacketList *packetList = (MIDIPacketList*) packetBuffer;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet->timeStamp = mach_absolute_time();
    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, 0, 2, (const Byte *) data);
    OSStatus s = MIDISend(outputPort, destination, packetList);
    if (s != noErr) {
        printf("problems sending.\n");
    }
}

- (void) sendControl: (uint8_t) controller value: (uint8_t) value channel: (uint8_t) channel {
    const Byte data[3] = {CONT | (channel -1), controller, value};
    Byte packetBuffer[256];
    MIDIPacketList *packetList = (MIDIPacketList*) packetBuffer;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, 1000, 3, (const Byte *) data);
    OSStatus s = MIDISend(outputPort, destination, packetList);
    if (s != noErr) {
        printf("problems sending.\n");
    }
}

- (void) sendProgram: (uint8_t) value  channel: (uint8_t) channel {
    const Byte data[3] = {PROGRAM_CHANGE | (channel -1), value};
    Byte packetBuffer[256];
    MIDIPacketList *packetList = (MIDIPacketList*) packetBuffer;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, 0, 2, (const Byte *) data);
    OSStatus s = MIDISend(outputPort, destination, packetList);
    if (s != noErr) {
        printf("problems sending.\n");
    }
}

- (void) sendDownNote: (uint8_t) note weight: (uint8_t) weight channel: (uint8_t) channel {
    const Byte data[3] = {KEY_DOWN | (channel -1), note, weight};
    Byte packetBuffer[256];
    MIDIPacketList *packetList = (MIDIPacketList*) packetBuffer;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList, sizeof(packetBuffer), packet, 0, 3, (const Byte *) data);
    OSStatus s = MIDISend(outputPort, destination, packetList);
    if (s != noErr) {
        printf("problems sending.\n");
    }
}
- (void) setDumpEvents: (BOOL) dump {
    dumpEvents = dump;
}

@end

void PlayWithSettings(MIDIControl *control) {
    for (int i =0 ; i < 29 ; i+= 1) {
        [control sendControl: 20 value: i channel: 1];
        [control sendDownNote: 0x40 weight: 80 channel: 1];
        usleep(100000);
        [control sendUpNote: 0x40 channel: 1];
        usleep(100000);
    }
}

void MaryHadALittleLamb(MIDIControl *control) {
    // Play Mary Had A Little Lamb.
    const uint8_t song_data[8] = {63, 61, 59, 61, 63, 63, 63 };
    
    char lastNote = 0;
    int i = 0;
    for (i=0; i < 8; i++) {
        [control sendUpNote: lastNote channel: 1];
        [control sendDownNote: song_data[i] weight: 0x70 channel: 1];
        lastNote = song_data[i];
        usleep(500000);
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        printf("Setting up.\n");
        MIDIControl *circuit = [[MIDIControl alloc] initWithDeviceNamed: @"Circuit" handler: redirect_to_circuit];
        if (!circuit) {
            printf("Couldn't connect to circuit.\n");
            exit(1);
        }

        MIDIControl *yamaha = [[MIDIControl alloc] initWithDeviceNamed: @"Yamaha" handler: default_handler];
        if (!yamaha) {
            printf("Couldn't connect to yamaha.\n");
            exit(1);
        }
        printf("Ready.\n");
        
#if (0)
        for (i=0; i < 100; i++) {
            [circuit sendUpNote: lastNote channel: 1];
            lastNote = random() % 40 + 30;
            int weight = random() % 120;
            [circuit sendDownNote: lastNote weight: weight channel: 1];
            usleep(100000);
        }
        [control sendUpNote: lastNote channel: 1];
#endif

       while (1) {
            sleep(1);
        }
    }
    return 0;
}

