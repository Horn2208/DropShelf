import XCTest

final class OrganizeTests: XCTestCase {
    private func plan(_ n: [String], _ r: RenameRule, dates: [Date] = []) -> [RenameStep] {
        Organize.renamePlan(n, rule: r, dates: dates)
    }
    private func news(_ p: [RenameStep]) -> [String] { p.map(\.new) }

    func testReplacePlainKeepsExtension() {
        let p = plan(["IMG_1.jpg", "IMG_2.png"], .replace(find: "IMG", with: "Foto", regex: false))
        XCTAssertEqual(news(p), ["Foto_1.jpg", "Foto_2.png"])
        XCTAssertTrue(p.allSatisfy { $0.problem == nil })
    }

    func testReplaceDoesNotTouchExtension() {
        XCTAssertEqual(news(plan(["a.png"], .replace(find: "png", with: "x", regex: false))), ["a.png"])
    }

    func testRegexOnOff() {
        let name = ["a1b22.txt"]
        XCTAssertEqual(news(plan(name, .replace(find: "\\d+", with: "#", regex: true))), ["a#b#.txt"])
        XCTAssertEqual(news(plan(name, .replace(find: "\\d+", with: "#", regex: false))), ["a1b22.txt"])
        XCTAssertEqual(news(plan(["ab.txt"], .replace(find: "(a)(b)", with: "$2$1", regex: true))), ["ba.txt"])
    }

    func testInvalidRegex() {
        let p = plan(["a.txt", "b.txt"], .replace(find: "(", with: "", regex: true))
        XCTAssertEqual(news(p), ["a.txt", "b.txt"])
        XCTAssertTrue(p.allSatisfy { $0.problem != nil })
    }

    func testAffix() {
        XCTAssertEqual(news(plan(["a.txt", "Makefile"], .affix(prefix: "x_", suffix: "_y"))), ["x_a_y.txt", "x_Makefile_y"])
    }

    func testCounterWidthAndStart() {
        XCTAssertEqual(news(plan(["a.txt", "b.txt"], .counter(start: 1, width: 1))), ["a - 1.txt", "b - 2.txt"])
        XCTAssertEqual(news(plan(["a.txt", "b.txt"], .counter(start: 1, width: 2))), ["a - 01.txt", "b - 02.txt"])
        XCTAssertEqual(news(plan(["a.txt", "b.txt"], .counter(start: 9, width: 2))), ["a - 09.txt", "b - 10.txt"])
    }

    func testDateFixedTimeZone() {
        // 2026-11-25 23:30 UTC ist in Berlin schon der 26.
        let d = Date(timeIntervalSince1970: 1_795_649_400)
        let utc = TimeZone(identifier: "UTC")!, berlin = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(news(plan(["a.txt"], .date(format: "yyyy-MM-dd", asPrefix: true, timeZone: utc), dates: [d])), ["2026-11-25 - a.txt"])
        XCTAssertEqual(news(plan(["a.txt"], .date(format: "yyyy-MM-dd", asPrefix: false, timeZone: berlin), dates: [d])), ["a - 2026-11-26.txt"])
    }

    func testMissingDate() {
        XCTAssertNotNil(plan(["a.txt"], .date(format: "yyyy", asPrefix: true, timeZone: .gmt)).first?.problem)
    }

    func testProblems() {
        XCTAssertEqual(plan(["a.txt"], .replace(find: "a", with: "", regex: false))[0].problem, "Leerer Name")
        XCTAssertNotNil(plan(["a.txt"], .replace(find: "a", with: "x/y", regex: false))[0].problem)
        XCTAssertNotNil(plan(["a.txt"], .affix(prefix: "a:", suffix: ""))[0].problem)
    }

    func testDuplicateTargets() {
        let p = plan(["a1.txt", "a2.txt", "b.txt"], .replace(find: "\\d", with: "", regex: true))
        XCTAssertNotNil(p[0].problem)
        XCTAssertNotNil(p[1].problem)
        XCTAssertNil(p[2].problem)
        // groß/klein zählt als Duplikat
        XCTAssertNotNil(plan(["A.txt", "a.txt"], .affix(prefix: "", suffix: ""))[0].problem)
    }
}
