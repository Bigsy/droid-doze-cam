import XCTest
import DroidDozeCamCore
@testable import droiddozecam

@MainActor
final class AppUpdateTests: XCTestCase {
    private func fixture(_ test: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await test(directory)
    }

    func testActiveCameraBlocksUpdateAndIdleCameraAllowsIt() async throws {
        try await fixture { directory in
            let maintenance = AppUpdateMaintenance(directory: directory)
            let status = ServiceStatusFile(directory: directory)
            for state in [ServiceStatus.State.starting, .streaming, .reconnecting, .problem] {
                try status.publish(ServiceStatus(state: state, detail: "fixture"))
                XCTAssertThrowsError(try maintenance.requireIdle())
            }
            try status.publish(ServiceStatus(state: .idle, detail: "fixture"))
            XCTAssertNoThrow(try maintenance.requireIdle())
            try status.publish(ServiceStatus(state: .streaming, detail: "stale", pid: 999999))
            XCTAssertNoThrow(try maintenance.requireIdle())
        }
    }

    func testInterruptedInstallationRestartsServiceOnSameBuild() async throws {
        try await fixture { directory in
            let plist = directory.appendingPathComponent("service.plist")
            try Data().write(to: plist)
            let marker = directory.appendingPathComponent("pending-app-update.json")
            var loaded = true
            var starts = 0
            let maintenance = AppUpdateMaintenance(directory: directory, servicePlist: plist,
                build: "1", installed: true, command: { _, args in
                    switch args.first {
                    case "print": return CommandResult(status: loaded ? 0 : 1, text: "")
                    case "bootout":
                        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Persist recovery before stopping launchd")
                        loaded = false
                    case "bootstrap": loaded = true; starts += 1
                    default: break
                    }
                    return CommandResult(status: 0, text: "")
                })
            try maintenance.prepare()
            XCTAssertFalse(loaded)
            let recovered = expectation(description: "recovered")
            maintenance.recover { recovered.fulfill() }
            await fulfillment(of: [recovered], timeout: 2)
            XCTAssertTrue(loaded)
            XCTAssertEqual(starts, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testServiceThatWasStoppedRemainsStoppedAfterUpgrade() async throws {
        try await fixture { directory in
            let plist = directory.appendingPathComponent("service.plist")
            try Data().write(to: plist)
            var mutations = 0
            let command: (String, [String]) throws -> CommandResult = { _, args in
                if ["bootstrap", "bootout"].contains(args.first ?? "") { mutations += 1 }
                return CommandResult(status: args.first == "print" ? 1 : 0, text: "")
            }
            let old = AppUpdateMaintenance(directory: directory, servicePlist: plist, build: "1", installed: true, command: command)
            try old.prepare()
            let new = AppUpdateMaintenance(directory: directory, servicePlist: plist, build: "2", installed: true, command: command)
            let recovered = expectation(description: "new app recovered")
            new.recover { recovered.fulfill() }
            await fulfillment(of: [recovered], timeout: 2)
            XCTAssertEqual(mutations, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-app-update.json").path))
        }
    }

    func testFailedServiceRestartRetainsRecoveryState() async throws {
        try await fixture { directory in
            let plist = directory.appendingPathComponent("service.plist")
            try Data().write(to: plist)
            var loaded = true
            var issues = 0
            let maintenance = AppUpdateMaintenance(directory: directory, servicePlist: plist,
                build: "1", installed: true, command: { _, args in
                    if args.first == "print" { return CommandResult(status: loaded ? 0 : 1, text: "") }
                    if args.first == "bootout" { loaded = false }
                    return CommandResult(status: args.first == "bootstrap" ? 1 : 0, text: "fixture failure")
                })
            maintenance.onIssue = { _, _ in issues += 1 }
            try maintenance.prepare()
            let recovered = expectation(description: "recovery attempted")
            maintenance.recover { recovered.fulfill() }
            await fulfillment(of: [recovered], timeout: 2)
            XCTAssertEqual(issues, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-app-update.json").path))
            XCTAssertNoThrow(try maintenance.prepare())
            let data = try Data(contentsOf: directory.appendingPathComponent("pending-app-update.json"))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(state["restartService"] as? Bool, true, "Carry the failed restart into the next update")
        }
    }

    func testApprovedExtensionIsMatchedInTabSeparatedSystemListing() async throws {
        try await fixture { directory in
            let maintenance = AppUpdateMaintenance(directory: directory, build: "1", installed: true,
                identifier: "dev.fixture.camera", command: { _, args in
                    if args.first == "print" { return CommandResult(status: 1, text: "") }
                    return CommandResult(status: 0, text: "*\t*\tTEAM\tdev.fixture.camera (0.1.0/1)\tCamera\t[activated enabled]")
                })
            try maintenance.prepare()
            let data = try Data(contentsOf: directory.appendingPathComponent("pending-app-update.json"))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(state["replaceExtension"] as? Bool, true)
        }
    }

    func testFailedExtensionListingNeverStopsService() async throws {
        try await fixture { directory in
            var stops = 0
            let maintenance = AppUpdateMaintenance(directory: directory, build: "1", installed: true,
                command: { _, args in
                    if args.first == "bootout" { stops += 1 }
                    return CommandResult(status: args.first == "list" ? 1 : 0, text: "fixture failure")
                })
            XCTAssertThrowsError(try maintenance.prepare())
            XCTAssertEqual(stops, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-app-update.json").path))
        }
    }

    func testApprovedBuildParserIgnoresOtherExtensionsAndInactiveVersions() {
        let listing = """
        *\t*\tTEAM\tdev.fixture.camera.extra (0.1.1/300)\tOther\t[activated enabled]
        \t\tTEAM\tdev.fixture.camera (0.1.0/100)\tCamera\t[terminated waiting to uninstall on reboot]
        *\t*\tTEAM\tdev.fixture.camera (0.1.1/200)\tCamera\t[activated enabled]
        """
        XCTAssertEqual(AppUpdateMaintenance.approvedExtensionBuild(in: listing, identifier: "dev.fixture.camera"), "200")
        XCTAssertNil(AppUpdateMaintenance.approvedExtensionBuild(in: listing, identifier: "dev.missing.camera"))
        XCTAssertNil(AppUpdateMaintenance.approvedExtensionBuild(in: "dev.fixture.camera (0.1.1/bad) [activated enabled]", identifier: "dev.fixture.camera"))
    }

    func testManualUpgradeDefersWhileCameraIsInUseAndKeepsRecoveryState() async throws {
        try await fixture { directory in
            try ServiceStatusFile(directory: directory).publish(ServiceStatus(state: .streaming, detail: "fixture"))
            var stops = 0
            var issues = 0
            let maintenance = AppUpdateMaintenance(directory: directory, build: "200", installed: true,
                identifier: "dev.fixture.camera", command: { _, args in
                    if args.first == "bootout" { stops += 1 }
                    return CommandResult(status: 0, text: "*\t*\tTEAM\tdev.fixture.camera (0.1.0/100)\tCamera\t[activated enabled]")
                })
            maintenance.onIssue = { _, _ in issues += 1 }
            let finished = expectation(description: "manual update deferred")
            maintenance.recover { finished.fulfill() }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(stops, 0)
            XCTAssertEqual(issues, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-app-update.json").path))
        }
    }

    func testMatchingOrNewerInstalledExtensionNeedsNoRecovery() async throws {
        try await fixture { directory in
            for build in ["200", "300"] {
                var mutations = 0
                let maintenance = AppUpdateMaintenance(directory: directory, build: "200", installed: true,
                    identifier: "dev.fixture.camera", command: { _, args in
                        if args.first != "list" { mutations += 1 }
                        return CommandResult(status: 0, text: "dev.fixture.camera (0.1.1/\(build)) Camera [activated enabled]")
                    })
                var finished = false
                maintenance.recover { finished = true }
                XCTAssertTrue(finished)
                XCTAssertEqual(mutations, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-app-update.json").path))
            }
        }
    }

    func testAnotherAppUpdatePreservesDeferredExtensionAndStopsLoadedService() async throws {
        try await fixture { directory in
            let marker = directory.appendingPathComponent("pending-app-update.json")
            try JSONSerialization.data(withJSONObject: ["previousBuild": "100", "restartService": false,
                                                        "replaceExtension": true]).write(to: marker)
            var stops = 0
            let maintenance = AppUpdateMaintenance(directory: directory, build: "200", installed: true,
                command: { _, args in
                    if args.first == "bootout" { stops += 1 }
                    return CommandResult(status: 0, text: "")
                })
            try maintenance.prepare()
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            XCTAssertEqual(state["previousBuild"] as? String, "100")
            XCTAssertEqual(state["replaceExtension"] as? Bool, true)
            XCTAssertEqual(state["restartService"] as? Bool, true)
            XCTAssertEqual(stops, 1)
        }
    }

    func testMalformedRecoveryStateNeverStopsServiceOrGetsOverwritten() async throws {
        try await fixture { directory in
            let marker = directory.appendingPathComponent("pending-app-update.json")
            let data = Data("incomplete recovery".utf8)
            try data.write(to: marker)
            var commands = 0
            let maintenance = AppUpdateMaintenance(directory: directory, command: { _, _ in
                commands += 1
                return CommandResult(status: 0, text: "")
            })
            XCTAssertThrowsError(try maintenance.prepare())
            XCTAssertEqual(commands, 0)
            XCTAssertEqual(try Data(contentsOf: marker), data)
        }
    }
}
