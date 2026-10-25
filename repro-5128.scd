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
