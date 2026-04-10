import XCTest
@testable import SupersetShell

private final class DataBox: @unchecked Sendable {
    var value: Data?
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

final class OutputBatcherTests: XCTestCase {

    func testFlushProducesRawData() {
        let expectation = expectation(description: "Flushed")
        let box = DataBox()

        let batcher = OutputBatcher(sessionId: "test") { _, data in
            box.value = data
            expectation.fulfill()
        }

        batcher.append("hello".data(using: .utf8)!)
        batcher.flush()

        wait(for: [expectation], timeout: 1.0)

        let flushedData = box.value!
        // Raw bytes — no framing, delivered via evaluateJavaScript+base64
        XCTAssertEqual(flushedData.count, 5) // "hello" is 5 bytes
        XCTAssertEqual(String(data: flushedData, encoding: .utf8), "hello")
    }

    func testAutoFlushOnMaxSize() {
        let expectation = expectation(description: "Auto-flushed")

        let batcher = OutputBatcher(sessionId: "test") { _, _ in
            expectation.fulfill()
        }

        // Append more than maxFlushBytes (16KB)
        let bigData = Data(repeating: 0x41, count: 20000)
        batcher.append(bigData)

        wait(for: [expectation], timeout: 1.0)
    }

    func testReplayBuffer() {
        let batcher = OutputBatcher(sessionId: "test") { _, _ in }

        batcher.append("first".data(using: .utf8)!)
        batcher.flush()
        batcher.append("second".data(using: .utf8)!)
        batcher.flush()

        let replay = batcher.replayBuffer()
        XCTAssertNotNil(replay)
        // Replay contains raw bytes — delivered via evaluateJavaScript+base64
        // The replay buffer accumulates all raw input: "firstsecond"
        XCTAssertEqual(String(data: replay!, encoding: .utf8), "firstsecond")
    }

    func testEmptyFlushDoesNothing() {
        let counter = Counter()
        let batcher = OutputBatcher(sessionId: "test") { _, _ in
            counter.increment()
        }

        batcher.flush()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(counter.value, 0)
    }

    func testExitFrame() {
        let frame = OutputBatcher.makeExitFrame(code: 42, signal: 0)
        XCTAssertEqual(frame[0], 0x02) // exit frame type
        let length = UInt32(frame[1]) << 24 | UInt32(frame[2]) << 16
                   | UInt32(frame[3]) << 8  | UInt32(frame[4])
        let payload = frame[5..<(5 + Int(length))]
        let json = try! JSONSerialization.jsonObject(with: Data(payload)) as! [String: Any]
        XCTAssertEqual(json["code"] as? Int, 42)
        XCTAssertEqual(json["signal"] as? Int, 0)
    }
}
