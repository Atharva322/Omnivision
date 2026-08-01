//
//  trackc-eval
//  Track C — runs the fixture suites and prints the extraction report.
//
//  Usage:
//      swift run trackc-eval [fixtures-directory]        (default: ./Fixtures)
//      scripts/swift-linux.sh run trackc-eval Fixtures
//
//  Exit code is non-zero when any fixture expectation is unmet, so it can gate CI.
//

import Foundation
import AccessLensTrackC

let arguments = CommandLine.arguments
let directoryPath = arguments.count > 1 ? arguments[1] : "Fixtures"
let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)

do {
    let suites = try FixtureSuite.loadAll(in: directory)
    guard !suites.isEmpty else {
        FileHandle.standardError.write(Data("no fixture files found in \(directory.path)\n".utf8))
        exit(2)
    }

    let denylist = NameDenylist.bundled()
    let validator = PortableNameValidator()
    let evaluator = FixtureEvaluator(
        parser: LumenCommandParser(
            slotResolver: NameSlotResolver(denylist: denylist, validator: validator)
        ),
        extractor: NameExtractor(denylist: denylist, validator: validator)
    )

    let report = evaluator.evaluate(suites)
    print("Suites: " + suites.map(\.name).joined(separator: ", "))
    print("")
    print(report.formatted(denylist: denylist, validatorID: validator.validatorID))

    exit(report.passed ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("failed to load fixtures: \(error)\n".utf8))
    exit(2)
}
