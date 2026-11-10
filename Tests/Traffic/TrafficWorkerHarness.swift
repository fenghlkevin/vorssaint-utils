import Foundation
import Darwin

@main struct TrafficWorkerHarness {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--app-traffic-worker" {
            exit(AppTrafficWorker.run(parentPID: Int32(args[2]) ?? 0))
        }
        let child = Process()
        let life = Pipe()
        child.executableURL = URL(fileURLWithPath: args[0])
        child.arguments = ["--app-traffic-worker", String(getpid())]
        child.standardInput = life
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { exit(3) }
        try? life.fileHandleForReading.close()
        print(child.processIdentifier); fflush(stdout)
        if args.contains("--lifeline-close") {
            usleep(700_000)
            try? life.fileHandleForWriting.close()
            child.waitUntilExit()
            exit(child.terminationStatus)
        }
        if args.contains("--worker-term") {
            usleep(700_000)
            child.terminate()
            child.waitUntilExit()
            exit(child.terminationStatus)
        }
        withExtendedLifetime(life) { while true { sleep(1) } }
    }
}
