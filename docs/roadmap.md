# Deliberate stopping point and future investigation

This release freezes the two-bank TX design at Gen1/Gen2 x1. It does not promise
faster implementations or support for other hardware based on parameter edits.

Potential investigations, each requiring protocol tests, timing and new hardware
measurements:

- More completion prefetch slots and overlap across endpoint read requests.
- Buffer/credit capacity sweeps with occupancy measurements and bounded ownership.
- Registered byte preparation and BRAM-backed serializer storage for timing margin.
- Reducing ACK/replay drain overhead without freeing live retry storage.
- Gen3 or wider links: new PHY, encoding/training/protocol architecture and validation.
- OP063 adapter qualification and a reviewed FRU/VADJ policy update.
- Broader endpoint/device coverage, long-duration and cold-cycle qualification.

The measured baseline has zero TX backpressure at the host completion interface,
but approximately 30% of host cycles wait for completion-slot data. That supports
further DDR-prefetch investigation; it does not prove a particular future speedup.
