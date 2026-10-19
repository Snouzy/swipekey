#pragma once

#include <stdint.h>

/// A single contact on a multitouch device, simplified from the private MTTouch struct.
/// Coordinates are normalized to 0...1, origin at the bottom-left of the trackpad.
typedef struct {
    float x;
    float y;
    int32_t identifier;
    /// Raw MultitouchSupport state: 3 = make touch, 4 = touching, 5 = break touch, ...
    int32_t state;
    /// Contact size and ellipse axes, as MultitouchSupport reports them (used to spot thumbs and palms).
    float size;
    float majorAxis;
    float minorAxis;
} SKTouch;

/// Called on a MultitouchSupport thread for every frame of every device.
typedef void (*SKFrameHandler)(uintptr_t device, const SKTouch *touches, int32_t count, double timestamp);

/// Loads MultitouchSupport and starts every multitouch device.
/// Returns the number of devices started, or -1 when the framework or its symbols are unavailable.
int32_t sk_multitouch_start(SKFrameHandler handler);

/// Stops every device started by sk_multitouch_start.
void sk_multitouch_stop(void);
