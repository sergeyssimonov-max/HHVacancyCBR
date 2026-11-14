import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

// Keep the XCTestCase identity and stored fixtures stable for selective test commands.
final class HHVacancyCBRTests: XCTestCase {



    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    static let areaTree = HHAreaNode(id: "113", name: "Россия", areas: [
        .init(id: "1", name: "Москва"),
        .init(id: "2", name: "Санкт-Петербург"),
        .init(id: "66", name: "Свердловская область", areas: [.init(id: "3", name: "Екатеринбург")])
    ])
}
