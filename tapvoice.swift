#!/usr/bin/env swift
// tapvoice — macOS daemon: four-finger tap -> key event.
// Reads raw trackpad frames via the private MultitouchSupport framework
// (no permission needed for capture), detects a four-finger tap, then posts
// a key at the HID level via CGEvent (requires Accessibility permission).
//
// Gestures:
//   four-finger tap          -> left-Cmd (toggle: e.g. Doubao voice input)
//   four-finger double-tap   -> Return
// Single taps are delayed 280ms to wait for a possible second tap; a
// double-tap only sends Return and never touches the voice state.
//
// Env: TAP_FINGERS (default 4), TAP_DEBUG=1 logs every contact frame.
import Foundation
import CoreGraphics
import ApplicationServices

let MT_PATH = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport"
let wantedFingers = Int(ProcessInfo.processInfo.environment["TAP_FINGERS"] ?? "4") ?? 4
let debugMode = ProcessInfo.processInfo.environment["TAP_DEBUG"] == "1"
let logFH = FileHandle.standardOutput
func log(_ s: String) { logFH.write((s + "\n").data(using: .utf8)!) }

typealias MTDevice = UnsafeMutableRawPointer
typealias MTContactFrameCallback = @convention(c) (MTDevice?, UnsafeRawPointer?, Int, Double, UInt32) -> Void

var tapStart: Date?
var lastFire = Date.distantPast
var lastTapDate = Date.distantPast
var pendingGeneration = 0
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

func postLeftCommand() {
    // NX_DEVICELCMDKEYMASK = 0x8: mark as *left* Command
    postKey(55, [.maskCommand, CGEventFlags(rawValue: 0x8)])
}

// 单击延迟由回调内联处理(回调已持锁, 不得再取同一把锁)

let callback: MTContactFrameCallback = { device, touches, count, timestamp, frame in
    stateLock.lock()
    defer { stateLock.unlock() }
    let now = Date()
    let idx = device.flatMap { deviceIndex[$0] } ?? -1
    if debugMode && count > 0 {
        log(String(format: "frame: dev=%d count=%d t=%.3f", idx, count, timestamp))
    }
    if count >= wantedFingers + 1 {
        // 5+ fingers: palm / five-finger gesture -> cancel
        tapStart = nil
    } else if count >= wantedFingers {
        if tapStart == nil { tapStart = now }
    } else if count > 0 {
        // 1..(wanted-1) fingers: touchdown/liftoff transition frames -> keep candidate
    } else {
        // count == 0: all fingers up, decide now
        if let t0 = tapStart {
            let dt = now.timeIntervalSince(t0)
            tapStart = nil
            // tap window 30~500ms (covers staggered touchdown); 250ms anti-chatter
            if dt > 0.03 && dt < 0.5 && now.timeIntervalSince(lastFire) > 0.25 {
                lastFire = now
                if now.timeIntervalSince(lastTapDate) < 0.45 {
                    // double-tap: Return only; cancel the pending single tap
                    lastTapDate = .distantPast
                    pendingGeneration += 1
                    log(String(format: "double-tap (%.0fms) -> post return", dt * 1000))
                    postKey(36, [])
                } else {
                    // single tap: fire after 280ms unless a second tap arrives
                    lastTapDate = now
                    pendingGeneration += 1
                    let gen = pendingGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        stateLock.lock()
                        let stillPending = (gen == pendingGeneration)
                        stateLock.unlock()
                        if stillPending {
                            log("single-tap (delayed) -> post left-cmd")
                            postLeftCommand()
                        }
                    }
                }
            }
        }
    }
}

guard let mt = dlopen(MT_PATH, RTLD_NOW) else {
    log("FATAL: cannot load MultitouchSupport.framework")
    exit(1)
}
typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias RegCbFn = @convention(c) (MTDevice, MTContactFrameCallback) -> Void
typealias StartFn = @convention(c) (MTDevice, Int32) -> Int32
typealias TypeIDFn = @convention(c) (MTDevice) -> Int32

guard let createListSym = dlsym(mt, "MTDeviceCreateList"),
      let regCbSym = dlsym(mt, "MTRegisterContactFrameCallback"),
      let startSym = dlsym(mt, "MTDeviceStart") else {
    log("FATAL: missing MT symbols")
    exit(1)
}
let createList = unsafeBitCast(createListSym, to: CreateListFn.self)
let regCb = unsafeBitCast(regCbSym, to: RegCbFn.self)
let startDev = unsafeBitCast(startSym, to: StartFn.self)
let typeIDFn = dlsym(mt, "MTDeviceGetDeviceTypeID").map { unsafeBitCast($0, to: TypeIDFn.self) }

guard let devicesRef = createList()?.takeUnretainedValue() else {
    log("FATAL: no multitouch devices")
    exit(1)
}
let devices = (devicesRef as! [AnyObject]).map { Unmanaged<AnyObject>.passUnretained($0).toOpaque() }
for (i, dev) in devices.enumerated() {
    deviceIndex[dev] = i
    regCb(dev, callback)
    let rc = startDev(dev, 0)
    let tid = typeIDFn?(dev) ?? -1
    log(String(format: "device %d started rc=%d typeID=%d", i, rc, tid))
}
log("tapvoice listening on \(devices.count) device(s), want \(wantedFingers) fingers")

// 启动自检: 合成按键需要辅助功能权限; 没有则弹系统授权框
let trustedOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(trustedOpts)
log("accessibility trusted: \(trusted)")

dispatchMain()
