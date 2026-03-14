import Foundation
import IOKit
import IOKit.hid
import Carbon.HIToolbox

// MARK: - Constants

let APPLE_VENDOR_ID = 0x05AC
let CONFIG_DIR      = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".config/keyboard-switch")

// MARK: - Logging

func log(_ msg: String) { NSLog("keyboard-switch: %@", msg) }

// MARK: - Config

struct Config: Codable {
    var macLayout: String?
    var pcLayout: String?
}

func loadConfig() -> Config {
    let url = CONFIG_DIR.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    return config
}

// MARK: - Layout Detection

/// Prints all enabled Apple keyboard layout IDs to stdout and exits.
func listLayouts() {
    guard let listRef = TISCreateInputSourceList(nil, false) else {
        print("Failed to read input sources.")
        exit(1)
    }
    let sources = listRef.takeRetainedValue() as! [TISInputSource]
    var found = false
    for source in sources {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        guard id.hasPrefix("com.apple.keylayout.") else { continue }
        print(id)
        found = true
    }
    if !found { print("No keyboard layouts found.") }
    exit(0)
}

/// Returns the (mac, pc) layout pair.
/// Priority: config file → auto-detection from enabled sources.
func resolveLayouts(config: Config) -> (mac: String, pc: String)? {
    // If both are explicitly configured, use them directly.
    if let mac = config.macLayout, let pc = config.pcLayout {
        log("Using layouts from config: Mac=\(mac) PC=\(pc)")
        return (mac: mac, pc: pc)
    }

    // Auto-detect: find the -PC layout and its base equivalent.
    guard let listRef = TISCreateInputSourceList(nil, false) else { return nil }
    let sources = listRef.takeRetainedValue() as! [TISInputSource]

    var layoutIDs: [String] = []
    for source in sources {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        guard id.hasPrefix("com.apple.keylayout.") else { continue }
        layoutIDs.append(id)
    }

    guard let pcID = layoutIDs.first(where: { $0.hasSuffix("-PC") }) else {
        log("Auto-detect failed: no -PC layout enabled. Enable one in System Settings > Keyboard > Input Sources, or set layouts explicitly in ~/.config/keyboard-switch/config.json.")
        return nil
    }

    let baseID = pcID.replacingOccurrences(of: "-PC", with: "")
    let macID  = layoutIDs.first(where: { $0 == baseID })
              ?? layoutIDs.first(where: { !$0.hasSuffix("-PC") })

    guard let macID else {
        log("Auto-detect failed: found '\(pcID)' but no matching Mac layout.")
        return nil
    }

    return (mac: macID, pc: pcID)
}

// MARK: - Persistence

struct DeviceKeyJSON: Codable {
    let vendorID: Int
    let productID: Int
}

// MARK: - Switcher

final class KeyboardSwitcher {

    private struct DeviceKey: Hashable {
        let vendorID: Int
        let productID: Int
    }

    private let manager: IOHIDManager
    private let macLayout: String
    private let pcLayout: String

    // Registry IDs of all connected non-Apple USB keyboard HID services.
    private var connectedKeyboards: [UInt64: DeviceKey] = [:]

    // Vendor+product pairs confirmed as real keyboards via actual keystrokes.
    // Persisted across sessions — once learned, instantly recognised on reconnect.
    private var knownKeyboards: Set<DeviceKey> = []

    private let knownKeyboardsURL: URL
    private var initialEnumerationDone = false

    init(macLayout: String, pcLayout: String) {
        self.macLayout = macLayout
        self.pcLayout  = pcLayout
        self.manager   = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.knownKeyboardsURL = CONFIG_DIR.appendingPathComponent("known-keyboards.json")
        loadKnownKeyboards()
    }

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDPrimaryUsagePageKey: 1,
            kIOHIDPrimaryUsageKey:    6,
        ] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().deviceConnected(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, result, _, device in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().deviceDisconnected(device)
        }, ctx)

        // Input value callback — the only reliable way to identify real keyboards.
        // When a keypress arrives from a device we haven't seen before, we learn
        // its vendor+product as a real keyboard and persist that to disk.
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, result, _, value in
            guard result == kIOReturnSuccess, let ctx else { return }
            Unmanaged<KeyboardSwitcher>.fromOpaque(ctx).takeUnretainedValue().inputReceived(value)
        }, ctx)

        // Only fire input callbacks for Keyboard/Keypad page (7) — actual key presses.
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: 7] as CFDictionary)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let err = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if err != kIOReturnSuccess {
            log("Failed to open HID manager (err: \(err)). Grant Input Monitoring in System Settings > Privacy & Security > Input Monitoring.")
        }

        log("Started. Mac=\(macLayout) PC=\(pcLayout) | Known keyboards: \(knownKeyboards.count)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.initialEnumerationDone = true
            log("Initial state: \(self.realKeyboardCount()) real keyboard(s) connected")
            self.updateLayout()
        }
    }

    // MARK: - Device Events

    private func deviceConnected(_ device: IOHIDDevice) {
        guard isNonAppleUSBDevice(device) else { return }

        let id   = registryID(device)
        let key  = deviceKey(device)
        let name = strVal(device, kIOHIDProductKey)

        connectedKeyboards[id] = key
        log("Connected: '\(name)' vendor=0x\(String(key.vendorID, radix: 16)) id=\(id) | known=\(knownKeyboards.contains(key))")

        if initialEnumerationDone { updateLayout() }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard isNonAppleUSBDevice(device) else { return }

        let id   = registryID(device)
        let name = strVal(device, kIOHIDProductKey)

        guard connectedKeyboards.removeValue(forKey: id) != nil else { return }
        log("Disconnected: '\(name)' id=\(id) | real keyboards=\(realKeyboardCount())")
        updateLayout()
    }

    // MARK: - Input Events

    private func inputReceived(_ value: IOHIDValue) {
        let elem  = IOHIDValueGetElement(value)
        let usage = IOHIDElementGetUsage(elem)

        // Usages 0–3 are reserved / error-rollover — not real keys.
        guard usage > 3 else { return }

        let device = IOHIDElementGetDevice(elem)
        guard isNonAppleUSBDevice(device) else { return }

        let key  = deviceKey(device)
        let name = strVal(device, kIOHIDProductKey)

        guard knownKeyboards.insert(key).inserted else { return }

        log("Learned real keyboard: '\(name)' vendor=0x\(String(key.vendorID, radix: 16)) product=0x\(String(key.productID, radix: 16))")
        saveKnownKeyboards()
        updateLayout()
    }

    // MARK: - Layout

    private func realKeyboardCount() -> Int {
        connectedKeyboards.values.filter { knownKeyboards.contains($0) }.count
    }

    private func updateLayout() {
        switchTo(realKeyboardCount() > 0 ? pcLayout : macLayout)
    }

    private func switchTo(_ layoutID: String) {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return }
        let sources = listRef.takeRetainedValue() as! [TISInputSource]

        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            guard id == layoutID else { continue }

            let err = TISSelectInputSource(source)
            log(err == noErr ? "Switched to \(layoutID)" : "Failed to switch to \(layoutID): err=\(err)")
            return
        }
        log("Layout not found: \(layoutID) — is it enabled in System Settings > Keyboard > Input Sources?")
    }

    // MARK: - Helpers

    private func isNonAppleUSBDevice(_ device: IOHIDDevice) -> Bool {
        strVal(device, kIOHIDTransportKey) == "USB"
            && intVal(device, kIOHIDVendorIDKey) != APPLE_VENDOR_ID
    }

    private func deviceKey(_ device: IOHIDDevice) -> DeviceKey {
        DeviceKey(vendorID: intVal(device, kIOHIDVendorIDKey), productID: intVal(device, kIOHIDProductIDKey))
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != IO_OBJECT_NULL { IORegistryEntryGetRegistryEntryID(service, &id) }
        return id
    }

    private func intVal(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }

    private func strVal(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }

    // MARK: - Persistence

    private func loadKnownKeyboards() {
        guard let data = try? Data(contentsOf: knownKeyboardsURL),
              let entries = try? JSONDecoder().decode([DeviceKeyJSON].self, from: data) else { return }
        knownKeyboards = Set(entries.map { DeviceKey(vendorID: $0.vendorID, productID: $0.productID) })
        log("Loaded \(knownKeyboards.count) known keyboard(s) from disk")
    }

    private func saveKnownKeyboards() {
        let entries = knownKeyboards.map { DeviceKeyJSON(vendorID: $0.vendorID, productID: $0.productID) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
        try? data.write(to: knownKeyboardsURL)
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments.dropFirst()

if args.contains("--list-layouts") {
    listLayouts()  // prints and exits
}

if args.contains("--help") {
    print("""
    keyboard-switch — auto-switch macOS input layout on USB keyboard connect/disconnect

    Usage:
      keyboard-switch               Run the daemon
      keyboard-switch --list-layouts  Print enabled keyboard layout IDs and exit
      keyboard-switch --help          Show this help

    Config: ~/.config/keyboard-switch/config.json
      {
        "macLayout": "com.apple.keylayout.British",
        "pcLayout":  "com.apple.keylayout.British-PC"
      }
    Both fields are optional. If omitted, layouts are auto-detected from enabled input sources.
    """)
    exit(0)
}

let config = loadConfig()

guard let layouts = resolveLayouts(config: config) else {
    log("Exiting: could not determine keyboard layouts.")
    exit(1)
}

let switcher = KeyboardSwitcher(macLayout: layouts.mac, pcLayout: layouts.pc)
switcher.start()
RunLoop.main.run()
