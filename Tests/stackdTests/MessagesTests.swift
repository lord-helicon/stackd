import Foundation
import Testing
@testable import stackd

struct MessagesTests {
    private func vmMessage(
        id: String = "vm-1", name: String = "web", status: String = "running",
        org: String = "acme", domain: String = "boxd.sh",
        vcpu: UInt64 = 4, memory: UInt64 = 8 << 30, created: Int64 = 1_700_000_000
    ) -> ProtoWriter {
        var w = ProtoWriter()
        w.appendString(1, id)
        w.appendString(2, name)
        w.tag(99, WireType.varint); w.appendRawVarint(7) // unknown
        w.appendString(5, status)
        w.appendString(10, org)
        w.appendString(12, domain)
        w.tag(50, WireType.lengthDelimited); w.appendRawVarint(2); w.raw([9, 9]) // unknown
        w.appendUInt64(15, vcpu)
        w.appendUInt64(16, memory)
        w.appendInt64(17, created)
        return w
    }

    @Test func vmURLIsPinnedToPlainHostnames() throws {
        func url(_ name: String, _ domain: String = "boxd.sh") throws -> URL? {
            try Vm(proto: vmMessage(name: name, domain: domain).data).url
        }
        #expect(try url("web")?.absoluteString == "https://web.boxd.sh")
        #expect(try url("a-b1", "x.example.com")?.absoluteString == "https://a-b1.x.example.com")
        for bad in ["a/b", "a#b", "a?b", "a@b", "a:b", "a b", "a.b", "-web", "web-", "", String(repeating: "a", count: 64)] {
            #expect(try url(bad) == nil, "name \(bad)")
        }
        let longDomain = Array(repeating: String(repeating: "a", count: 60), count: 5).joined(separator: ".")
        for bad in ["boxd.sh/x", "boxd.sh#x", "boxd.sh?x", "evil.com@boxd.sh", "boxd.sh:99", "box d.sh",
                    "boxd..sh", ".boxd.sh", "boxd.sh.", "-boxd.sh", "boxd-.sh", "", String(repeating: "a", count: 64) + ".sh", longDomain] {
            #expect(try url("web", bad) == nil, "domain \(bad)")
        }
    }

    @Test func decodesVm() throws {
        let vm = try Vm(proto: vmMessage().data)
        #expect(vm.id == "vm-1")
        #expect(vm.name == "web")
        #expect(vm.status == .running)
        #expect(vm.org == "acme")
        #expect(vm.accessDomain == "boxd.sh")
        #expect(vm.vcpu == 4)
        #expect(vm.memoryBytes == 8 << 30)
        #expect(vm.memoryGiB == 8)
        #expect(vm.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(vm.sizeLabel == "4×8G")
        #expect(vm.url == URL(string: "https://web.boxd.sh"))
    }

    @Test func optionalVmFields() throws {
        var w = ProtoWriter()
        w.appendString(3, "img"); w.appendString(4, "1.2.3.4"); w.appendString(14, "fork/x")
        let vm = try Vm(proto: w.data)
        #expect(vm.imageRef == "img")
        #expect(vm.publicIP == "1.2.3.4")
        #expect(vm.source == "fork/x")
        #expect(vm.url == nil)
        #expect(vm.createdAt == nil)
    }

    @Test func urlNilWithoutNameOrDomain() throws {
        #expect(try Vm(proto: vmMessage(domain: "").data).url == nil)
        #expect(try Vm(proto: vmMessage(name: "").data).url == nil)
    }

    @Test func hugeVcpuDoesNotCrash() throws {
        let vm = try Vm(proto: vmMessage(vcpu: UInt64.max).data)
        #expect(vm.vcpu == UInt32.max)
    }

    @Test func decodeList() throws {
        var w = ProtoWriter()
        w.appendMessage(1, vmMessage(id: "a", name: "one"))
        w.appendString(2, "ssh-host-key")
        w.appendMessage(1, vmMessage(id: "b", name: "two", status: "stopped"))
        w.appendMessage(1, vmMessage(id: "c", name: "three", status: "weird"))
        let vms = try Vm.decodeList(w.data)
        #expect(vms.map(\.id) == ["a", "b", "c"])
        #expect(vms.map(\.name) == ["one", "two", "three"])
        #expect(vms[1].status == .stopped)
        #expect(vms[2].status == .unknown("weird"))
        #expect(try Vm.decodeList(Data()).isEmpty)
    }

    @Test func decodeListTruncatedThrows() {
        #expect(throws: ProtoError.self) { try Vm.decodeList(Data([0x0A, 0x10, 1])) }
    }

    @Test func statusMapping() {
        #expect(VmStatus(raw: "running") == .running)
        #expect(VmStatus(raw: "stopped") == .stopped)
        #expect(VmStatus(raw: "standby") == .standby)
        // The API reports a paused VM as "suspended" (verified live); the CLI shows it as standby.
        #expect(VmStatus(raw: "suspended") == .standby)
        #expect(VmAction.actions(for: VmStatus(raw: "suspended")) == [.resume, .stop, .destroy])
        #expect(VmStatus(raw: "hibernated") == .hibernated)
        #expect(VmStatus(raw: "failed") == .failed)
        #expect(VmStatus(raw: "hibernating") == .transitional("hibernating"))
        #expect(VmStatus(raw: "starting").isTransitional)
        #expect(VmStatus(raw: "teleporting") == .unknown("teleporting"))
        #expect(!VmStatus(raw: "teleporting").isTransitional)
        #expect(VmStatus(raw: "teleporting").displayText == "teleporting")
        #expect(VmStatus.running.displayText == "running")
        #expect(VmStatus(raw: "").displayText == "")
    }

    @Test func actionMatrix() {
        #expect(VmAction.actions(for: .running) == [.stop, .reboot, .pause, .hibernate, .destroy])
        #expect(VmAction.actions(for: .stopped) == [.start, .destroy])
        #expect(VmAction.actions(for: .standby) == [.resume, .stop, .destroy])
        #expect(VmAction.actions(for: .hibernated) == [.wake, .destroy])
        #expect(VmAction.actions(for: .failed) == [.start, .destroy])
        #expect(VmAction.actions(for: .transitional("starting")).isEmpty)
        #expect(VmAction.actions(for: .unknown("x")).isEmpty)
    }

    @Test func actionMetadata() {
        #expect(VmAction.destroy.isDestructive)
        #expect(VmAction.allCases.filter(\.needsConfirm) == [.stop, .reboot, .destroy])
        #expect(VmAction.pause.methodName == "SuspendVm")
    }

    @Test func decodesIdentityWithBilling() throws {
        var b = ProtoWriter()
        b.appendString(3, "active")
        b.appendUInt32(7, 12)
        b.appendInt64(10, 12_340_000)
        b.appendString(11, "credits")
        b.appendString(12, "eur")
        var w = ProtoWriter()
        w.appendString(1, "user-1")
        w.appendMessage(4, b)
        w.appendString(5, "Ada")
        w.tag(77, WireType.fixed32); w.raw([0, 0, 0, 0])
        let id = try Identity(proto: w.data)
        #expect(id.userID == "user-1")
        #expect(id.displayName == "Ada")
        #expect(id.title == "Ada")
        let billing = try #require(id.billing)
        #expect(billing.subscriptionStatus == "active")
        #expect(billing.maxVMs == 12)
        #expect(billing.balanceMicro == 12_340_000)
        #expect(billing.billingMode == "credits")
        #expect(billing.currency == "eur")
        #expect(billing.balanceLabel == "€12.34")
    }

    @Test func identityTitleFallsBackToUserID() throws {
        var w = ProtoWriter()
        w.appendString(1, "user-1")
        let id = try Identity(proto: w.data)
        #expect(id.title == "user-1")
        #expect(id.billing == nil)
    }

    private func billing(mode: String, currency: String, micro: Int64) throws -> Billing {
        var w = ProtoWriter()
        w.appendInt64(10, micro)
        w.appendString(11, mode)
        w.appendString(12, currency)
        return try Billing(proto: w.data)
    }

    @Test func balanceLabels() throws {
        #expect(try billing(mode: "credits", currency: "eur", micro: 5_000_000).balanceLabel == "€5.00")
        #expect(try billing(mode: "credits", currency: "usd", micro: 2_500_000).balanceLabel == "$2.50")
        #expect(try billing(mode: "credits", currency: "chf", micro: 1_000_000).balanceLabel == "CHF 1.00")
        #expect(try billing(mode: "stripe", currency: "eur", micro: 5_000_000).balanceLabel == nil)
    }

    @Test func negativeBalance() throws {
        let b = try billing(mode: "credits", currency: "usd", micro: -3_000_000)
        #expect(b.balanceMicro == -3_000_000)
        #expect(b.balanceLabel == "-$3.00")
    }

    @Test func hugeMaxVMsDoesNotCrash() throws {
        var w = ProtoWriter()
        w.tag(7, WireType.varint); w.appendRawVarint(UInt64.max)
        #expect(try Billing(proto: w.data).maxVMs == UInt32.max)
    }

    @Test func requestBuilders() throws {
        #expect(BoxdRequests.vmID("abc").elementsEqual([0x0A, 3, 0x61, 0x62, 0x63]))
        #expect(BoxdRequests.listVms(org: "", allContexts: false).isEmpty)
        #expect(BoxdRequests.listVms(org: "o", allContexts: true).elementsEqual([0x0A, 1, 0x6F, 0x10, 1]))
    }
}
