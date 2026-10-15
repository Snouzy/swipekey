#include "CMultitouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

// Layout of the private MTTouch struct (96 bytes on 64-bit), as reverse engineered by
// the community (see jitouch, MiddleClick, OpenMultitouchSupport).
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerId;
    int32_t handId;
    MTVector normalized;
    float size;
    int32_t zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int32_t zero2[2];
    float density;
} MTTouch;

_Static_assert(sizeof(MTTouch) == 96, "MTTouch layout changed");

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFArrayRef (*MTDeviceCreateList)(void);
static void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*MTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*MTDeviceStart)(MTDeviceRef, int);
static void (*MTDeviceStop)(MTDeviceRef);

static SKFrameHandler frameHandler;
static CFArrayRef devices;

#define SK_MAX_TOUCHES 32

static int contactCallback(MTDeviceRef device, MTTouch *data, int count, double timestamp, int frame) {
    (void)frame;
    if (!frameHandler) return 0;
    SKTouch touches[SK_MAX_TOUCHES];
    int n = count < SK_MAX_TOUCHES ? count : SK_MAX_TOUCHES;
    for (int i = 0; i < n; i++) {
        touches[i] = (SKTouch){
            .x = data[i].normalized.position.x,
            .y = data[i].normalized.position.y,
            .identifier = data[i].identifier,
            .state = data[i].state,
        };
    }
    frameHandler((uintptr_t)device, touches, n, timestamp);
    return 0;
}

static int loadSymbols(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!lib) return 0;
    MTDeviceCreateList = dlsym(lib, "MTDeviceCreateList");
    MTRegisterContactFrameCallback = dlsym(lib, "MTRegisterContactFrameCallback");
    MTUnregisterContactFrameCallback = dlsym(lib, "MTUnregisterContactFrameCallback");
    MTDeviceStart = dlsym(lib, "MTDeviceStart");
    MTDeviceStop = dlsym(lib, "MTDeviceStop");
    return MTDeviceCreateList && MTRegisterContactFrameCallback && MTUnregisterContactFrameCallback
        && MTDeviceStart && MTDeviceStop;
}

int32_t sk_multitouch_start(SKFrameHandler handler) {
    if (!loadSymbols()) return -1;
    sk_multitouch_stop();
    frameHandler = handler;
    devices = MTDeviceCreateList();
    if (!devices) return 0;
    CFIndex count = CFArrayGetCount(devices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        MTRegisterContactFrameCallback(device, contactCallback);
        MTDeviceStart(device, 0);
    }
    return (int32_t)count;
}

void sk_multitouch_stop(void) {
    if (!devices) return;
    CFIndex count = CFArrayGetCount(devices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        MTUnregisterContactFrameCallback(device, contactCallback);
        MTDeviceStop(device);
    }
    CFRelease(devices);
    devices = NULL;
}
