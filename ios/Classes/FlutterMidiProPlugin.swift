import Flutter
import CoreMIDI
import AVFAudio
import AVFoundation
import CoreAudio

public class FlutterMidiProPlugin: NSObject, FlutterPlugin {
  private static let defaultPlaybackStandardA4 = 440.0
  private static let minPlaybackStandard = 400.0
  private static let maxPlaybackStandard = 480.0
  private static let samplerMidiChannel: UInt8 = 0

  private struct InstrumentSelection: Equatable {
    let bank: Int
    let program: Int
  }

  var audioEngines: [Int: [AVAudioEngine]] = [:]
  var soundfontIndex = 1
  var soundfontSamplers: [Int: [AVAudioUnitSampler]] = [:]
  var soundfontURLs: [Int: URL] = [:]
  private var selectedInstruments: [Int: [Int: InstrumentSelection]] = [:]
  private var activeChannelKeys: Set<Int> = []
  var playbackStandardA4 = defaultPlaybackStandardA4

  // MIDI Player support (per sfId)
  var midiSequencers: [Int: AVAudioSequencer] = [:]
  var midiPlayerEngines: [Int: AVAudioEngine] = [:]
  var midiPlayerSamplers: [Int: AVAudioUnitSampler] = [:]

  private func channelKey(sfId: Int, channel: Int) -> Int {
    return sfId * 16 + channel
  }

  private func markChannelActive(sfId: Int, channel: Int) {
    activeChannelKeys.insert(channelKey(sfId: sfId, channel: channel))
  }

  private func clearActiveChannels(for sfId: Int) {
    activeChannelKeys = activeChannelKeys.filter { $0 / 16 != sfId }
  }

  private func ensureChannelEngineRunning(sfId: Int, channel: Int) {
    guard let engine = audioEngines[sfId]?[channel] else {
      return
    }
    markChannelActive(sfId: sfId, channel: channel)
    if engine.isRunning {
      return
    }
    do {
      try engine.start()
    } catch {
      print("Failed to start channel engine for sfId \(sfId), channel \(channel): \(error)")
    }
  }

  private func stopEngines(for sfId: Int) {
    clearActiveChannels(for: sfId)
    audioEngines[sfId]?.forEach { engine in
      if engine.isRunning {
        engine.stop()
      }
    }
  }

  private func globalTuningCents(for a4Hz: Double) -> Float {
    return Float(1200.0 * log2(a4Hz / Self.defaultPlaybackStandardA4))
  }

  private func applyPlaybackStandardToAllSamplers() {
    let cents = globalTuningCents(for: playbackStandardA4)
    for (_, samplers) in soundfontSamplers {
      for sampler in samplers {
        sampler.globalTuning = cents
      }
    }
  }

  private func isPercussionBank(_ bank: Int) -> Bool {
    return bank == 128
  }

  private func bankParameters(for bank: Int) -> (bankMSB: UInt8, bankLSB: UInt8) {
    let isPercussion = isPercussionBank(bank)
    let bankMSB: UInt8 = isPercussion ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
    let bankLSB: UInt8 = isPercussion ? 0 : UInt8(bank)
    return (bankMSB, bankLSB)
  }

  private func bankLoadAttempts(for bank: Int, program: Int) -> [(bankMSB: UInt8, bankLSB: UInt8)] {
    let bankParams = bankParameters(for: bank)
    if isPercussionBank(bank) {
      return [(bankParams.bankMSB, bankParams.bankLSB)]
    }
    if program >= 68 && program <= 73 {
      return [
        (0, UInt8(bank)),
        (bankParams.bankMSB, bankParams.bankLSB),
      ]
    }
    return [
      (bankParams.bankMSB, bankParams.bankLSB),
      (0, UInt8(bank)),
    ]
  }

  private func loadInstrument(
    sampler: AVAudioUnitSampler,
    url: URL,
    bank: Int,
    program: Int
  ) throws {
    var lastError: Error?
    for attempt in bankLoadAttempts(for: bank, program: program) {
      do {
        try sampler.loadSoundBankInstrument(
          at: url,
          program: UInt8(program),
          bankMSB: attempt.bankMSB,
          bankLSB: attempt.bankLSB
        )
        sampler.globalTuning = globalTuningCents(for: playbackStandardA4)
        return
      } catch {
        lastError = error
      }
    }
    throw lastError ?? NSError(
      domain: "flutter_midi_pro",
      code: -10851,
      userInfo: [NSLocalizedDescriptionKey: "Failed to load soundfont preset \(program)"]
    )
  }

  private func runOnMainThread(_ work: () throws -> Void) throws {
    if Thread.isMainThread {
      try work()
      return
    }
    var capturedError: Error?
    DispatchQueue.main.sync {
      do {
        try work()
      } catch {
        capturedError = error
      }
    }
    if let capturedError = capturedError {
      throw capturedError
    }
  }

  private func applyInstrumentSelection(
    sampler: AVAudioUnitSampler,
    url: URL,
    bank: Int,
    program: Int
  ) {
    let bankParams = bankParameters(for: bank)
    do {
      try runOnMainThread {
        try self.loadInstrument(sampler: sampler, url: url, bank: bank, program: program)
      }
      return
    } catch {
      NSLog("flutter_midi_pro: preset \(program) direct load failed, falling back to program change")
    }
    do {
      try runOnMainThread {
        try self.loadInstrument(sampler: sampler, url: url, bank: bank, program: 0)
      }
    } catch {
      NSLog("flutter_midi_pro: bank root fallback load failed for bank \(bank)")
    }
    sampler.sendProgramChange(
      UInt8(program),
      bankMSB: bankParams.bankMSB,
      bankLSB: bankParams.bankLSB,
      onChannel: Self.samplerMidiChannel
    )
  }

  private func startEngine(_ engine: AVAudioEngine) throws {
    if engine.isRunning {
      return
    }
    try engine.start()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_midi_pro", binaryMessenger: registrar.messenger())
    let instance = FlutterMidiProPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public override init() {
    super.init()
    setupAudioSession()
    setupAudioSessionNotifications()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func setupAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setPreferredSampleRate(44100)
      try session.setPreferredIOBufferDuration(0.01)
      try session.setActive(true)
    } catch {
      print("Failed to setup audio session: \(error)")
    }
  }

  private func setupAudioSessionNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioEngineConfigurationChange),
      name: .AVAudioEngineConfigurationChange,
      object: nil
    )
  }

  @objc private func handleAudioSessionInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }

    switch type {
    case .began:
      break
    case .ended:
      var shouldResume = true
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        shouldResume = options.contains(.shouldResume)
      }

      if shouldResume {
        setupAudioSession()
        restartAudioEngines()
      }
    @unknown default:
      break
    }
  }

  @objc private func handleAudioEngineConfigurationChange(notification: Notification) {
    restartAudioEngines()
  }

  private func restartAudioEngines() {
    for (sfId, engines) in audioEngines {
      for (channel, engine) in engines.enumerated() {
        let key = channelKey(sfId: sfId, channel: channel)
        guard activeChannelKeys.contains(key), !engine.isRunning else {
          continue
        }
        do {
          try engine.start()
        } catch {
          print("Failed to restart audio engine for sfId \(sfId), channel \(channel): \(error)")
        }
      }
    }
  }

  // ──────────────────────────────────────────────────────────
  // MARK: - MIDI file parsing for sampler pre-configuration
  // ──────────────────────────────────────────────────────────

  /// Parses MIDI data and pre-configures each channel's instrument on the
  /// sampler using `loadSoundBankInstrument` + `sendProgramChange` (same
  /// strategy as `selectInstrument` / `applyInstrumentSelection`).
  ///
  /// Also patches Bank Select MSB (CC 0) values in the MIDI data so that
  /// the `AVAudioSequencer` sends the correct values (121 for melodic, 120
  /// for percussion) instead of the raw MIDI halves — this prevents the
  /// sequencer from resetting the bank to 0 after we configure it.
  ///
  /// Returns the patched MIDI data for the sequencer.
  private func patchMidiForSampler(sampler: AVAudioUnitSampler, midiData: Data, sfUrl: URL) -> Data {
    let bytes = [UInt8](midiData)
    var patched = Data(midiData)

    var cc0 = [UInt8](repeating: 0, count: 16)
    var cc32 = [UInt8](repeating: 0, count: 16)
    var applied = Set<Int>()

    guard bytes.count >= 14 else { return midiData }
    guard String(bytes: Data(bytes[0..<4]), encoding: .ascii) == "MThd" else { return midiData }
    var pos = 14

    while pos + 8 <= bytes.count {
      let chunkLen = (UInt32(bytes[pos+4]) << 24) | (UInt32(bytes[pos+5]) << 16) |
                     (UInt32(bytes[pos+6]) << 8)  | UInt32(bytes[pos+7])
      pos += 8
      let trackEnd = pos + Int(chunkLen)
      guard trackEnd <= bytes.count else { break }

      var runningStatus: UInt8 = 0
      while pos < trackEnd {
        // Delta time (variable length)
        while true {
          guard pos < trackEnd else { break }
          let b = bytes[pos]; pos += 1
          if b & 0x80 == 0 { break }
        }
        guard pos < trackEnd else { break }

        var status = bytes[pos]
        if status & 0x80 == 0 {
          status = runningStatus
        } else {
          pos += 1
          runningStatus = status
        }

        let ch = Int(status & 0x0F)

        switch status & 0xF0 {
        case 0xB0:
          guard pos + 1 < trackEnd else { break }
          let ctrl = bytes[pos]
          let val = bytes[pos + 1]
          pos += 2
          if ctrl == 0 {
            cc0[ch] = val
            // Patch CC 0 value in the MIDI data copy
            let rawBank = Int(val) * 128 + Int(cc32[ch])
            let isPerc = rawBank >= 128 || val >= 120
            let corrected: UInt8 = isPerc
                ? UInt8(kAUSampler_DefaultPercussionBankMSB)
                : UInt8(kAUSampler_DefaultMelodicBankMSB)
            if val != corrected { patched[pos - 1] = corrected }
          } else if ctrl == 32 {
            cc32[ch] = val
          }

        case 0xC0:
          guard pos < trackEnd else { break }
          let program = bytes[pos]
          pos += 1

          let rawBank = Int(cc0[ch]) * 128 + Int(cc32[ch])
          let isPerc = rawBank >= 128 || cc0[ch] >= 120
          let msb: UInt8 = isPerc
              ? UInt8(kAUSampler_DefaultPercussionBankMSB)
              : UInt8(kAUSampler_DefaultMelodicBankMSB)
          let lsb: UInt8 = isPerc ? 0 : cc32[ch]

          // Call loadSoundBankInstrument once for the very first Program
          // Change encountered, to ensure the sampler's default preset is
          // correct (not piano).  Subsequent channels use sendProgramChange
          // on their respective MIDI channel without reloading the soundfont,
          // which avoids resetting the shared sampler's state.
          if !applied.contains(ch) && applied.isEmpty {
            // First-ever PC → load the preset so the sampler has it ready
            let bankForLoad = isPerc ? 128 : Int(cc32[ch])
            for attempt in self.bankLoadAttempts(for: bankForLoad, program: Int(program)) {
              do {
                try self.runOnMainThread {
                  try sampler.loadSoundBankInstrument(
                    at: sfUrl, program: program,
                    bankMSB: attempt.bankMSB, bankLSB: attempt.bankLSB
                  )
                  sampler.globalTuning = self.globalTuningCents(for: self.playbackStandardA4)
                }
                break
              } catch { continue }
            }
          }

          // Always send sendProgramChange for every channel.  This
          // pre-configures the sampler per-channel before the sequencer
          // starts; the sequencer's own (patched) MIDI events reinforce it.
          if !applied.contains(ch) {
            applied.insert(ch)
            // sendProgramChange is thread-safe; no try needed.
            sampler.sendProgramChange(
              program, bankMSB: msb, bankLSB: lsb,
              onChannel: UInt8(ch)
            )
          }

        case 0x80, 0x90, 0xA0, 0xD0, 0xE0:
          pos += min((status & 0xF0 == 0xD0) ? 1 : 2, trackEnd - pos)

        case 0xF0:
          if status == 0xFF {
            guard pos < trackEnd else { break }
            let mt = bytes[pos]; pos += 1
            var len: UInt32 = 0; var s: UInt32 = 0
            while pos < trackEnd {
              let b = bytes[pos]; pos += 1
              len |= (UInt32(b & 0x7F) << s); s += 7
              if b & 0x80 == 0 { break }
            }
            pos += min(Int(len), trackEnd - pos)
            if mt == 0x2F { break }
          } else {
            var len: UInt32 = 0; var s: UInt32 = 0
            while pos < trackEnd {
              let b = bytes[pos]; pos += 1
              len |= (UInt32(b & 0x7F) << s); s += 7
              if b & 0x80 == 0 { break }
            }
            pos += min(Int(len), trackEnd - pos)
          }

        default:
          pos += 1
        }
      }
    }
    return patched
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadSoundfont":
        let args = call.arguments as! [String: Any]
        let path = args["path"] as! String
        let bank = args["bank"] as! Int
        let program = args["program"] as! Int
        let url = URL(fileURLWithPath: path)
        var chSamplers: [AVAudioUnitSampler] = []
        var chAudioEngines: [AVAudioEngine] = []
        var channelSelections: [Int: InstrumentSelection] = [:]
        for channel in 0...15 {
            let sampler = AVAudioUnitSampler()
            let audioEngine = AVAudioEngine()
            audioEngine.attach(sampler)
            audioEngine.connect(sampler, to: audioEngine.mainMixerNode, format: nil)
            do {
                try runOnMainThread {
                    try self.loadInstrument(sampler: sampler, url: url, bank: bank, program: program)
                }
            } catch {
                result(FlutterError(code: "SOUND_FONT_LOAD_FAILED1", message: "Failed to load soundfont", details: nil))
                return
            }
            chSamplers.append(sampler)
            chAudioEngines.append(audioEngine)
            channelSelections[channel] = InstrumentSelection(bank: bank, program: program)
        }
        soundfontSamplers[soundfontIndex] = chSamplers
        soundfontURLs[soundfontIndex] = url
        audioEngines[soundfontIndex] = chAudioEngines
        selectedInstruments[soundfontIndex] = channelSelections
        soundfontIndex += 1
        result(soundfontIndex-1)
    case "stopAllNotes":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]
        if soundfontSampler == nil {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        soundfontSampler!.forEach { (sampler) in
            sampler.sendController(64, withValue: 0, onChannel: Self.samplerMidiChannel)
            sampler.sendController(120, withValue: 0, onChannel: Self.samplerMidiChannel)
        }
        stopEngines(for: sfId)
        result(nil)
    case "controlChange":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let channel = args["channel"] as! Int
        let controller = args["controller"] as! Int
        let value = args["value"] as! Int
        guard let sampler = soundfontSamplers[sfId]?[channel] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont/channel not found", details: nil))
            return
        }
        sampler.sendController(UInt8(controller), withValue: UInt8(value), onChannel: Self.samplerMidiChannel)
        result(nil)
    case "selectInstrument":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let channel = args["channel"] as! Int
        let bank = args["bank"] as! Int
        let program = args["program"] as! Int
        let selection = InstrumentSelection(bank: bank, program: program)
        let key = channelKey(sfId: sfId, channel: channel)
        // After stopAllNotes the engines are stopped; reusing the cached
        // selection without reloading leaves muffled/wrong timbre on iOS.
        if selectedInstruments[sfId]?[channel] == selection,
           activeChannelKeys.contains(key) {
            result(nil)
            return
        }
        ensureChannelEngineRunning(sfId: sfId, channel: channel)
        let soundfontSampler = soundfontSamplers[sfId]![channel]
        let soundfontUrl = soundfontURLs[sfId]!
        applyInstrumentSelection(
            sampler: soundfontSampler,
            url: soundfontUrl,
            bank: bank,
            program: program
        )
        if selectedInstruments[sfId] == nil {
            selectedInstruments[sfId] = [:]
        }
        selectedInstruments[sfId]![channel] = selection
        result(nil)
    case "playNote":
        let args = call.arguments as! [String: Any]
        let channel = args["channel"] as! Int
        let note = args["key"] as! Int
        let velocity = args["velocity"] as! Int
        let sfId = args["sfId"] as! Int
        ensureChannelEngineRunning(sfId: sfId, channel: channel)
        let soundfontSampler = soundfontSamplers[sfId]![channel]
        soundfontSampler.startNote(UInt8(note), withVelocity: UInt8(velocity), onChannel: Self.samplerMidiChannel)
        result(nil)
    case "stopNote":
        let args = call.arguments as! [String: Any]
        let channel = args["channel"] as! Int
        let note = args["key"] as! Int
        let sfId = args["sfId"] as! Int
        let soundfontSampler = soundfontSamplers[sfId]![channel]
        soundfontSampler.stopNote(UInt8(note), onChannel: Self.samplerMidiChannel)
        result(nil)
    case "unloadSoundfont":
        let args = call.arguments as! [String:Any]
        let sfId = args["sfId"] as! Int
        // Stop & remove MIDI player
        if let seq = midiSequencers[sfId] {
            seq.stop()
            midiSequencers.removeValue(forKey: sfId)
        }
        if let engine = midiPlayerEngines[sfId] {
            engine.stop()
            midiPlayerEngines.removeValue(forKey: sfId)
        }
        midiPlayerSamplers.removeValue(forKey: sfId)
        let soundfontSampler = soundfontSamplers[sfId]
        if soundfontSampler == nil {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        stopEngines(for: sfId)
        audioEngines.removeValue(forKey: sfId)
        soundfontSamplers.removeValue(forKey: sfId)
        soundfontURLs.removeValue(forKey: sfId)
        selectedInstruments.removeValue(forKey: sfId)
        result(nil)
    case "dispose":
        // Stop MIDI players
        midiSequencers.forEach { $0.value.stop() }
        midiSequencers = [:]
        midiPlayerEngines.forEach { $0.value.stop() }
        midiPlayerEngines = [:]
        midiPlayerSamplers = [:]
        audioEngines.forEach { (_, engines) in
            engines.forEach { engine in
                engine.stop()
            }
        }
        audioEngines = [:]
        soundfontSamplers = [:]
        soundfontURLs = [:]
        selectedInstruments = [:]
        activeChannelKeys = []
        playbackStandardA4 = Self.defaultPlaybackStandardA4
        result(nil)
    case "setPlaybackStandard":
        let args = call.arguments as! [String: Any]
        let standard = args["standard"] as! Double
        if standard < Self.minPlaybackStandard || standard > Self.maxPlaybackStandard {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "standard must be between 400 and 480", details: nil))
            return
        }
        playbackStandardA4 = standard
        applyPlaybackStandardToAllSamplers()
        result(nil)
    case "resetPlaybackStandard":
        playbackStandardA4 = Self.defaultPlaybackStandardA4
        applyPlaybackStandardToAllSamplers()
        result(nil)
    case "getPlaybackStandard":
        result(playbackStandardA4)
    case "syncAudioEngine":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        guard let engines = audioEngines[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        for channel in engines.indices where activeChannelKeys.contains(channelKey(sfId: sfId, channel: channel)) {
            ensureChannelEngineRunning(sfId: sfId, channel: channel)
        }
        result(nil)
    case "playMidiBuffer":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let midiData = args["midiData"] as! FlutterStandardTypedData

        // 停止旧的 sequencer（保留 engine/sampler 以便复用）
        if let oldSeq = midiSequencers[sfId] {
            oldSeq.stop()
            midiSequencers.removeValue(forKey: sfId)
        }

        guard let sfUrl = soundfontURLs[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not loaded", details: nil))
            return
        }

        // 复用或创建 engine + sampler
        let engine: AVAudioEngine
        let sampler: AVAudioUnitSampler
        if let existingEngine = midiPlayerEngines[sfId],
           let existingSampler = midiPlayerSamplers[sfId] {
            engine = existingEngine
            sampler = existingSampler
        } else {
            engine = AVAudioEngine()
            sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            do {
                try engine.start()
            } catch {
                result(FlutterError(code: "ENGINE_START_FAILED", message: "\(error)", details: nil))
                return
            }
            // Load soundfont into the player sampler (use a known-good default)
            do {
                try runOnMainThread {
                    try self.loadInstrument(sampler: sampler, url: sfUrl, bank: 0, program: 0)
                }
            } catch {
                result(FlutterError(code: "INSTRUMENT_LOAD_FAILED", message: "\(error)", details: nil))
                return
            }
            midiPlayerEngines[sfId] = engine
            midiPlayerSamplers[sfId] = sampler
        }

        // ── Reset sampler channels ──
        // 复用 sampler 时，旧播放残留的 CC 值（如 CC 7 音量=0）、持续延音、
        // 未释放的踏板、以及旧的 Program Change 会干扰新播放。
        // 发 All Sound Off + All Notes Off 清除所有通道的持续状态。
        for ch in 0..<16 {
            sampler.sendController(64,  withValue: 0, onChannel: UInt8(ch)) // Sustain Off
            sampler.sendController(120, withValue: 0, onChannel: UInt8(ch)) // All Sound Off
            sampler.sendController(121, withValue: 0, onChannel: UInt8(ch)) // All Notes Off
        }

        // ── Patch MIDI Bank Select & pre-configure sampler channels ──
        let patchedMidi = self.patchMidiForSampler(sampler: sampler, midiData: midiData.data, sfUrl: sfUrl)

        let sequencer = AVAudioSequencer(audioEngine: engine)
        do {
            try sequencer.load(from: patchedMidi)
        } catch {
            result(FlutterError(code: "MIDI_LOAD_FAILED", message: "\(error)", details: nil))
            return
        }
        do {
            try sequencer.start()
        } catch {
            result(FlutterError(code: "MIDI_START_FAILED", message: "\(error)", details: nil))
            return
        }
        midiSequencers[sfId] = sequencer
        result(nil)
    case "stopMidiPlayer":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        // 停止 sequencer，但保留 engine + sampler 以便下次快速启动
        if let seq = midiSequencers[sfId] {
            seq.stop()
            midiSequencers.removeValue(forKey: sfId)
        }
        // Note: engine 和 sampler 保持存活，避免下次 playMidiBuffer 时
        // 重复创建 AVAudioEngine / 加载 SoundFont 的开销。
        result(nil)
    default:
      result(FlutterMethodNotImplemented)
        break
    }
  }
}
