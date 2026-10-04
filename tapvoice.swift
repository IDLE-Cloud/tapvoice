#!/usr/bin/env swift
// tapvoice — macOS 触控板手势 → 按键事件 的开源守护进程（Swift，无依赖）
//
// 手势（默认）：
//   N指轻点                → 自定义键（默认 4 指 → 左⌘，立即触发）
//   M指双击(<450ms)        → 自定义键（默认 3 指 → 回车；M≠N 避免误触）
//   五指轻点               → 删除键（默认退格 51；位移门控区分轻点与轻扫）
//   五指按住不动 ≥0.6s     → 连续删除（每 0.1s 一次，移动/抬起即停）
//
// 实现：MultitouchSupport 私有框架读原始触点帧（无需权限）→ 指数量+时间窗判定
//       → CGEvent 系统级发键（此步需辅助功能权限）
//
// 判定要点：
//   - 触点帧在落指/抬指时必然波动(如 4→3→2→4→3→1)，过渡帧不取消候选，count==0 才判决
//   - M指双击的接触需持续 ≥60ms 且总时长 <300ms（区分为拖移类长接触与过渡噪声）
//
// 配置（环境变量）：
//   TAP_FINGERS       单击触发指数量，默认 4
//   TAP_KEYCODE       单击键码，默认 55（左⌘）
//   TAP_FLAGS         单击修饰标志(hex)，默认 0x100008（⌘ + 左键设备标记）
//   DOUBLE_FINGERS    双击触发指数量，默认 3
//   DOUBLE_KEYCODE    双击键码，默认 36（回车）
//   TAP_DEBUG=1       记录所有触点帧
import Foundation
import CoreGraphics
import ApplicationServices

let env = ProcessInfo.processInfo.environment
// Swift 的 UInt64(String) 只按十进制解析，不认 0x 前缀——必须显式剥前缀按 16 进制解析
func parseU64(_ s: String?, _ def: UInt64) -> UInt64 {
    guard let s = s, !s.isEmpty else { return def }
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        return UInt64(String(s.dropFirst(2)), radix: 16) ?? def
    }
    return UInt64(s) ?? def
}
let wantedFingers = Int(env["TAP_FINGERS"] ?? "4") ?? 4
let tapKeycode = UInt16(env["TAP_KEYCODE"] ?? "55") ?? 55
let tapFlags = CGEventFlags(rawValue: parseU64(env["TAP_FLAGS"], 0x100008))
let doubleFingers = Int(env["DOUBLE_FINGERS"] ?? "3") ?? 3
let doubleKeycode = UInt16(env["DOUBLE_KEYCODE"] ?? "36") ?? 36
let deleteKeycode = UInt16(env["DELETE_KEYCODE"] ?? "51") ?? 51   // 五指轻点 → 删除（51=退格, 117=向前删除）
let debugMode = env["TAP_DEBUG"] == "1"
let logFH = FileHandle.standardOutput
func log(_ s: String) { logFH.write((s + "\n").data(using: .utf8)!) }

typealias MTDevice = UnsafeMutableRawPointer
typealias MTContactFrameCallback = @convention(c) (MTDevice?, UnsafeRawPointer?, Int, Double, UInt32) -> Void

// MTTouch 原始布局（未公开，社区逆向版本；运行时用值域校验，异常则退化为纯计数模式）
struct MTTouch {
    var frame: Int32
    var _pad0: UInt32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var x: Float
    var y: Float
    var total: Float
    var pressure: Float
}

// 单击候选（wantedFingers 指）
var tapStart: Date?
var lastFire = Date.distantPast
// 双击候选（doubleFingers 指，需持续接触，两次 <450ms）
var bClusterStart: Date?
var bRunStart: Date?
var bLastThree: Date?
var lastCount = -1
var lastBTap = Date.distantPast
// 五指删除族状态
var d5Start: Date?
var dDippedBelow5 = false        // 五指段中曾跌破 5
var dGlitch = false              // 跌破 5 后又回到 5 → 轻扫抖动，作废本簇
var d5StartPos: (x: Float, y: Float)?
var d5EndPos: (x: Float, y: Float)?
var lastDeleteFire = Date.distantPast
// 位置自校准状态（MTTouch 布局随系统版本变化，运行时探测 x/y 浮点字段偏移）
var calibXOff = -1
var calibYOff = -1
var calibLo = [Float](repeating: 1e9, count: 16)
var calibHi = [Float](repeating: -1e9, count: 16)
var calibN = 0
var calibDone = false
let stateLock = NSLock()
var deviceIndex: [UnsafeMutableRawPointer: Int] = [:]

func postKey(_ keycode: UInt16, _ flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(20000)
    let up = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

// 多修饰键组合（如 ⌃+⌘）按真实双键时序投递：先压修饰键1，再压修饰键2，依次抬起
func postChord() {
    let src = CGEventSource(stateID: .hidSystemState)
    let mods: [(UInt16, CGEventFlags)] = [
        (59, [.maskControl, CGEventFlags(rawValue: 0x1)]),              // 左⌃ 按下
        (55, [.maskControl, .maskCommand, CGEventFlags(rawValue: 0x9)]) // 左⌘ 按下（带⌃）
    ]
    for (code, flags) in mods {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(15000)
    }
    for (code, flags) in mods.reversed() {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(15000)
    }
}

// —— 运行时位置自校准 ——
// MTTouch 结构偏移随 macOS 版本变化（社区旧资料曾读出垃圾值），故开机后头 20 个
// 有触点的帧里，扫描触点结构体 24..60 字节内所有 Float 偏移，把值域落在 [0,1] 附近
// 且随手指明显变化的两个偏移认定为 x/y。只读触点[0]，避免结构体跨触点步长不确定。
func calibScan(_ touches: UnsafeRawPointer?, _ count: Int) {
    guard !calibDone, count >= 1, let t0 = touches else { return }
    calibN += 1
    let base = t0
    for off in stride(from: 24, through: 60, by: 4) {
        let v = base.load(fromByteOffset: off, as: Float.self)
        let k = (off - 24) / 4
        if v.isFinite {
            calibLo[k] = min(calibLo[k], v)
            calibHi[k] = max(calibHi[k], v)
        }
    }
    if calibN >= 200 {
        var best: [(off: Int, span: Float)] = []
        for off in stride(from: 24, through: 60, by: 4) {
            let k = (off - 24) / 4
            if calibLo[k] >= -0.05 && calibHi[k] <= 1.05 && (calibHi[k] - calibLo[k]) > 0.02 {
                best.append((off, calibHi[k] - calibLo[k]))
            }
        }
        if best.count >= 2 {
            best.sort { $0.span > $1.span }
            calibXOff = best[0].off
            calibYOff = best[1].off
        }
        calibDone = true
        log(String(format: "calib done: x@%d y@%d (candidates=%d)", calibXOff, calibYOff, best.count))
    }
}

func touchPos(_ touches: UnsafeRawPointer?) -> (x: Float, y: Float)? {
    guard calibXOff >= 0, let t = touches else { return nil }
    let x = t.load(fromByteOffset: calibXOff, as: Float.self)
    let y = t.load(fromByteOffset: calibYOff, as: Float.self)
    guard x.isFinite, y.isFinite else { return nil }
    return (x, y)
}

// 发键统一走独立串行队列，避免阻塞 MT 回调线程（检测永不掉帧）
let postQueue = DispatchQueue(label: "tapvoice.post")

func postTapKey() {
    if tapFlags.contains(.maskControl) && tapFlags.contains(.maskCommand) {
        postChord()
    } else {
        postKey(tapKeycode, tapFlags)
    }
}

let callback: MTContactFrameCallback = { device, touches, count, timestamp, frame in
    stateLock.lock()
    defer { stateLock.unlock() }
    let now = Date()
    let idx = device.flatMap { deviceIndex[$0] } ?? -1
    if debugMode && count > 0 {
        log(String(format: "frame: dev=%d count=%d t=%.3f", idx, count, timestamp))
    }
    calibScan(touches, count)   // 前 200 帧内持续采样自校准 x/y 偏移
    // —— 双击族（doubleFingers）：count==0 时结算 ——
    // 设计：4 指短暂尖峰(手掌误触,15~30ms)不作废本簇；真四指点按的 3 指过渡帧
    // 持续 <60ms，天然不满足 sustained 条件而分流到单击族。
    if count == doubleFingers {
        if bClusterStart == nil {
            bClusterStart = now
        }
        if bRunStart == nil || lastCount != doubleFingers {
            bRunStart = now   // 连续 3 指段的起始（被 4 打断后重新起算）
        }
        bLastThree = now
    }

    if count == 0 {
        var bHandled = false
        if let c0 = bClusterStart, let rs = bRunStart, let l3 = bLastThree {
            let total = now.timeIntervalSince(c0)
            let sustained = l3.timeIntervalSince(rs)
            // 连续 3 指段 ≥40ms(四指过渡帧的单/双帧段只有 15~30ms,天然分流) 且总时长 <500ms(排除拖移)
            if total < 0.5 && sustained >= 0.04 {
                bHandled = true
                if now.timeIntervalSince(lastBTap) < 0.45 {
                    lastBTap = .distantPast
                    log(String(format: "%d-finger double-tap (%.0fms) -> post key %d", doubleFingers, total * 1000, doubleKeycode))
                    postQueue.async { postKey(doubleKeycode, []) }
                } else {
                    lastBTap = now
                }
            }
        }
        bClusterStart = nil; bRunStart = nil; bLastThree = nil

        // —— 五指删除族：count==0 结算，位移门控区分轻点(不动)与轻扫(移动) ——
        var dHandled = false
        if let ds = d5Start, let t0 = tapStart, !dGlitch {
            let held = now.timeIntervalSince(ds)
            let total = now.timeIntervalSince(t0)
            var moved: Float = -1.0
            if let p0 = d5StartPos, let p1 = d5EndPos {
                let dx = p1.x - p0.x, dy = p1.y - p0.y
                moved = (dx * dx + dy * dy).squareRoot()
            }
            // 校准成功用位移门控(<0.03)；校准失败退化为极短接触窗口(<0.35s)
            let tapped = moved >= 0 ? moved < 0.03 : total < 0.35
            let inWindow = held >= 0.04 && total > 0.03 && total < 0.6
            if inWindow && tapped && now.timeIntervalSince(lastDeleteFire) > 0.3 {
                dHandled = true
                lastDeleteFire = now
                log(String(format: "5-finger tap (%.0fms moved=%.3f) -> post key %d", total * 1000, max(moved, 0), deleteKeycode))
                postQueue.async { postKey(deleteKeycode, []) }
            } else if inWindow && !tapped {
                log(String(format: "5-finger swipe rejected (%.0fms moved=%.3f)", total * 1000, moved))
            }
        }
        d5Start = nil; dDippedBelow5 = false; dGlitch = false; d5StartPos = nil; d5EndPos = nil

        // —— 单击族（wantedFingers 指）：双击族/删除族未处理时才结算 ——
        if !bHandled && !dHandled, let t0 = tapStart {
            let dt = now.timeIntervalSince(t0)
            if dt > 0.03 && dt < 0.4 && now.timeIntervalSince(lastFire) > 0.25 {
                lastFire = now
                log(String(format: "%d-finger tap (%.0fms) -> post key %d", wantedFingers, dt * 1000, tapKeycode))
                postQueue.async { postTapKey() }
            }
        }
        tapStart = nil
    } else if count >= 5 {
        if tapStart == nil { tapStart = now }
        if d5Start == nil {
            d5Start = now
            dDippedBelow5 = false
            dGlitch = false
            d5StartPos = touchPos(touches)
            d5EndPos = nil
        } else if dDippedBelow5 {
            dGlitch = true   // 跌破 5 又回到 5 → 轻扫中途抖动，作废
        }
        if let p = touchPos(touches) { d5EndPos = p }   // 持续取末帧位置
        // 长按连删：按住不动 ≥0.6s 后每 0.1s 发一次；移动即停（与轻扫区分）
        if let ds = d5Start, !dGlitch, now.timeIntervalSince(ds) > 0.6,
           now.timeIntervalSince(lastDeleteFire) >= 0.1,
           let p0 = d5StartPos, let p1 = d5EndPos {
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            if (dx * dx + dy * dy).squareRoot() < 0.03 {
                lastDeleteFire = now
                log(String(format: "5-finger hold repeat -> key %d", deleteKeycode))
                postQueue.async { postKey(deleteKeycode, []) }
            }
        }
    } else if count >= wantedFingers {
        if tapStart == nil { tapStart = now }
        if d5Start != nil { dDippedBelow5 = true }
    } else if count > 0 && d5Start != nil {
        dDippedBelow5 = true
    }
    // 其余过渡帧：不处理（保留各自候选）
    lastCount = count
}

guard let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport", RTLD_NOW) else {
    log("FATAL: cannot load MultitouchSupport.framework")
    exit(1)
}
typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias RegCbFn = @convention(c) (MTDevice, MTContactFrameCallback) -> Void
typealias StartFn = @convention(c) (MTDevice, Int32) -> Int32

guard let createListSym = dlsym(mt, "MTDeviceCreateList"),
      let regCbSym = dlsym(mt, "MTRegisterContactFrameCallback"),
      let startSym = dlsym(mt, "MTDeviceStart") else {
    log("FATAL: missing MT symbols")
    exit(1)
}
let createList = unsafeBitCast(createListSym, to: CreateListFn.self)
let regCb = unsafeBitCast(regCbSym, to: RegCbFn.self)
let startDev = unsafeBitCast(startSym, to: StartFn.self)

guard let devicesRef = createList()?.takeUnretainedValue() else {
    log("FATAL: no multitouch devices")
    exit(1)
}
let devices = (devicesRef as! [AnyObject]).map { Unmanaged<AnyObject>.passUnretained($0).toOpaque() }
for (i, dev) in devices.enumerated() {
    deviceIndex[dev] = i
    regCb(dev, callback)
    let rc = startDev(dev, 0)
    log(String(format: "device %d started rc=%d", i, rc))
}
log("tapvoice listening: tap=\(wantedFingers)fingers key=\(tapKeycode), double=\(doubleFingers)fingers key=\(doubleKeycode), 5-finger delete key=\(deleteKeycode)")
log(String(format: "tapFlags=0x%lx", tapFlags.rawValue))

// 启动自检: 合成按键需要辅助功能权限; 没有则弹系统授权框
let trustedOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
log("accessibility trusted: \(AXIsProcessTrustedWithOptions(trustedOpts))")

dispatchMain()
