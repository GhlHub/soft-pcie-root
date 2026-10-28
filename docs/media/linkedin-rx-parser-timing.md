# PCIe RX parser timing graphic

[Download PNG](linkedin-rx-parser-timing.png) · [Generation prompt](linkedin-rx-parser-timing-prompt.txt)

Created with the built-in imagegen tool and visually checked for text, numbers,
RTL pseudocode and qualification scope. The diagram simplifies the pointer
feedback path; metadata storage/read, occupancy checks and full packet validation
remain present in the implementation.

Suggested post:

Another small improvement to the 250 MHz soft PCIe Gen3 x1 receive path on ZCU104.

The critical feedback loop read buffered bytes, aligned and classified a token,
then calculated the next read pointer. I moved byte classification to the ingress
write and computed pointer candidates in parallel, leaving a late selection.
There is no added parser latency, and packet validation remains unchanged.

Before programming, the modified parser matched the previous RTL cycle by cycle
on 6,745 stimulus entries plus drain cycles. The independent framing oracle
covered 208 cases, and all 85 regression tests passed. These are simulation
checks on tested cases, not a formal-equivalence proof.

Fresh full synthesis and place-and-route improved setup WNS from +0.090 ns to
+0.136 ns: 46 ps more margin at the same 4 ns clock period. The independent
checkpoint audit passed, followed by Gen3 x1 startup and all eight NVMe
performance/integrity jobs. QD8 reads/writes measured 734.84/564.79 MB/s, within
0.3% of the preceding image. QD1 reads were 2.73% lower in this historical
comparison; these runs are not an interleaved statistical study.

Gen3 remains experimental, with further stabilization and qualification pending.

[Exact build and hardware evidence](../evidence/rx_metadata_v1/completion.json).
