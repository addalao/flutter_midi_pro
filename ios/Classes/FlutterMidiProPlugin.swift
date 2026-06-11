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
        // Stop existing player
        if let oldSeq = midiSequencers[sfId] {
            oldSeq.stop()
            midiSequencers.removeValue(forKey: sfId)
        }
        if let oldEngine = midiPlayerEngines[sfId] {
            oldEngine.stop()
            midiPlayerEngines.removeValue(forKey: sfId)
        }
        midiPlayerSamplers.removeValue(forKey: sfId)

        guard let sfUrl = soundfontURLs[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not loaded", details: nil))
            return
        }

        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
        } catch {
            result(FlutterError(code: "ENGINE_START_FAILED", message: "\(error)", details: nil))
            return
        }
        // Load soundfont into the player sampler
        do {
            try runOnMainThread {
                try self.loadInstrument(sampler: sampler, url: sfUrl, bank: 0, program: 0)
            }
        } catch {
            result(FlutterError(code: "INSTRUMENT_LOAD_FAILED", message: "\(error)", details: nil))
            return
        }

        let sequencer = AVAudioSequencer(audioEngine: engine)
        do {
            try sequencer.load(from: midiData.data, options: .smf)
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
        midiPlayerEngines[sfId] = engine
        midiPlayerSamplers[sfId] = sampler
        result(nil)
    case "stopMidiPlayer":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        if let seq = midiSequencers[sfId] {
            seq.stop()
            midiSequencers.removeValue(forKey: sfId)
        }
        if let engine = midiPlayerEngines[sfId] {
            engine.stop()
            midiPlayerEngines.removeValue(forKey: sfId)
        }
        midiPlayerSamplers.removeValue(forKey: sfId)
        result(nil)
    default:
      result(FlutterMethodNotImplemented)
        break
    }
  }
}
