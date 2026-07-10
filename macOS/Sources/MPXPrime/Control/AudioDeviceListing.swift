import Foundation

#if os(macOS)
import MPXPrimeCore
#else
import CAlsa
#endif

// Cross-platform enumeration of selectable audio devices for the control API
// (GET /api/devices). macOS uses the same CoreAudio list the GUI's device
// pickers show; Linux enumerates ALSA PCMs via snd_device_name_hint, the
// counterpart of `aplay -L` / `arecord -L`.
enum AudioDeviceListing {
    static func enumerate() -> (inputs: [ControlDevice], outputs: [ControlDevice], note: String) {
        #if os(macOS)
        guard let devices = try? AudioDevices.list() else { return ([], [], "") }
        let inputs = devices.filter { $0.hasInput }.map {
            ControlDevice(id: $0.uid, name: $0.name, canInput: true, canOutput: $0.hasOutput)
        }
        let outputs = devices.filter { $0.hasOutput }.map {
            ControlDevice(id: $0.uid, name: $0.name, canInput: $0.hasInput, canOutput: true)
        }
        return (inputs, outputs, "")
        #else
        return enumerateALSA()
        #endif
    }

    #if os(Linux)
    private static func enumerateALSA() -> ([ControlDevice], [ControlDevice], String) {
        var inputs: [ControlDevice] = [
            ControlDevice(id: "default", name: "default (ALSA default PCM)",
                          canInput: true, canOutput: false)
        ]
        var outputs: [ControlDevice] = [
            ControlDevice(id: "default", name: "default (ALSA default PCM)",
                          canInput: false, canOutput: true)
        ]

        var hintsPtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        guard snd_device_name_hint(-1, "pcm", &hintsPtr) == 0, let hints = hintsPtr else {
            return (inputs, outputs,
                    "ALSA PCM names (hw:0,0 / plughw:...). Enumeration unavailable; type a name.")
        }
        defer { snd_device_name_free_hint(hints) }

        func hintValue(_ hint: UnsafeMutableRawPointer, _ id: String) -> String? {
            guard let c = snd_device_name_get_hint(hint, id) else { return nil }
            defer { free(c) }
            let value = String(cString: c)
            return value == "null" ? nil : value
        }

        var idx = 0
        while let hint = hints[idx] {
            idx += 1
            guard let name = hintValue(hint, "NAME") else { continue }
            // First line of DESC is the human label; the rest is verbose.
            let desc = hintValue(hint, "DESC")?
                .split(separator: "\n").first.map(String.init) ?? name
            let ioid = hintValue(hint, "IOID")   // "Input" | "Output" | nil (both)
            let device = { (input: Bool, output: Bool) in
                ControlDevice(id: name, name: desc, canInput: input, canOutput: output)
            }
            if ioid == nil || ioid == "Input", !inputs.contains(where: { $0.id == name }) {
                inputs.append(device(true, ioid == nil))
            }
            if ioid == nil || ioid == "Output", !outputs.contains(where: { $0.id == name }) {
                outputs.append(device(ioid == nil, true))
            }
        }
        return (inputs, outputs,
                "Linux devices are ALSA PCM names. A hw: device must support the "
                    + "configured sample rate natively; plughw:/default let ALSA convert.")
    }
    #endif
}
