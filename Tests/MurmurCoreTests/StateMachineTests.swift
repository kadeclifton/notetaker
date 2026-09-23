import XCTest
@testable import MurmurCore

final class StateMachineTests: XCTestCase {
    var machine = DictationStateMachine(timing: .init(tapMax: 0.25, doubleTapWindow: 0.35, chordGuard: 0.4, maxDuration: 300))

    func testHoldRecordsUntilRelease() {
        XCTAssertEqual(machine.handle(.hotkeyDown, at: 10), [.startRecording(.hold)])
        XCTAssertEqual(machine.mode, .hold)
        XCTAssertEqual(machine.handle(.tick, at: 11), [])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 12), [.finishRecording(.released)])
        XCTAssertFalse(machine.isRecording)
    }

    func testSingleShortTapIsDroppedAfterWindow() {
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 0.1), [])
        XCTAssertTrue(machine.isRecording, "keeps recording while a second tap may still come")
        XCTAssertEqual(machine.handle(.tick, at: 0.3), [])
        XCTAssertEqual(machine.handle(.tick, at: 0.46), [.discardRecording(.singleTap)])
        XCTAssertFalse(machine.isRecording)
    }

    func testDoubleTapStartsHandsFreeAndNextTapStops() {
        XCTAssertEqual(machine.handle(.hotkeyDown, at: 0), [.startRecording(.hold)])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 0.1), [])
        XCTAssertEqual(machine.handle(.hotkeyDown, at: 0.3), [.modeChanged(.handsFree)])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 0.4), [])
        XCTAssertEqual(machine.mode, .handsFree)
        XCTAssertEqual(machine.handle(.tick, at: 60), [])
        XCTAssertEqual(machine.handle(.otherKeyDown, at: 61), [], "typing does not end hands-free")
        XCTAssertEqual(machine.handle(.hotkeyDown, at: 90), [.finishRecording(.tappedToStop)])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 90.1), [], "the stopping tap's release is ignored")
        XCTAssertFalse(machine.isRecording)
    }

    func testHandsFreeStopsAtTimeLimit() {
        _ = machine.handle(.hotkeyDown, at: 0)
        _ = machine.handle(.hotkeyUp, at: 0.1)
        _ = machine.handle(.hotkeyDown, at: 0.2)
        _ = machine.handle(.hotkeyUp, at: 0.3)
        XCTAssertEqual(machine.remaining(at: 100), 200, accuracy: 0.001)
        XCTAssertEqual(machine.handle(.tick, at: 299.9), [])
        XCTAssertEqual(machine.handle(.tick, at: 300), [.finishRecording(.timeLimit)])
        XCTAssertFalse(machine.isRecording)
    }

    func testTimeLimitCanDiscard() {
        machine.timing.transcribeOnTimeLimit = false
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.tick, at: 301), [.discardRecording(.timeLimit)])
    }

    func testStuckHoldIsCappedToo() {
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.tick, at: 300), [.finishRecording(.timeLimit)])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 400), [], "late key-up does nothing")
    }

    func testEscapeDropsRecordingInEveryRecordingState() {
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.escape, at: 1), [.discardRecording(.escape)])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 2), [], "release after Esc does not transcribe")

        _ = machine.handle(.hotkeyDown, at: 10)
        _ = machine.handle(.hotkeyUp, at: 10.1)
        XCTAssertEqual(machine.handle(.escape, at: 10.2), [.discardRecording(.escape)])

        _ = machine.handle(.hotkeyDown, at: 20)
        _ = machine.handle(.hotkeyUp, at: 20.1)
        _ = machine.handle(.hotkeyDown, at: 20.2)
        XCTAssertEqual(machine.handle(.escape, at: 30), [.discardRecording(.escape)])
        XCTAssertFalse(machine.isRecording)
    }

    func testEscapeWhileIdleCancelsProcessing() {
        XCTAssertEqual(machine.handle(.escape, at: 0), [.cancelProcessing])
    }

    func testChordWithinGuardIsDropped() {
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.otherKeyDown, at: 0.2), [.discardRecording(.chord)])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 0.5), [])
    }

    func testOtherKeyAfterGuardKeepsRecording() {
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.otherKeyDown, at: 1), [])
        XCTAssertEqual(machine.handle(.hotkeyUp, at: 2), [.finishRecording(.released)])
    }

    func testTypingRightAfterATapDropsIt() {
        _ = machine.handle(.hotkeyDown, at: 0)
        _ = machine.handle(.hotkeyUp, at: 0.1)
        XCTAssertEqual(machine.handle(.otherKeyDown, at: 0.2), [.discardRecording(.singleTap)])
    }

    func testRepeatedKeyDownWhileHoldingIsIgnored() {
        _ = machine.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(machine.handle(.hotkeyDown, at: 0.5), [])
        XCTAssertEqual(machine.mode, .hold)
    }

    func testTimingFromConfig() {
        var config = Config()
        config.handsFree.maxMinutes = 2
        config.handsFree.onTimeLimit = "Discard"
        config.timing.doubleTapWindowMs = 500
        let timing = DictationStateMachine.Timing(config)
        XCTAssertEqual(timing.maxDuration, 120)
        XCTAssertEqual(timing.doubleTapWindow, 0.5)
        XCTAssertFalse(timing.transcribeOnTimeLimit)
    }
}
