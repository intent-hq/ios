import Foundation
@testable import Intent
import Testing
import UIKit
import WebKit

@MainActor
struct HTMLFileResourcePolicyTests {
    private typealias Policy = HTMLFileResourcePolicy

    private static let host = "page-token"

    private func base(_ filePath: String = "reports/Demo report.html") throws -> URL {
        try #require(Policy.baseURL(host: Self.host, filePath: filePath))
    }

    private func resolve(_ reference: String, from filePath: String = "reports/Demo report.html") throws -> Policy.Resource {
        let url = try #require(URL(string: reference, relativeTo: try base(filePath))?.absoluteURL)
        return try Policy.resource(for: url, host: Self.host, root: Policy.Root(filePath: filePath))
    }

    private func rejection(_ reference: String, from filePath: String = "reports/Demo report.html") throws -> Policy.Rejection? {
        do {
            _ = try resolve(reference, from: filePath)
            return nil
        } catch let error as Policy.Rejection {
            return error
        }
    }

    @Test func baseURLPlacesTheReportUnderThePerPageWorkspaceRoot() throws {
        let url = try base()
        #expect(url.scheme == "intent-file")
        #expect(url.host() == Self.host)
        #expect(url.path(percentEncoded: true) == "/workspace/reports/Demo%20report.html")
        #expect(try base("./reports/./a.html").path(percentEncoded: true) == "/workspace/reports/a.html")
        #expect(Policy.baseURL(host: Self.host, filePath: "../a.html") == nil)
        #expect(Policy.baseURL(host: Self.host, filePath: "reports/../../a.html") == nil)
        #expect(Policy.baseURL(host: Self.host, filePath: "") == nil)
    }

    @Test func resolvesRelativeAndNestedReferencesInsideTheWorkspace() throws {
        #expect(try resolve("images/chart.png") == Policy.Resource(path: "reports/images/chart.png", kind: .image(mimeType: "image/png")))
        #expect(try resolve("./assets/deep/nested/report.css") == Policy.Resource(path: "reports/assets/deep/nested/report.css", kind: .stylesheet))
        #expect(try resolve("../shared/logo.JPG").path == "shared/logo.JPG")
        #expect(try resolve("Chart%20One.webp?v=2#top").path == "reports/Chart One.webp")
        #expect(try resolve("photo.jpeg").kind == .image(mimeType: "image/jpeg"))
        #expect(try resolve("loop.gif").kind == .image(mimeType: "image/gif"))
        #expect(try resolve("top.png", from: "index.html").path == "top.png")
    }

    @Test func rejectsEscapesAbsolutePathsAndOtherOrigins() throws {
        #expect(try rejection("../../secret.png") == .outsideWorkspace)
        #expect(try rejection("../../../../etc/passwd.png") == .outsideWorkspace)
        #expect(try rejection("/etc/secret.png") == .outsideWorkspace)
        #expect(try rejection("%2e%2e/%2e%2e/secret.png") == .outsideWorkspace)
        #expect(try rejection("images/..%2F..%2F..%2Fsecret.png") == .outsideWorkspace)
        #expect(try rejection("a%5C..%5Csecret.png") == .outsideWorkspace)
        #expect(try rejection("images%2Fchart.png") == .outsideWorkspace, "An encoded separator never splits a name")
        #expect(try rejection("bad%00name.png") == .outsideWorkspace)
        #expect(try rejection("images//chart.png") == .outsideWorkspace)
        #expect(try rejection("intent-file://other-page/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("intent-file://user@\(Self.host)/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("intent-file://\(Self.host):8080/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("https://\(Self.host)/workspace/reports/chart.png") == .wrongOrigin)
        #expect(try rejection("file:///workspace/reports/chart.png") == .wrongOrigin)
    }

    @Test func resolvesAssetsBesideAnAbsolutelyAddressedReport() throws {
        let report = "/Users/alice/project/reports/report.html"
        #expect(try base(report).path(percentEncoded: true) == "/absolute/Users/alice/project/reports/report.html")
        #expect(try resolve("chart.png", from: report) == Policy.Resource(
            path: "/Users/alice/project/reports/chart.png", kind: .image(mimeType: "image/png")
        ))
        #expect(try resolve("./img/My%20Chart.webp?v=1", from: report).path == "/Users/alice/project/reports/img/My Chart.webp")
        #expect(try resolve("../shared/site.css", from: report).path == "/Users/alice/project/shared/site.css")

        // A file:// link reaches the viewer as the same absolute path.
        let fileURL = try #require(URL(string: "file:///Users/alice/project/reports/report.html"))
        let fileLink = try #require(IntentFileLink.parsePath(fileURL))
        #expect(fileLink.path == report)
        #expect(try resolve("images/chart.png", from: fileLink.path).path == "/Users/alice/project/reports/images/chart.png")
        #expect(Policy.baseURL(host: Self.host, filePath: "/") == nil)
        #expect(Policy.baseURL(host: Self.host, filePath: "/Users/../etc/a.html") == nil)
        #expect(Policy.baseURL(host: Self.host, filePath: "//Users/a.html") == nil)
    }

    @Test func rejectsEscapesInBothModesAndNeverCrossesBetweenThem() throws {
        let report = "/Users/alice/project/reports/report.html"
        for reference in [
            "../../../../../secret.png", "/etc/secret.png", "%2e%2e/%2e%2e/secret.png", "images/..%2F..%2Fsecret.png",
            "images%2Fchart.png", "a%5C..%5Csecret.png", "bad%00name.png", "images//chart.png",
            "../../../../workspace/secret.png", "/workspace/reports/chart.png"
        ] {
            #expect(try rejection(reference, from: report) == .outsideWorkspace, "\(reference)")
        }
        #expect(try rejection("intent-file://other-page/absolute/Users/alice/chart.png", from: report) == .wrongOrigin)
        #expect(try rejection("file:///Users/alice/project/reports/chart.png", from: report) == .wrongOrigin)

        // A workspace-relative report can never reach an absolute path.
        #expect(try rejection("../../absolute/etc/secret.png") == .outsideWorkspace)
        #expect(try rejection("/absolute/Users/alice/chart.png") == .outsideWorkspace)
        let absoluteURL = try #require(URL(string: "chart.png", relativeTo: try base(report))?.absoluteURL)
        #expect(throws: Policy.Rejection.outsideWorkspace) { try Policy.resource(for: absoluteURL, host: Self.host, root: .workspace) }
    }

    @Test func rejectsTypesOtherThanImagesStylesheetsAndFonts() throws {
        for reference in ["page.html", "app.js", "logo.svg", "clip.mp4", "data.json", "README", "archive.png.zip"] {
            #expect(try rejection(reference) == .unsupportedType, "\(reference)")
        }
    }

    @Test func validatesContentAgainstTheDeclaredType() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        #expect(throws: Never.self) { try Policy.validate(png, as: .image(mimeType: "image/png")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("<html></html>".utf8), as: .image(mimeType: "image/png")) }
        #expect(throws: Never.self) { try Policy.validate(Data("h1 { color: red; }".utf8), as: .stylesheet) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data([0x68, 0x00, 0x31]), as: .stylesheet) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data([0xFF, 0xFE, 0xFD]), as: .stylesheet) }
    }

    @Test func allowsOnlyWebFontTypes() throws {
        #expect(try resolve("fonts/Report.woff2") == Policy.Resource(path: "reports/fonts/Report.woff2", kind: .font(mimeType: "font/woff2")))
        #expect(try resolve("fonts/Report.WOFF").kind == .font(mimeType: "font/woff"))
        #expect(try resolve("Report.ttf").kind == .font(mimeType: "font/ttf"))
        #expect(try resolve("Report.otf").kind == .font(mimeType: "font/otf"))
        for reference in ["Report.eot", "Report.ttc", "Report.dfont", "Report.fon", "Report.svgz", "Report.woff3"] {
            #expect(try rejection(reference) == .unsupportedType, "\(reference)")
        }
        #expect(try rejection("../../fonts/Report.woff2") == .outsideWorkspace)
    }

    @Test func validatesFontSignatures() throws {
        let inter = try Data(contentsOf: try #require(Bundle.main.url(forResource: "Inter-Regular", withExtension: "ttf")))
        #expect(throws: Never.self) { try Policy.validate(inter, as: .font(mimeType: "font/ttf")) }
        let accepted: [(String, [UInt8])] = [
            ("font/woff2", Array("wOF2".utf8)), ("font/woff", Array("wOFF".utf8)),
            ("font/ttf", Array("true".utf8)), ("font/otf", Array("OTTO".utf8))
        ]
        for (mimeType, signature) in accepted {
            let data = Data(signature + [0, 0, 0, 0])
            #expect(throws: Never.self, "\(mimeType)") { try Policy.validate(data, as: .font(mimeType: mimeType)) }
        }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(inter, as: .font(mimeType: "font/woff2")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("wOF".utf8), as: .font(mimeType: "font/woff2")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("<html>".utf8), as: .font(mimeType: "font/ttf")) }
        #expect(throws: Policy.Rejection.invalidContent) { try Policy.validate(Data("OTTO".utf8), as: .font(mimeType: "font/eot")) }
    }

    @Test func contentSecurityPolicyWidensOnlyImagesStylesAndFontsToTheScheme() {
        let directives = Policy.contentSecurityPolicy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(directives == [
            "default-src 'none'",
            "style-src 'unsafe-inline' intent-file:",
            "img-src data: intent-file:",
            "font-src intent-file:",
            "base-uri 'none'",
            "form-action 'none'"
        ])
    }

    @Test func webViewRegistersTheSchemeWithJavaScriptOff() async throws {
        let handler = HTMLFileResourceHandler(workspaceId: "ws") { _, _, _ in Data() }
        let coordinator = HTMLFileWebView.Coordinator(resources: handler) {}
        let webView = HTMLFileWebView.makeWebView(coordinator: coordinator, rules: try await HTMLFileWebView.blockingRules())
        defer { HTMLFileWebView.dismantleUIView(webView, coordinator: coordinator) }
        let registered = webView.configuration.urlSchemeHandler(forURLScheme: Policy.scheme) as? HTMLFileResourceHandler
        #expect(registered === handler)
        #expect(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
    }
}
