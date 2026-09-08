import Foundation

@main
struct EnergyOptimizationTests {
    static func main() {
        let now = Date()
        func canPause(_ readings: [(Bool, Date?)], loss: Int = 90, continuous: Bool = false) -> Bool {
            AwayLockSupport.canPauseScan(readings: readings, now: now,
                pauseSeconds: 12, scanSeconds: 3, lossSeconds: loss,
                requiresContinuousScan: continuous)
        }
        precondition(canPause([(true, now)]))
        precondition(!canPause([]))
        precondition(!canPause([(true, nil)]))
        precondition(!canPause([(false, now)]))
        precondition(!canPause([(true, now)], continuous: true))
        precondition(!canPause([(true, now)], loss: 15))
        precondition(!canPause([(true, now.addingTimeInterval(-75))]))
        precondition(!canPause([(true, now), (false, now)]))
        precondition(!canPause([(true, now.addingTimeInterval(1))]))

        var reads = 0
        var pending: ((Int) -> Void)?
        let clock = ClipboardPollingClock { completion in
            reads += 1
            pending = completion
        }
        var first: [Int] = []
        var second: [Int] = []
        var third: [Int] = []
        let firstID = clock.subscribe(interval: 1) { first.append($0) }
        precondition(clock.interval == 1)
        let secondID = clock.subscribe { second.append($0) }
        let thirdID = clock.subscribe { third.append($0) }
        precondition(clock.interval == 0.8)
        clock.poll()
        for _ in 0..<100 { clock.poll() }
        precondition(reads == 1) // A blocked server cannot accumulate reads.
        pending?(42)
        precondition(first == [42] && second == [42] && third == [42])
        clock.poll()
        precondition(reads == 2)
        clock.unsubscribe(secondID)
        clock.unsubscribe(thirdID)
        precondition(clock.interval == 1)
        pending?(43)
        precondition(first == [42, 43] && second == [42] && third == [42])
        clock.poll()
        clock.unsubscribe(firstID)
        precondition(clock.interval == nil)
        var restartedValues: [Int] = []
        let restarted = clock.subscribe { restartedValues.append($0) }
        pending?(44)
        precondition(restartedValues.isEmpty) // No stale delivery across restart.
        clock.poll()
        pending?(45)
        precondition(restartedValues == [45])
        clock.unsubscribe(restarted)
        let readsBeforeStop = reads
        clock.poll()
        precondition(reads == readsBeforeStop)
        var idleReads = 0
        var deliveries = 0
        let idleClock = ClipboardPollingClock { completion in
            idleReads += 1
            completion(100)
        }
        let idleIDs = (0..<3).map { _ in idleClock.subscribe { count in
            precondition(count == 100)
            deliveries += 1
        } }
        for _ in 0..<100 { idleClock.poll() }
        precondition(idleReads == 100 && deliveries == 300)
        idleIDs.forEach { idleClock.unsubscribe($0) }

        var removedCalls = 0
        let removalClock = ClipboardPollingClock { $0(1) }
        var removedID: UUID?
        let removerID = removalClock.subscribe { _ in removalClock.unsubscribe(removedID) }
        removedID = removalClock.subscribe { _ in removedCalls += 1 }
        removalClock.poll()
        precondition(removedCalls == 0)
        removalClock.unsubscribe(removerID)
        print("Energy optimization tests passed: scan safety, one shared read, blocked server, cadence and stale subscriptions")
    }
}
