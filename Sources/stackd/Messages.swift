import Foundation

/// Decoded models for the boxd API. Field numbers per the published proto
/// (docs.boxd.sh/reference/grpc-proto.md); unknown fields are skipped.

// MARK: - VM status

enum VmStatus: Hashable {
    case running, stopped, standby, hibernated, failed
    case transitional(String) // starting / hibernating / rebooting / destroying / …
    case unknown(String)      // anything new server-side; displays raw value

    init(raw: String) {
        switch raw {
        case "running": self = .running
        case "stopped": self = .stopped
        case "standby", "suspended": self = .standby // the API says "suspended"; CLI/docs call it standby
        case "hibernated": self = .hibernated
        case "failed": self = .failed
        case "starting", "stopping", "rebooting", "pausing", "resuming",
             "hibernating", "waking", "destroying":
            self = .transitional(raw)
        default:
            self = .unknown(raw)
        }
    }

    var displayText: String {
        switch self {
        case .running: return "running"
        case .stopped: return "stopped"
        case .standby: return "standby"
        case .hibernated: return "hibernated"
        case .failed: return "failed"
        case .transitional(let raw), .unknown(let raw): return raw
        }
    }

    var isTransitional: Bool {
        if case .transitional = self { return true }
        return false
    }
}

// MARK: - VM

struct Vm: Identifiable, Hashable {
    var id = ""            // vm_id = 1
    var name = ""          // 2
    var imageRef = ""      // 3
    var publicIP = ""      // 4
    var status: VmStatus = .unknown("") // 5
    var org = ""           // 10: org the VM is shared with; "" = not shared
    var accessDomain = ""  // 12: org custom domain or cluster zone (e.g. boxd.sh)
    var source = ""        // 14: "standalone" | "fork/<name>" | "snapshot/<n>:<v>"
    var vcpu: UInt32 = 0   // 15
    var memoryBytes: UInt64 = 0 // 16
    var createdAt: Date?   // 17, unix seconds

    var memoryGiB: UInt64 { memoryBytes >> 30 }
    var sizeLabel: String { "\(vcpu)×\(memoryGiB)G" }
    var url: URL? {
        guard !name.isEmpty, !accessDomain.isEmpty else { return nil }
        return URL(string: "https://\(name).\(accessDomain)")
    }

    init(proto data: Data) throws {
        var r = ProtoReader(data)
        while let f = try r.nextField() {
            switch f.field {
            case 1: id = try r.readString()
            case 2: name = try r.readString()
            case 3: imageRef = try r.readString()
            case 4: publicIP = try r.readString()
            case 5: status = VmStatus(raw: try r.readString())
            case 10: org = try r.readString()
            case 12: accessDomain = try r.readString()
            case 14: source = try r.readString()
            case 15: vcpu = UInt32(clamping: try r.readUInt64())
            case 16: memoryBytes = try r.readUInt64()
            case 17:
                let secs = try r.readInt64()
                createdAt = secs > 0 ? Date(timeIntervalSince1970: TimeInterval(secs)) : nil
            default: try r.skip(f.wire)
            }
        }
    }

    /// ListVmsResponse { repeated GetVmResponse vms = 1, string ssh_host_key = 2 }
    static func decodeList(_ data: Data) throws -> [Vm] {
        var r = ProtoReader(data)
        var vms: [Vm] = []
        while let f = try r.nextField() {
            if f.field == 1 {
                vms.append(try Vm(proto: Data(try r.readLengthDelimited())))
            } else {
                try r.skip(f.wire)
            }
        }
        return vms
    }
}

// MARK: - VM actions

enum VmAction: CaseIterable, Hashable {
    case start, stop, reboot, pause, resume, hibernate, wake, destroy

    var label: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .reboot: return "Reboot"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .hibernate: return "Hibernate"
        case .wake: return "Wake"
        case .destroy: return "Destroy"
        }
    }

    var progressLabel: String {
        switch self {
        case .start: return "Starting"
        case .stop: return "Stopping"
        case .reboot: return "Rebooting"
        case .pause: return "Pausing"
        case .resume: return "Resuming"
        case .hibernate: return "Hibernating"
        case .wake: return "Waking"
        case .destroy: return "Destroying"
        }
    }

    var methodName: String {
        switch self {
        case .start: return "StartVm"
        case .stop: return "StopVm"
        case .reboot: return "RebootVm"
        case .pause: return "SuspendVm"
        case .resume: return "ResumeVm"
        case .hibernate: return "HibernateVm"
        case .wake: return "WakeVm"
        case .destroy: return "DestroyVm"
        }
    }

    var needsConfirm: Bool { self == .stop || self == .reboot || self == .destroy }
    var isDestructive: Bool { self == .destroy }

    static func actions(for status: VmStatus) -> [VmAction] {
        switch status {
        case .running: return [.stop, .reboot, .pause, .hibernate, .destroy]
        case .stopped: return [.start, .destroy]
        case .standby: return [.resume, .stop, .destroy]
        case .hibernated: return [.wake, .destroy]
        case .failed: return [.start, .destroy]
        case .transitional, .unknown: return []
        }
    }
}

// MARK: - Identity (Whoami)

struct Identity: Hashable {
    var userID = ""        // 1
    var displayName = ""   // 5
    var billing: Billing?  // 4

    var title: String { displayName.isEmpty ? userID : displayName }

    init(proto data: Data) throws {
        var r = ProtoReader(data)
        while let f = try r.nextField() {
            switch f.field {
            case 1: userID = try r.readString()
            case 4: billing = try Billing(proto: Data(try r.readLengthDelimited()))
            case 5: displayName = try r.readString()
            default: try r.skip(f.wire)
            }
        }
    }
}

struct Billing: Hashable {
    var subscriptionStatus = "" // 3
    var maxVMs: UInt32 = 0      // 7
    var balanceMicro: Int64 = 0 // 10
    var billingMode = ""        // 11: "stripe" | "credits"
    var currency = ""           // 12: "eur" | "usd"

    /// Shown in the menu header for credits billing.
    var balanceLabel: String? {
        guard billingMode == "credits" else { return nil }
        let symbol = currency == "eur" ? "€" : currency == "usd" ? "$" : "\(currency.uppercased()) "
        let sign = balanceMicro < 0 ? "-" : ""
        return sign + symbol + String(format: "%.2f", Double(balanceMicro.magnitude) / 1_000_000)
    }

    init(proto data: Data) throws {
        var r = ProtoReader(data)
        while let f = try r.nextField() {
            switch f.field {
            case 3: subscriptionStatus = try r.readString()
            case 7: maxVMs = UInt32(clamping: try r.readUInt64())
            case 10: balanceMicro = try r.readInt64()
            case 11: billingMode = try r.readString()
            case 12: currency = try r.readString()
            default: try r.skip(f.wire)
            }
        }
    }
}

// MARK: - Request builders

enum BoxdRequests {
    /// ListVmsRequest { string org = 1; bool all_contexts = 2 }
    static func listVms(org: String, allContexts: Bool) -> Data {
        var w = ProtoWriter()
        w.appendString(1, org)
        w.appendBool(2, allContexts)
        return w.data
    }

    /// All state verbs + GetVm share { string vm_id = 1 }.
    static func vmID(_ id: String) -> Data {
        var w = ProtoWriter()
        w.appendString(1, id)
        return w.data
    }
}
