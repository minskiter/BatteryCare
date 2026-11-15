// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

final class StubProtocol: URLProtocol {
    static var offline = false
    static var reject = false
    static var writes: [URLRequest] = []
    static var enabled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let method = request.httpMethod ?? "GET"
        if method != "GET" { Self.writes.append(request) }
        let fixture = """
        {"service":{"running":true},"battery":{"percentage":72,"is_charging":false,"cycle_count":491,"health_percentage":82},"temperature":{"cpu_celsius":54.5,"limit_celsius":80},"auto_discharge":{"enabled":false,"cycle_active":false,"cpu_load_active":false,"caffeinate_active":false},"config":{"auto_discharge_enabled":false,"low_battery_threshold":10,"high_battery_threshold":20,"temp_limit":80,"cool_down_sleep":30,"loop_interval":60}}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reject ? 400 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (Self.reject ? "{\"message\":\"test rejection\"}" : fixture).data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ModelTests {
    @MainActor static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let model = BatteryModel(session: URLSession(configuration: config), poll: false)
        await model.refresh()
        precondition(model.connected && model.batteryLabel == "72%" && !model.enabled)
        print("PASS live status decoding")
        StubProtocol.offline = true; await model.refresh()
        precondition(!model.connected && model.batteryLabel == "72%")
        model.toggle(false); precondition(StubProtocol.writes.isEmpty)
        print("PASS offline retains last reading and disables writes")
        StubProtocol.offline = false; await model.refresh()
        var draft = model.status!.config; draft.low_battery_threshold = 30
        model.save(draft)
        precondition(model.message != nil && StubProtocol.writes.isEmpty)
        print("PASS invalid thresholds rejected without HTTP write")
        draft = model.status!.config; draft.high_battery_threshold = 25
        model.save(draft)
        while model.busy { try? await Task.sleep(nanoseconds: 20_000_000) }
        precondition(StubProtocol.writes.count == 1 && StubProtocol.writes[0].httpMethod == "PATCH")
        print("PASS parameter save uses PATCH")
        StubProtocol.reject = true
        model.toggle(false)
        while model.busy { try? await Task.sleep(nanoseconds: 20_000_000) }
        precondition(model.message == "test rejection")
        print("PASS API rejection surfaced")
        print("All model tests passed; no real battery requests were sent.")
    }
}
