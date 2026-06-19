import XCTest
@testable import Surfr

final class FirstRunReducerTests: XCTestCase {

    typealias Action = FirstRunReducer.Action
    typealias Effect = FirstRunReducer.Effect
    typealias Step = FirstRunReducer.Step

    // The only happy path: set master → kit exists → acknowledge → commit.
    func test_happyPath_commitsOnlyAfterKit() {
        var r = FirstRunReducer()
        XCTAssertEqual(r.step, .setMaster)

        XCTAssertEqual(r.apply(.masterAccepted), .createInMemoryVault)
        XCTAssertEqual(r.step, .recoveryKit)

        XCTAssertEqual(r.apply(.acknowledgeKit), .commitToDisk)
        XCTAssertEqual(r.step, .committed)
    }

    // The load-bearing attack: try to acknowledge a kit that was never created.
    func test_cannotAcknowledgeKitBeforeItExists() {
        var r = FirstRunReducer()
        XCTAssertEqual(r.apply(.acknowledgeKit), .none, "acknowledging from setMaster must NOT commit")
        XCTAssertEqual(r.step, .setMaster)
    }

    // Abandon between create and acknowledge resets, so a later acknowledge cannot commit.
    func test_abandonThenAcknowledge_doesNotCommit() {
        var r = FirstRunReducer()
        _ = r.apply(.masterAccepted)               // → recoveryKit
        XCTAssertEqual(r.apply(.abandon), .wipeInMemory)
        XCTAssertEqual(r.step, .setMaster)
        XCTAssertEqual(r.apply(.acknowledgeKit), .none, "after abandon, the kit is gone")
        XCTAssertEqual(r.step, .setMaster)
    }

    // Abandon from any state wipes and resets.
    func test_abandon_alwaysWipesAndResets() {
        for prefix in [[Action](), [.masterAccepted], [.masterAccepted, .acknowledgeKit]] {
            var r = FirstRunReducer()
            for a in prefix { _ = r.apply(a) }
            XCTAssertEqual(r.apply(.abandon), .wipeInMemory)
            XCTAssertEqual(r.step, .setMaster)
        }
    }

    /// INVARIANT (brute force): over **every** action sequence up to length 7, a `.commitToDisk`
    /// effect is emitted only when the reducer was in `.recoveryKit` immediately before — and
    /// `.recoveryKit` is reachable only via `masterAccepted` (which emits `.createInMemoryVault`).
    /// Therefore no path reaches a committed vault without first creating, and acknowledging, the kit.
    func test_invariant_noCommitWithoutKitStep() {
        let alphabet: [Action] = [.masterAccepted, .acknowledgeKit, .abandon]
        var checked = 0

        func walk(_ seq: [Action]) {
            // Replay and assert at each commit that the pre-step was recoveryKit, and that a
            // createInMemoryVault effect occurred earlier in this run with no later reset.
            var r = FirstRunReducer()
            var kitReady = false   // createInMemoryVault happened and not since wiped
            for action in seq {
                let preStep = r.step
                let effect = r.apply(action)
                switch effect {
                case .createInMemoryVault:
                    XCTAssertEqual(preStep, .setMaster)
                    kitReady = true
                case .wipeInMemory:
                    kitReady = false
                case .commitToDisk:
                    XCTAssertEqual(preStep, .recoveryKit, "commit from \(preStep) via \(action)")
                    XCTAssertTrue(kitReady, "commit without a live in-memory kit: \(seq)")
                case .none:
                    break
                }
            }
            checked += 1
        }

        func generate(_ prefix: [Action], _ depth: Int) {
            walk(prefix)
            guard depth > 0 else { return }
            for a in alphabet { generate(prefix + [a], depth - 1) }
        }
        generate([], 7)
        XCTAssertGreaterThan(checked, 2000)   // sanity: we really did enumerate the space
    }
}
