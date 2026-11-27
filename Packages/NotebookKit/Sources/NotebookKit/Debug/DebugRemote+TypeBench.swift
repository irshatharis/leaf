#if DEBUG && os(macOS)
import AppKit
import QuartzCore
import os

/// `typebench <count> [interval]`: types `count` characters into the note, one key event every `interval` seconds
/// (0.1 by default), and logs what each key cost the main thread. `key` is the key's own handling plus drawing the
/// window and handing the frame to the render server; `key cpu` is the main thread's CPU time for the same, which
/// other processes on the cores don't inflate; `busy` is everything the main run loop did between waits, per key, so
/// work a key sets off for later counts too. Lines laid out and glyphs made count the text system's work for the keys
/// themselves (not the layout done ahead while idle), which doesn't vary with the load on the machine. Signposts mark
/// each key for Instruments.
@MainActor
enum TypeBench {
    private static let signposts = OSSignposter(subsystem: "app.leaf.bench", category: .pointsOfInterest)
    private static var observer: CFRunLoopObserver?
    private static var busy: Double = 0
    private static var wokeAt: Double?

    static func run(count: Int, interval: Double, window: NSWindow, send: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        let text = Array("the quick brown fox jumps over the lazy dog ")
        var keyTimes: [Double] = []
        var keyCPU: [Double] = []
        var lines = 0, glyphs = 0
        startBusyClock()
        let start = CACurrentMediaTime()
        var typed = 0
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard typed < count else {
                    timer.invalidate()
                    let wall = CACurrentMediaTime() - start
                    let total = stopBusyClock()
                    let sorted = keyTimes.sorted()
                    func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
                    let cpu = keyCPU.sorted()
                    let slowest = keyTimes.indices.sorted { keyTimes[$0] > keyTimes[$1] }.prefix(3)
                    log("typebench slowest keys: " + slowest.map { String(format: "#%d %.1f ms", $0, keyTimes[$0] * 1000) }.joined(separator: ", "))
                    let keys = Double(sorted.count)
                    log(String(format: "typebench %d keys: key p50 %.2f ms p90 %.2f ms max %.2f ms; key cpu p50 %.2f ms mean %.2f ms; busy %.2f ms/key; lines laid out %.1f/key, glyphs made %.0f/key; wall %.1f s",
                               sorted.count, at(0.5), at(0.9), sorted.last.map { $0 * 1000 } ?? 0, cpu[cpu.count / 2] * 1000,
                               cpu.reduce(0, +) * 1000 / keys, total * 1000 / keys, Double(lines) / keys,
                               Double(glyphs) / keys, wall))
                    return
                }
                let state = signposts.beginInterval("key")
                let t0 = CACurrentMediaTime()
                let c0 = threadCPU()
                let (l0, g0) = (NotebookLayoutManager.debugLinesLaidOut, NotebookLayoutManager.debugGlyphsMade)
                send(String(text[typed % text.count]))
                window.displayIfNeeded()
                CATransaction.flush()
                keyTimes.append(CACurrentMediaTime() - t0)
                keyCPU.append(threadCPU() - c0)
                lines += NotebookLayoutManager.debugLinesLaidOut - l0
                glyphs += NotebookLayoutManager.debugGlyphsMade - g0
                signposts.endInterval("key", state)
                typed += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The main thread's own CPU time, which other processes taking the cores don't add to.
    private static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    private static func startBusyClock() {
        busy = 0
        wokeAt = CACurrentMediaTime()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    wokeAt = now
                } else if let woke = wokeAt {
                    busy += now - woke
                    wokeAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private static func stopBusyClock() -> Double {
        if let woke = wokeAt { busy += CACurrentMediaTime() - woke }
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        return busy
    }
}
#endif
