import Foundation
import IOKit.pwr_mgt

/// 通过 IOKit 电源断言阻止系统 / 屏幕进入闲置休眠。
/// 断言由内核持有，进程退出时自动回收，因此不会出现 caffeinate 子进程残留导致 Mac 永不休眠的问题。
final class PowerAssertionManager {

    private var systemAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var displayAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var holdsSystem = false
    private var holdsDisplay = false

    private(set) var currentReason: String = ""

    /// 幂等地把断言状态调整到目标状态。
    /// 注意：断言名称必须是 ASCII，非 ASCII 会被系统丢弃成空字符串。
    func update(preventSystemSleep: Bool, preventDisplaySleep: Bool, reason: String) {
        let name = reason.isEmpty ? "MacAwake" : reason

        if preventSystemSleep != holdsSystem {
            if preventSystemSleep {
                holdsSystem = create(kIOPMAssertionTypePreventUserIdleSystemSleep,
                                     name: name, into: &systemAssertion)
            } else {
                IOPMAssertionRelease(systemAssertion)
                systemAssertion = IOPMAssertionID(0)
                holdsSystem = false
            }
        } else if holdsSystem, name != currentReason {
            rename(systemAssertion, to: name)
        }

        if preventDisplaySleep != holdsDisplay {
            if preventDisplaySleep {
                holdsDisplay = create(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                      name: name, into: &displayAssertion)
            } else {
                IOPMAssertionRelease(displayAssertion)
                displayAssertion = IOPMAssertionID(0)
                holdsDisplay = false
            }
        } else if holdsDisplay, name != currentReason {
            rename(displayAssertion, to: name)
        }

        currentReason = name
    }

    func releaseAll() {
        update(preventSystemSleep: false, preventDisplaySleep: false, reason: "")
    }

    private func create(_ type: String, name: String, into id: inout IOPMAssertionID) -> Bool {
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else { return false }
        id = newID
        return true
    }

    private func rename(_ id: IOPMAssertionID, to name: String) {
        IOPMAssertionSetProperty(id, kIOPMAssertionNameKey as CFString, name as CFString)
    }

    deinit { releaseAll() }

    /// 立即让 Mac 进入睡眠。pmset sleepnow 不需要管理员权限。
    static func sleepNow() {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        do {
            try pmset.run()
        } catch {
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", "tell application \"System Events\" to sleep"]
            try? osa.run()
        }
    }
}
