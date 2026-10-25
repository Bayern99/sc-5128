# Upstream Technical Report — `supercollider/supercollider#5128` (`removeAt` and Partial-Scan GC)

**Upstream issue:** [supercollider/supercollider#5128 — "Possible GC bug involving removeAt"](https://github.com/supercollider/supercollider/issues/5128) (opened 2020-08-08 by `@jamshark70`; open, with no C++ analysis attached)  
**Environment:** SuperCollider `3.14.1` macOS arm64 bundle, built from tag `Version-3.14.1` (commit `426edf6`). Source citations are to that tag. A `develop` checkout from 2026-10-22 had byte-identical `basicRemoveAt` and `ScanOneObj`/`DoPartialScan` bodies (line numbers differ; frame layout has since changed, see §2.3).  
**Scope:** An independent minimal reproducer, a source-level hypothesis, and an application-side workaround. No changes have been made to the upstream repository; no fix was compiled; no new experiments were run for this write-up.  
**Evidence:** Retained log excerpts are in `evidence/`; counts without retained per-run logs are labeled as historical summaries; §2 and §5 are hypothesis, not instrumentation.  
**AI assistance:** This write-up was prepared with AI assistance from the investigation's retained logs and the cited source; every quoted result is reproduced as recorded.

---

## 0. How to read the evidence

The claims in this report come from three different evidence tiers. They should not be read as one tier.

| Tier | What it supports | Where |
| --- | --- | --- |
| **Retained raw logs** | The application's `Instance of Frame` receiver and the clean circular-`put` control (`evidence/`); two frame-lifetime control results retained in the earlier package and summarized in §4 | `evidence/`, §4 |
| **Historical recorded outcomes** | 20/25 faults at `capacity = 192`; the capacity sweep; the tail-removal count; the single no-`Pbind` run | §3 and §4; per-run logs were not retained |
| **Static hypothesis** | The partial-scan/memmove mechanism, the boundary condition, the frame size-class collision, and candidate fixes | §2 and §5 |

Two cautions follow from this split:

- The earlier investigation described the 25-run series as quark-free. No per-run logs for that series were retained, and the retained probe logs from the same investigation show sclang compiling downloaded quarks. This report therefore does **not** claim a controlled quark-free or default-class-library baseline. It reports the fault count as a historical recorded outcome.
- The application that exposed the fault has private source and cannot be linked publicly. Its retained log excerpt is included as evidence; no private source path is cited in this report.

---

## 1. Symptom (observed)

In the observed failure, a `List` used as a sliding window of 8-slot `Array` rows repeatedly evicts from the front while event-stream allocations drive incremental GC. A retained element later reads back as an interpreter `Frame` instead of an `Array`:

```text
ERROR: Message 'at' not understood.
RECEIVER:
Instance of Frame {    (0x76de44e6c8, gc=F4, fmt=01, flg=00, set=03)
  indexed slots [7]
      0 : instance of Method CollStream:putAll (0x76df8d2b40)
      1 : Integer 0
      2 : Frame (0x76de44e6c8) of CollStream:putAll
      3 : Frame (0x76de44e6c8) of CollStream:putAll
      4 : RawPointer 0x0
      5 : instance of CollStream (0x76de2ef6f8, size=2, set=2)
      6 : "0.12"
}
```

This is a verbatim excerpt from a retained application log (`evidence/red-application-frame-error.txt`). The receiver is a 7-slot `PyrFrame` in GC `set=03`, not the 8-slot `Array` the program stored. The same receiver address appears later in the same log with a different `gc=` color (`evidence/red-application-frame-address-reuse.txt`); the address stability is consistent with in-place reuse, but the allocation history itself was not logged, so the reuse is an inference from the dump.

The failure matches the symptom in [`supercollider/supercollider#5128`](https://github.com/supercollider/supercollider/issues/5128): `Frame` objects appearing where arrays or other values are expected, with the reporter's `removeAt` → `reject` workaround making the problem disappear. The issue itself contains no C++ analysis, so this report treats #5128 as a **suspected** match, not a confirmed duplicate.

---

## 2. Static hypothesis: how `removeAt` can hide an unscanned slot

> **Status: hypothesis from source reading, not instrumented.** No run printed `mPartialScanObj`, `mPartialScanSlot`, or the hidden child's colour; no debugger or `GC_SANITYCHECK` build was used. The observed receiver is consistent with the mechanism below, and the controls in §3 are consistent with it, but §6 lists the alternatives that the evidence does not exclude.

### 2.1 Incremental partial scanning colours a large array Black before all slots are scanned

The trigger is `size > mNumToScan + 32`, where `mNumToScan` is the remaining scan budget — not a fixed `size > 32` test, and not a "32-element" array length.

In [`lang/LangSource/GC.cpp:545-553`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L545-L553) (`PyrGC::ScanOneObj()`):

```cpp
ToBlack(obj);

int32 size = ScanSize(obj);
if (size > mNumToScan + 32) {
    mPartialScanObj = obj;
    mPartialScanSlot = 0;
    DoPartialScan(size);
}
```

`DoPartialScan` ([`GC.cpp:498-522`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L498-L522)) scans at most the remaining budget and leaves the cursor at `mPartialScanSlot`:

```cpp
int32 remain = inObjSize - mPartialScanSlot;
if (remain <= 0) {
    mPartialScanObj = nullptr;
    mNumToScan -= 4;
    ...
    return;
}
int32 numtoscan = sc_min(remain, mNumToScan);
ScanSlots(mPartialScanObj->slots + mPartialScanSlot, numtoscan);

if (numtoscan == remain) {
    mPartialScanObj = nullptr;
    mNumToScan -= numtoscan + 4;
} else {
    mPartialScanSlot += numtoscan;
    mNumToScan -= numtoscan;
}
```

`ScanSize` is `obj->size` for slot-format objects only ([`GC.cpp:146`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L146)), so only indexed slot arrays can take this path. Partial scan is entered from `Collect()` at [`GC.cpp:671-679`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L671-L679); while budget remains, the collector services the partial object, and `Flip()` ([`GC.cpp:600-642`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L600-L642)) is not reached until the partial scan has been cleared. Thus a partially scanned array can survive across several `Collect()` calls with a scanned prefix `[0, s)` and an unscanned suffix `[s, size)`.

In the reproducer, the ring is a `List`; `List` is a wrapper around a slot-format `Array`, and `List:removeAt` delegates to `Array:removeAt` ([`List.sc:49-53`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/SCClassLibrary/Common/Collections/List.sc#L49-L53)). At `capacity = 192` the backing array is **193 slots** immediately after an insert and before the eviction trims it. That transient 193-slot state is the size the partial-scan gate sees if the array is popped from the grey list at that moment.

### 2.2 `basicRemoveAt` shifts an unscanned White slot left across `mPartialScanSlot` without barriering it

In [`lang/LangPrimSource/PyrArrayPrimitives.cpp:153-221`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangPrimSource/PyrArrayPrimitives.cpp#L153-L221) (`basicRemoveAt`):

```cpp
length = obj->size - index - 1;
if (length > 0) {
    elemsize = gFormatElemSize[obj->obj_format];
    memmove(ptr, (char*)ptr + elemsize, length * elemsize);
    if (obj->obj_format <= obj_slot) {
        // might be partial scan object
        g->gc->GCWrite(obj, obj->slots + index);
    }
}
obj->size--;
return errNone;
```

Compare `basicTakeAt` ([`PyrArrayPrimitives.cpp:251-256`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangPrimSource/PyrArrayPrimitives.cpp#L251-L256)), which moves only the last slot into `slots[index]` and barriers that one slot. `basicRemoveAt` instead `memmove`s every slot `[index + 1, size)` one position left, then barriers only `slots[index]`.

Let `s = mPartialScanSlot` before the eviction, with `0 < s < size`, and let `index` be the eviction index. The scan cursor has passed slots `< s`; slots `>= s` are still unscanned. The `memmove` shifts old slot `j` to `j - 1` for `j > index`. The only slot that can cross from the unscanned suffix into the scanned prefix is old slot `s`, and only when `index < s`:

- If `index <= s - 2`, old slot `s` lands at `s - 1`, which is inside the already-scanned prefix. The barrier at `slots[index]` targets old slot `index + 1`, which is also in the scanned prefix, so `GCWrite` is a no-op for a child that was already scanned. **If the child in old slot `s` was White, it is now hidden behind the cursor, was never greyed by this barrier, and is swept at the next `Flip()` unless another reference greys it.**
- If `index == s - 1`, old slot `s` lands at `s - 1`, and the existing barrier targets exactly that slot. That child is greyed; safe.
- If `index >= s`, the shift starts inside the unscanned suffix; the cursor still covers the shifted slots. Safe.
- If `s == 0` or `s == 1`, no `index <= s - 2` exists. Safe.

So, when the condition holds, each such eviction hides exactly one child from the scan: the one in the first unscanned slot that crosses the cursor. If that child was White and no other reference marks it, it is swept at `Flip()`. `GCWrite` only greys a White child when the parent is Black ([`GC.h:96-100`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.h#L96-L100)); the parent was made Black by `ScanOneObj` before the partial scan, so the barrier would work if it targeted the right slot.

If enough removals shrink `size` to `<= s` before the scan resumes, `DoPartialScan` takes the `remain <= 0` branch ([`GC.cpp:501-507`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L501-L507)) and clears `mPartialScanObj` without rescanning the prefix. In the `size == s` case the hidden child at `s - 1` is still inside the array and stays unmarked; if the array has shrunk past it, that child is no longer referenced by the array. This variant is not exercised by the minimal reproducer.

`basicRemoveAt` only re-greys the single slot it writes. Primitives that re-grey the array — `prArrayInsert` ([`PyrArrayPrimitives.cpp:962-963`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangPrimSource/PyrArrayPrimitives.cpp#L962-L963) and its later `obj_slot` branch at `1035-1036`), `prArrayAddAll` ([`1473-1474`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangPrimSource/PyrArrayPrimitives.cpp#L1473-L1474)) and `prArrayOverwrite` ([`1516-1517`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangPrimSource/PyrArrayPrimitives.cpp#L1516-L1517)) — put the array, or its replacement when the primitive reallocates, back on the grey list and force a fresh scan from slot 0. That is the static reason the §3 discriminants single out `removeAt`; it is not a proof that every other mutating primitive is safe.

Not verified experimentally: whether `basicTakeAt` can hide a slot. Its write is `slots[lastIndex] -> slots[index]` plus one barrier at `slots[index]`; if `index < s` and `lastIndex >= s`, the barrier targets the slot that receives the unscanned value, which covers it. A reachable hiding case was not found, but this deserves maintainer scrutiny rather than a claim.

### 2.3 Why a `Frame` replaces an 8-slot `Array` row in place

In [`lang/LangSource/GC.cpp:373-405`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L373-L405) (`PyrGC::NewFrame`) and [`PyrKernel.h:78-87`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/PyrKernel.h#L78-L87):

- `NewFrame` aligns the requested byte size to 16 bytes, divides by `sizeof(PyrSlot)` (16 on 64-bit), then takes `sizeclass = LOG2CEIL(numSlots)`. An 8-element `Array` is 128 bytes → 8 slots → **`set = 3`**. A 5-element `Array` is 80 bytes → 5 slots → `LOG2CEIL(5) = 3`; the set-3 pool serves blocks of 8 slots. The set-3 band is therefore 5–8 slots.
- A `PyrFrame` is `(FRAMESIZE + proto->size)` slots, with `FRAMESIZE = 5` on 3.14.1 ([`PyrKernel.h:87`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/PyrKernel.h#L87); the header is `method, caller, context, homeContext, ip`, then `vars[]`). A block with 2 arguments or locals is 7 slots → 112 bytes → 7 slots → **`set = 3`**, the same class as an 8-slot `Array`. The observed receiver has `indexed slots [7]` and `set=03`.
- Earlier observations recorded 5- and 8-slot arrays and a 7-slot frame as `set=03`, and a 9-slot array as `set=04`, which matches the arithmetic; those spot checks are historical, not retained logs.

**Version caveat:** PR [#7737](https://github.com/supercollider/supercollider/pull/7737) ("sclang: implement reference counting for frames") merged after 3.14.1 and changes the frame layout: `FRAMESIZE` is 7 in the `develop` checkout used here, versus 5 in 3.14.1. The partial-scan and `basicRemoveAt` code paths analyzed here are unchanged in that checkout, but the same 2-variable block would no longer be a 7-slot frame on `develop` (`FRAMESIZE` 7 instead of 5), so the exact receiver shape is version-dependent. This report does **not** claim the same receiver shape on `develop`; it claims the GC mutation hazard is not a 3.14.1-only code path.

`Flip()` ([`GC.cpp:600-642`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L600-L642)) is reached only after the partial scan has completed. Its `MajorFlip`/`MinorFlip` ([`GC.cpp:214-233`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L214-L233)) moves every still-White object of the set to the head of the free list. The skipped White 8-slot `Array` row is referenced from a slot in the already-scanned prefix of `List.array`, which was not re-barriered after the shift, so it is not marked. It lands on `mSets[3].mFree` while remaining the live element of the `List`. A later frame allocation can call `g->gc->NewFrame(...)` at [`PyrMessage.cpp:500`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/PyrMessage.cpp#L500), pop that address from `mSets[3].mFree` ([`GC.h:316-322`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.h#L316-L322)) and write `obj->classptr = class_frame` ([`GC.cpp:398`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L398)), turning the live element inside `List.array` into an `Instance of Frame`. Which caller name appears in slot 0 (`List:add`, `CollStream:putAll`, `String:==`, …) is decided by whichever frame allocation wins the race, not by the eviction site.

---

## 3. Standalone reproducer

The reproducer is [`repro-5128.scd`](repro-5128.scd) in this directory. It runs under plain `sclang repro-5128.scd`; the script itself uses only built-in classes and requires no quarks. Runtime is roughly 12–20 s, with no Server and no disk writes.

```supercollider
// Standalone SuperCollider reproducer for supercollider/supercollider#5128.
//
// Run with: sclang repro-5128.scd
// Expected:  "rowsAreArrays=false ... fault=nonArrayRow receiver=Frame"
//            in roughly 4 out of 5 runs (probabilistic; see the report).
// Runtime:   ~12-20 s, no Server, no GUI, no write to disk.
//
// A List of 8-element Array rows is used as a 192-slot sliding window and
// evicts from the front with removeAt(0). _BasicRemoveAt memmove-shifts the
// slots, and on an array the GC has left partially scanned that moves the
// first unscanned slot behind mPartialScanSlot, where it is never scanned and
// is swept at the next Flip(). The freed 8-slot Array (GC set=3) is then
// reallocated in place as a 7-slot PyrFrame, which is the same set=3 size
// class, so the live row reads back as "Instance of Frame".
//
// Controls used in the upstream report:
//   - var capacity = 192; -> events.removeAt(events.size - 1);
//     (tail removal, no memmove: 4/4 clean)
//   - var capacity = 32;
//     (ring never exceeds 32, so partial scan is unreachable: 3/3 clean)
//   - capacity 40..160 clean; 176 and 192 fault.
(
var capacity = 192;
var rounds = 640;
var clock = TempoClock(16);
var events = List.new;
var seq = 0, dropped = 0, fault = nil, faultReceiver = "none";
var counts = Dictionary["lead" -> 0, "bass" -> 0, "response" -> 0];
var capture, makeStream, players;

Event.addEventType(\sc5128Probe, { });

capture = { |event, voice|
    var row;
    seq = seq + 1;
    // 8-slot Array (GC set=3, same size class as a 7-slot PyrFrame)
    row = [voice, seq, clock.beats.round(0.01), event[\dur], event[\degree], 5, 440, 0];
    events.add(row);
    while { events.size > capacity } {
        events.first[2];
        events.removeAt(0); // _BasicRemoveAt on mPartialScanObj (size 193 > 32)
        dropped = dropped + 1;
    };
    counts[voice] = counts[voice] + 1;
};

makeStream = { |voice, dur|
    Pfin(rounds, Pbind(
        \type, \sc5128Probe,
        \degree, Pseq((0..7), inf),
        \dur, dur,
        \callback, { |event| capture.value(event, voice) }
    )).play(clock, quant: 0);
};

players = [
    makeStream.value("lead", 0.25),
    makeStream.value("bass", 0.5),
    makeStream.value("response", 0.75)
];

Routine.run({
    var deadline = clock.beats + 520, badRow;
    while { fault.isNil and: { clock.beats < deadline } and: { counts.values.sum < (rounds * 3) } } {
        badRow = events.detect { |row| row.isKindOf(Array).not };
        if(badRow.notNil) {
            fault = "nonArrayRow";
            faultReceiver = badRow.class.asString;
        };
        0.05.wait;
    };
    players.do(_.stop);
    "events=% dropped=% counts=% rowsAreArrays=% fault=% receiver=%".format(
        events.size, dropped, counts, events.every(_.isKindOf(Array)), fault ? "none", faultReceiver
    ).postln;
    clock.stop;
    0.exit;
});
)
```

The script is published verbatim, including its header comments. The inline `(size 193 > 32)` is shorthand for the `size > mNumToScan + 32` gate; it is **not** a claim that 32 is the threshold. The header's tail-removal count is discussed in §3.4.

### 3.1 Recorded outcomes (historical summary, no per-run logs retained)

The fault is probabilistic: under the §2 hypothesis, the GC must expose the array at mid-scan when `removeAt(0)` runs before the next rescan. The earlier investigation recorded **20 of 25 runs at `capacity = 192`** ending in `rowsAreArrays=false`, `faultReceiver=Frame`. Per-run logs for that series were not retained, and the series was not recorded as a controlled quark-free baseline (§0), so this is a historical recorded outcome rather than a retained-log measurement.

Sample lines from that series, as recorded at the time:

```text
events=192 dropped=1520 counts=Dictionary[(bass -> 640), (lead -> 640), (response -> 432)] rowsAreArrays=false fault=nonArrayRow receiver=Frame
events=192 dropped=1057 counts=Dictionary[(bass -> 365), (lead -> 640), (response -> 244)] rowsAreArrays=false fault=nonArrayRow receiver=Frame
events=192 dropped=273  counts=Dictionary[(bass -> 127), (lead -> 253), (response -> 85)]   rowsAreArrays=false fault=nonArrayRow receiver=Frame
events=192 dropped=1728 counts=Dictionary[(bass -> 640), (lead -> 640), (response -> 640)]   rowsAreArrays=true  fault=none receiver=none
```

The recorded samples show a consistent pattern: a faulting run ends early, consistent with the corrupted row throwing inside a callback so that one or more streams stop, and `dropped` stays below the full `1728`; a clean run reaches `dropped=1728` with all three voices at `640`. These are recorded observations, not a claim that the early-stop behaviour was instrumented.

### 3.2 The full receiver dump (retained, instrumented variant)

An instrumented variant of the same eviction policy produced the full `DoesNotUnderstandError` receiver dump below. This is a **different runner from the standalone script**, but the eviction policy and row shape are the same, and the dump is retained in the earlier investigation's probe log (the application log in §1 is a second, independent retained instance).

```text
ERROR: Message 'at' not understood.
RECEIVER:
Instance of Frame {    (0x7a68171168, gc=D0, fmt=01, flg=00, set=03)
  indexed slots [7]
      0 : instance of Method List:add (0x7a69bbdc40)
...
probeEvents=195
probeDropped=47
probeLead=130
probeBass=65
probeResponse=44
probeRowsAreArrays=false
probeFault=nonArrayRow
probeFaultReceiver=Frame
```

The ad-hoc `probe*` labels are from the earlier runner, not from the public reproducer.

### 3.3 The clean control (retained)

With in-place circular `put` (`putIndexedSlot` on a fixed-capacity ring) instead of `removeAt(0)`, the same workload completes all `1920` events and `1728` evictions:

```text
probeEvents=192
probeDropped=1728
probeLead=640
probeBass=640
probeResponse=640
probeRowsAreArrays=true
probeFault=none
probeFaultReceiver=none
upstreamWithClosureCaller=Frame
upstreamNoClosureCaller=Array
```

This is a retained control log (`evidence/green-circular-put-stdout.txt` and payload). Its head shows that the probe runner compiled the machine's class library including downloaded quarks; the circular-`put` result is a control on the eviction policy, **not** a quark-free baseline. The two `upstream*` lines are the #7711 discriminator discussed in §4.

### 3.4 Controls from the earlier investigation

Same script or the same eviction policy, one variable changed each time. These are recorded summaries; per-run logs were not retained except where noted.

| Control | Recorded result |
| --- | --- |
| `removeAt(events.size - 1)` (tail removal; no `memmove`, `length == 0`) | Clean. The reproducer's header records 4/4; an earlier summary said 5/5. Per-run logs were not retained, so the count discrepancy is unresolved here; both records agree the control passed. |
| `capacity = 32` | Clean in 3/3 recorded runs; source reasoning below makes the gate unreachable. |
| `capacity = 40 / 48 / 64 / 96 / 128 / 150 / 160` | Clean in 2–4 runs each, 16 runs total, as recorded. |
| `capacity = 176` | 1 fault in 2 recorded runs. |
| `capacity = 192` | 20 faults in 25 recorded runs. |

**Why `capacity = 32` is the source-provable safe case.** The backing array reaches **33 slots**, not 32, between the insert and the eviction; the script's own comment "the ring never exceeds 32" is off by one because the trim happens after the insert. At size 33, the gate `size > mNumToScan + 32` requires `mNumToScan < 1`. `ScanOneObj` is only called while `mNumToScan > 0` (the `Collect()` loop condition at `GC.cpp:671-679`), and `mNumToScan` is an integer budget, so the gate is unreachable. The strict `>` matters: at budget 1, `33 > 33` is false. This is source reasoning plus 3/3 recorded clean runs, not a logged proof. At `capacity = 33` the transient size is 34, `mNumToScan = 1` can satisfy `34 > 33`, and partial scan becomes reachable, so 32 is the largest capacity whose safety follows from the gate alone.

The sweep is consistent with the `size > mNumToScan + 32` gate but does **not** establish a crisp cutoff. The budget depends on the graph order and the collection in which the array is popped, so the 160→176 transition should not be quoted upstream as a threshold. The practical statement supported by the sweep is only: the fault needs a large ring and a partially scanned array at the same time, which is what the mechanism predicts.

One further recorded observation: a minimal loop adding and evicting rows without `Pbind`/`EventStreamPlayer` did **not** fault in a single 20,000-iteration run. That is one run, not a clean control; it suggests the trigger needs real event-stream allocation traffic, but it is not proof and should be repeated before being cited upstream.

---

## 4. Discrimination from `supercollider/supercollider#7711`

[#7711](https://github.com/supercollider/supercollider/issues/7711) is a separate, known 3.14.1 frame-lifetime bug: `returnFromBlock()` frees a frame still referenced by a live frame's `caller`. Because #7711 also produces `PyrFrame` reuse in 3.14.1, it must be excluded before blaming `removeAt`. Three single-variable controls were run in the earlier investigation:

1. **Heap-frame callbacks** (forcing the `Pbind` callbacks onto heap frames): still failed with `Frame of String:==` (`178/89/60`, `dropped=135`); retained control log.
2. **Explicit environment restoration** (removing the probe's `.inEnvir` calls and restoring the environment at the callback boundary): still failed with `probeFaultReceiver=Frame` (`170/85/57`, `dropped=120`); retained control log.
3. **In-place circular `put`** (the probe's circular-put path): keeps all `.inEnvir` closures and runs the #7711 discriminator in the same process (`upstreamWithClosureCaller=Frame`, `upstreamNoClosureCaller=Array`), yet completes all `1920` events and `1728` evictions with `probeFault=none`; retained log.

**Version note.** PR [#7737](https://github.com/supercollider/supercollider/pull/7737) ("sclang: implement reference counting for frames", closes #7711) merged on 2026-10-04, after the `Version-3.14.1` tag. The 3.14.1 bundle used here therefore still has the non-refcounted frame behavior, which is why the #7711 exclusion is required. This report does not claim the #7711 path is inactive in the reproducer's process.

**What these controls do and do not prove.** All three are process-level: they show the `removeAt(0)` fault survives removing the two #7711 triggers, and disappears when the eviction policy changes. They do not prove the #7711 path is inactive in the standalone reproducer; the standalone script does not include the #7711 discriminator. The tail-removal control in §3.4 is the sharper one, because it changes only the primitive call while leaving the rest of the reproducer's workload unchanged.

---

## 5. Candidate fixes (untested) and application workaround

> **Status: candidate directions, not a reviewed patch.** None of these was compiled or run. Any fix must preserve the invariant that a slot the cursor has passed is never moved again without a barrier.

Under the §2 hypothesis, the defect is the `memmove` at [`PyrArrayPrimitives.cpp:214`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangPrimSource/PyrArrayPrimitives.cpp#L214) moving unscanned slots behind the scan cursor; the barrier at line 217 covers only `obj->slots + index`, in line with the comment "might be partial scan object". Candidate fixes, cheapest first:

1. **Barrier the boundary slot.** After the shift, `obj->slots[s - 1]` holds old `obj->slots[s]`, the one unscanned slot that fell behind the cursor. A single extra `g->gc->GCWrite(obj, obj->slots + s - 1)` when `IsPartialScanObject(obj)`, `index <= s - 2`, and the hidden slot is still inside the new size re-greys it; the rest of `[s, size - 1)` is still under the cursor. `IsPartialScanObject` and `GetPartialScanIndex` are already public on `PyrGC` ([`GC.h:166-167`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.h#L166-L167)), so this needs no new surface.
2. **Move the cursor back.** If `obj == mPartialScanObj && index < mPartialScanSlot`, decrement `mPartialScanSlot` so the next `DoPartialScan` rescans `[s - 1, size)`. This needs an accessor or friend declaration and must also handle `size` shrinking to `<= s` (the `remain <= 0` note in §2.2).
3. **Complete the scan first.** Call `g->gc->CompletePartialScan(obj)` before the `memmove`. The function exists ([`GC.cpp:491-496`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.cpp#L491-L496), declared at [`GC.h:139`](https://github.com/supercollider/supercollider/blob/Version-3.14.1/lang/LangSource/GC.h#L139)) but has **no call site anywhere in the tree** — dead code today. It scans the remaining slots but does not clear `mPartialScanObj` or move the cursor, so the object would be rescanned from `s` later; that is safe but wasteful, and a real fix would also have to update the GC state. It also spends the pause budget the partial scan exists to protect, which is probably why it was never wired up; treat it as a correctness reference rather than the preferred fix.

`PyrSched.cpp:121-172` already hand-rolls an `IsPartialScanObject` + `GCWriteBlack` guard for its heap — a useful precedent and a useful regression target.

**Application-side workaround (adopted where this fault was found).** Avoid `removeAt` on sliding windows whose backing array can exceed the partial-scan gate. Use a fixed-capacity ring that overwrites `slot = (seq - 1).mod(capacity)` via `put(slot, row)` (`putIndexedSlot` in `PyrObject.cpp:2686-2695` barriers the exact written slot with no `memmove`) and reads in chronological order via `wrapAt(dropped + index)`. The retained circular-`put` control in §3.3 exercises this policy. This avoids the primitive; it does not make `removeAt` safe.

---

## 6. Evidence status

### Retained raw logs (in `evidence/`)

- The application's `Instance of Frame` receiver: `evidence/red-application-frame-error.txt` (lines 70-76 of the archived log) and `evidence/red-application-frame-address-reuse.txt` (later lines showing the same address with a different `gc=` color).
- The clean circular-`put` result: `evidence/green-circular-put-stdout.txt` and `evidence/green-circular-put-payload.json` (`192` events, `1728` evictions, `640/640/640`, `probeFault=none`; discriminator `upstreamWithClosureCaller=Frame`, `upstreamNoClosureCaller=Array`).
- The two #7711 control results are retained in the earlier evidence package, but only their summaries are quoted here; the raw excerpts are not reproduced in this directory.

### Historical recorded outcomes (no per-run logs retained)

- 20 of 25 `capacity = 192` runs faulted; the series was not a controlled quark-free baseline. The count is as recorded by the earlier investigation.
- The capacity sweep: 40–160 clean (2–4 runs each, 16 total), 176 one fault in 2, 192 twenty faults in 25.
- Tail removal: the script header records 4/4 clean; an earlier summary said 5/5. The per-run logs were not retained; the mismatch is unresolved here. The script's 4/4 and the summary's 5/5 both describe the same control.
- The single no-`Pbind` 20,000-iteration run did not fault.

### Static hypothesis (not instrumented)

- **The exact violated invariant.** The child in the boundary slot `obj->slots[s]` is shifted to `s - 1` and never rescanned; this is the only child hidden per eviction when `index <= s - 2`, and if it was White it is swept. The argument is from source and is consistent with every control, but no run printed `mPartialScanObj`, `mPartialScanSlot`, or the hidden child's colour.
- **That the missing barrier is the proximate cause.** A missed `CompletePartialScan` and a `mNumToScan` accounting slip are separate candidate defects in the same subsystem; the evidence does not separate them.
- **That the reproducer's fault is always this mechanism.** The signature (a `set=3` frame in place of an 8-slot array element in a `removeAt`-evicting ring) matches, but a run could in principle be a different GC defect. The controls make this unlikely; they do not exclude it.
- **The capacity crossover.** Consistent with the gate, but the gate depends on the remaining scan budget; no fixed number should be quoted as a threshold.

### Requires upstream maintainers

- Whether the partial-scan design permits an array to be mutated by a `memmove` at all, or whether the intended contract is that mutating primitives call `CompletePartialScan` first. `CompletePartialScan` existing and never being called is either an oversight or a deliberate removal — only the authors know which.
- Whether #5128 (opened 2020, SC 3.11, Windows-reported) is this bug. The symptom text and the `removeAt`/`reject` workaround match, `basicRemoveAt` is byte-identical between 3.11.2 and 3.14.1, and the partial-scan code path is unchanged in the `develop` checkout used here, but #5128 has no C++ analysis or comments; it should be treated as a suspected duplicate, linked, not claimed.
- Whether `basicTakeAt` and `prArrayInsert` have related hiding cases. No reachable hiding case was established for `basicTakeAt`, and `prArrayInsert`'s re-grey path is noted in §2.2 but not proven safe; §2.2 says so rather than claiming coverage.
- Which of the §5 candidate fixes is acceptable, and whether the fix belongs in the primitive or in a stronger `PyrGC` invariant.

### Not claimed by this report

- That the bug affects `3.12`, `3.13`, or `develop` at runtime. `basicRemoveAt` is identical in 3.11.2 and 3.14.1, and the partial-scan region is unchanged in the `develop` checkout used here, but `3.12`/`3.13` were not checked and only `3.14.1` was executed in the underlying investigation; `develop` frame layout also changed after PR #7737.
- Any fix, patch, or compiled result. §5 is a direction list; none of it was built.
- That the application-side workaround is the right fix for anyone else. It avoids the primitive; it does not make `removeAt` safe.
