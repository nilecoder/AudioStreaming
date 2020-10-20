//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import CoreAudio
import AVFoundation

public final class AudioPlayer {
    
    public weak var delegate: AudioPlayerDelegate?
    
    public var muted: Bool {
        get { playerContext.muted }
        set { playerContext.$muted.write { $0 = newValue } }
    }
    
    /// The volume of the audio
    ///
    /// Defaults to 1.0. Valid ranges are 0.0 to 1.0
    /// The value is restricted from 0.0 to 1.0
    public var volume: Float32 {
        get { audioEngine.mainMixerNode.outputVolume }
        set { audioEngine.mainMixerNode.outputVolume = min(1.0, max(0.0, newValue)) }
    }
    /// The playback rate of the player.
    ///
    /// The default value is 1.0. Valid ranges are 1/32 to 32.0
    ///
    /// **NOTE:** Setting this to a value of more than `1.0` while playing a live broadcast stream would
    /// result in the audio being exhausted before it could fetch new data.
    public var rate: Float {
        get { rateNode.rate }
        set { rateNode.rate = newValue }
    }
    
    /// The player's current state.
    public var state: AudioPlayerState {
        playerContext.state
    }
    
    /// Indicates the reason that the player stopped.
    public var stopReason: AudioPlayerStopReason {
        playerContext.stopReason
    }
    
    /// The current configuration of the player.
    public let configuration: AudioPlayerConfiguration
    
    /// An `AVAudioFormat` object for the canonical audio stream
    private var outputAudioFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 44100.0, channels: 2, interleaved: true)!
    }()
    
    /// Keeps track of the player's state before being paused.
    private var stateBeforePaused: InternalState = .initial
    
    /// The underlying `AVAudioEngine` object
    let audioEngine = AVAudioEngine()
    /// An `AVAudioUnit` object that represents the audio player
    private(set) var player: AVAudioUnit?
    /// An `AVAudioUnitTimePitch` that controls the playback rate of the audio engine
    let rateNode = AVAudioUnitTimePitch()
    
    /// A Boolean value that indicates whether the audio engine is running.
    /// `true` if the engine is running, otherwise, `false`
    var isEngineRunning: Bool { audioEngine.isRunning }
    
    /// An object representing the context of the audio render.
    /// Holds the audio buffer and in/out lists as required by the audio rendering
    let rendererContext: AudioRendererContext
    /// An object representing the context of the player.
    /// Holds the player's state, current playing and reading entries.
    let playerContext: AudioPlayerContext
    
    let fileStreamProcessor: AudioFileStreamProcessor
    let playerRenderProcessor: AudioPlayerRenderProcessor
    
    private let audioReadSource: DispatchTimerSource
    private let underlyingQueue = DispatchQueue(label: "streaming.core.queue", qos: .userInitiated)
    private let sourceQueue: DispatchQueue
    
    private(set) lazy var networking = NetworkingClient()
    var audioSource: AudioStreamSource?
    
    var entriesQueue: PlayerQueueEntries
    
    public init(configuration: AudioPlayerConfiguration = .default) {
        self.configuration = configuration.normalizeValues()
        
        self.rendererContext = AudioRendererContext(configuration: configuration, outputAudioFormat: outputAudioFormat)
        self.playerContext = AudioPlayerContext()
        
        self.entriesQueue = PlayerQueueEntries()
        
        self.sourceQueue = DispatchQueue(label: "source.queue", qos: .userInitiated, target: underlyingQueue)
        self.audioReadSource = DispatchTimerSource(interval: .milliseconds(500), queue: underlyingQueue)
        
        self.fileStreamProcessor = AudioFileStreamProcessor(playerContext: playerContext,
                                                            rendererContext: rendererContext,
                                                            outputAudioFormat: outputAudioFormat.basicStreamDescription)
        
        self.playerRenderProcessor = AudioPlayerRenderProcessor(playerContext: playerContext,
                                                                rendererContext: rendererContext,
                                                                outputAudioFormat: outputAudioFormat.basicStreamDescription)
        
        self.configPlayerContext()
        self.configPlayerNode()
        self.setupEngine()
    }
    
    deinit {
        // todo more stuff to release...
        rendererContext.clean()
    }
    
    // MARK: Public
    
    /// Starts the audio playback for the given URL
    ///
    /// - parameter url: A `URL` specifying the audio context to be played
    public func play(url: URL) {
        play(url: url, headers: [:])
    }
    
    /// Starts the audio playback for the given URL
    ///
    /// - parameter url: A `URL` specifying the audio context to be played.
    /// - parameter headers: A `Dictionary` specifying any additional headers to be pass to the network request.
    public func play(url: URL, headers: [String: String]) {
        let audioSource = RemoteAudioSource(networking: networking,
                                            url: url,
                                            underlyingQueue: sourceQueue,
                                            httpHeaders: headers)
        let entry = AudioEntry(source: audioSource,
                               entryId: AudioEntryId(id: url.absoluteString))
        entry.delegate = self
        clearQueue()
        entriesQueue.enqueue(item: entry, type: .upcoming)
        playerContext.internalState = .pendingNext
        
        checkRenderWaitingAndNotifyIfNeeded()
        sourceQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.startEngineIfNeeded()
            } catch {
                self.raiseUnxpected(error: .audioSystemError(.engineFailure))
            }
            self.processSource()
            self.startReadProcessFromSourceIfNeeded()
        }
    }
    
    /// Stops the audio playback
    public func stop() {
        guard playerContext.internalState != .stopped else { return }
        
        stopEngine(reason: .userAction)
        stopReadProccessFromSource()
        sourceQueue.async { [weak self] in
            guard let self = self else { return }
            self.playerContext.audioReadingEntry?.delegate = nil
            self.playerContext.audioReadingEntry?.close()
            if let playingEntry = self.playerContext.audioPlayingEntry {
                self.processFinishPlaying(entry: playingEntry, with: nil)
            }
            
            self.clearQueue()
            self.playerContext.audioReadingEntry = nil
            self.playerContext.audioPlayingEntry = nil
            
            self.processSource()
        }
        checkRenderWaitingAndNotifyIfNeeded()
    }
    
    /// Pauses the audio playback
    public func pause() {
        if playerContext.internalState != .paused && playerContext.internalState.contains(.running) {
            stateBeforePaused = playerContext.internalState
            playerContext.setInternalState(to: .paused)
            
            pauseEngine()
            stopReadProccessFromSource()
            playerContext.audioPlayingEntry?.suspend()
            sourceQueue.async { [weak self] in
                self?.processSource()
            }
        }
    }
    /// Resumes the audio playback, if previous paused
    public func resume() {
        guard playerContext.internalState == .paused else { return }
        playerContext.setInternalState(to: stateBeforePaused)
        // check if seek time requested and reset buffers
        do {
            try startEngine()
        } catch {
            Logger.debug("resuming audio engine failed: %@", category: .generic, args: error.localizedDescription)
        }
        
        playerContext.audioPlayingEntry?.resume()
        startPlayer(resetBuffers: false)
        startReadProcessFromSourceIfNeeded()
    }
    
    /// The duration of the audio, in seconds.
    ///
    /// **NOTE** In live audio playback this will be `0.0`
    ///
    /// - Returns: A `Double` value indicating the total duration.
    public func duration() -> Double {
        guard playerContext.internalState != .pendingNext else { return 0 }
        guard let entry = playerContext.entriesLock.around( { playerContext.audioPlayingEntry } ) else { return 0 }
        
        let entryDuration = entry.duration()
        let progress = self.progress()
        if entryDuration < progress && entryDuration > 0 {
            return progress
        }
        return entryDuration
    }
    
    /// The progress of the audio playback, in seconds.
    public func progress() -> Double {
        // TODO: account for seek request
        guard playerContext.internalState != .pendingNext else { return 0 }
        guard let entry = playerContext.entriesLock.around( { playerContext.audioPlayingEntry } ) else { return 0 }
        
        return entry.lock.around {
            return Double(entry.seekTime) + (Double(entry.framesState.played) / outputAudioFormat.sampleRate)
        }
    }
    
    // MARK: Private
    
    /// Setups the audio engine with manual rendering mode.
    private func setupEngine() {
        do {
            // audio engine must be stop before enabling manualRendering mode.
            audioEngine.stop()
            playerRenderProcessor.renderBlock = audioEngine.manualRenderingBlock
            
            try audioEngine.enableManualRenderingMode(.realtime,
                                                      format: outputAudioFormat,
                                                      maximumFrameCount: maxFramesPerSlice)
            
            let inputBlock = { [weak self] frameCount -> UnsafePointer<AudioBufferList>? in
                self?.playerRenderProcessor.inRender(inNumberFrames: frameCount)
            }
            
            let success = audioEngine.inputNode.setManualRenderingInputPCMFormat(outputAudioFormat,
                                                                                 inputBlock: inputBlock)
            guard success else {
                assertionFailure("failure setting manual rendering mode")
                return
            }
            attachAndConnectNodes()
            
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            Logger.error("⚠️ error setuping audio engine: %@", category: .generic, args: error.localizedDescription)
        }
    }
    
    /// Creates and configures an `AVAudioUnit` with an output configuration
    /// and assigns it to the `player` variable.
    private func configPlayerNode() {
        let playerRenderProcessor = self.playerRenderProcessor
        AVAudioUnit.createAudioUnit(with: UnitDescriptions.output) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let unit):
                    self.player = unit
                    playerRenderProcessor.attachCallback(on: unit, audioFormat: self.outputAudioFormat)
                case .failure(let error):
                    assertionFailure("couldn't create player unit: \(error)")
                    self.raiseUnxpected(error: .audioSystemError(.playerNotFound))
            }
        }
    }
    
    /// Attaches callbacks to the `playerContext` and `renderProcessor`.
    private func configPlayerContext() {
        playerContext.stateChanged = { [weak self] oldValue, newValue in
            guard let self = self else { return }
            self.delegate?.audioPlayerStateChanged(player: self, with: newValue, previous: oldValue)
        }
        
        playerRenderProcessor.audioFinished = { [weak self] entry in
            guard let self = self else { return }
            self.sourceQueue.async {
                let nextEntry = self.entriesQueue.dequeue(type: .buffering)
                self.processFinishPlaying(entry: entry, with: nextEntry)
                self.processSource()
            }
        }
    }
    
    /// Attaches and connect nodes to the `AudioEngine`.
    private func attachAndConnectNodes() {
        audioEngine.attach(rateNode)
        
        audioEngine.connect(audioEngine.inputNode, to: rateNode, format: nil)
        audioEngine.connect(rateNode, to: audioEngine.mainMixerNode, format:  nil)
    }
    
    /// Starts the engine, if not already running.
    ///
    /// - Throws: An `Error` when failed to start the engine.
    private func startEngineIfNeeded() throws {
        guard !isEngineRunning else {
            Logger.debug("engine already running 🛵", category: .generic)
            return
        }
        try startEngine()
    }
    
    /// Force starts the engine
    ///
    /// - Throws: An `Error` when failed to start the engine.
    private func startEngine() throws {
        try audioEngine.start()
        Logger.debug("engine started 🛵", category: .generic)
    }
    
    /// Pauses the audio engine and stops the player's hardware
    private func pauseEngine() {
        guard isEngineRunning else { return }
        audioEngine.pause()
        player?.auAudioUnit.stopHardware()
        Logger.debug("engine paused ⏸", category: .generic)
    }
    
    /// Stops the audio engine and the player's hardware
    ///
    /// - parameter reason: A value of `AudioPlayerStopReason` indicating the reason the engine stopped.
    private func stopEngine(reason: AudioPlayerStopReason) {
        guard isEngineRunning else {
            Logger.debug("already already stopped 🛑", category: .generic)
            return
        }
        audioEngine.stop()
        player?.auAudioUnit.stopHardware()
        rendererContext.resetBuffers()
        playerContext.internalState = .stopped
        playerContext.$stopReason.write { $0 = reason }
        Logger.debug("engine stopped 🛑", category: .generic)
    }
    
    /// Starts the timer of `audioReadSource` for proccesing the source read stream
    ///
    /// This calls `processSource` method every `500 ms`
    ///
    private func startReadProcessFromSourceIfNeeded() {
        guard audioReadSource.state != .activated else { return }
        audioReadSource.add { [weak self] in
            self?.processSource()
        }
        audioReadSource.activate()
    }
    
    /// Stops and removes the handler from the timer, @see `audioReadSource`
    private func stopReadProccessFromSource() {
        audioReadSource.suspend()
        audioReadSource.removeHandler()
    }
    
    /// Starts the audio player, reseting the buffers if requested
    ///
    /// - parameter resetBuffers: A `Bool` value indicating if the buffers should be reset, prior starting the player.
    private func startPlayer(resetBuffers: Bool) {
        guard let player = player else { return }
        if resetBuffers {
            rendererContext.resetBuffers()
        }
        if !isEngineRunning && !player.auAudioUnit.isRunning {
            Logger.debug("trying to start the player when audio engine and player are already running", category: .generic)
            return
        }
        do {
            try player.auAudioUnit.startHardware()
        } catch {
            raiseUnxpected(error: .audioSystemError(.playerStartError))
        }
        // TODO: stop system background task
        
    }
    
    /// Processing the `playerContext` state to ensure correct behavior of playing/stop/seek
    private func processSource() {
        guard !playerContext.disposedRequested else { return }
        guard playerContext.internalState != .paused else { return }
        
        if playerContext.internalState == .pendingNext {
            let entry = entriesQueue.dequeue(type: .upcoming)
            playerContext.internalState = .waitingForData
            setCurrentReading(entry: entry, startPlaying: true, shouldClearQueue: true)
            rendererContext.resetBuffers()
        }
        else if playerContext.audioReadingEntry == nil {
            if entriesQueue.count(for: .upcoming) > 0 {
                let entry = entriesQueue.dequeue(type: .upcoming)
                let shouldStartPlaying = playerContext.audioPlayingEntry == nil
                playerContext.internalState = .waitingForData
                setCurrentReading(entry: entry, startPlaying: shouldStartPlaying, shouldClearQueue: true)
            } else if playerContext.audioPlayingEntry == nil {
                if playerContext.internalState != .stopped {
                    stopReadProccessFromSource()
                    stopEngine(reason: .eof)
                }
            }
        }
    }
    
    private func setCurrentReading(entry: AudioEntry?, startPlaying: Bool, shouldClearQueue: Bool) {
        guard let entry = entry else { return }
        Logger.debug("Setting current reading entry to: %@", category: .generic, args: entry.debugDescription)
        if startPlaying {
            let count = Int(rendererContext.bufferContext.totalFrameCount * rendererContext.bufferContext.sizeInBytes)
            memset(rendererContext.audioBuffer.mData, 0, count)
        }
        
        fileStreamProcessor.closeFileStreamIfNeeded()
        
        if let readingEntry = playerContext.audioReadingEntry {
            readingEntry.delegate = nil
            readingEntry.close()
        }
        
        playerContext.entriesLock.around {
            playerContext.audioReadingEntry = entry
        }
        playerContext.audioReadingEntry?.delegate = self
        playerContext.audioReadingEntry?.seek(at: 0)
        
        if startPlaying {
            if shouldClearQueue {
                clearQueue()
            }
            processFinishPlaying(entry: playerContext.audioPlayingEntry, with: entry)
            startPlayer(resetBuffers: true)
        } else {
            entriesQueue.enqueue(item: entry, type: .buffering)
        }
    }
    
    private func processFinishPlaying(entry: AudioEntry?, with nextEntry: AudioEntry?) {
        guard entry == playerContext.audioPlayingEntry else { return }
        
        let isPlayingSameItemProbablySeek = playerContext.audioPlayingEntry == nextEntry
        
        let notifyDelegateEntryFinishedPlaying: (AudioEntry?, Bool) -> Void = { [weak self] entry, probablySeek in
            guard let self = self else { return }
            if let entry = entry, !isPlayingSameItemProbablySeek {
                let entryId = entry.id
                let progressInFrames = entry.progressInFrames()
                let progress = Double(progressInFrames) / self.outputAudioFormat.basicStreamDescription.mSampleRate
                let duration = entry.duration()
                
                asyncOnMain {
                    self.delegate?.audioPlayerDidFinishPlaying(player: self, entryId: entryId, stopReason: self.stopReason, progress: progress, duration: duration)
                }
            }
        }
        
        if let nextEntry = nextEntry {
            if !isPlayingSameItemProbablySeek {
                sourceQueue.async {
                    nextEntry.seekTime = 0
                }
                // seek requested no.
            }
            playerContext.entriesLock.around {
                playerContext.audioPlayingEntry = nextEntry
            }
            let playingQueueEntryId = nextEntry.id
            
            notifyDelegateEntryFinishedPlaying(entry, isPlayingSameItemProbablySeek)
            if !isPlayingSameItemProbablySeek {
                playerContext.internalState = .waitingForData
                
                asyncOnMain { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.audioPlayerDidStartPlaying(player: self, with: playingQueueEntryId)
                }
            }
        } else {
            notifyDelegateEntryFinishedPlaying(entry, isPlayingSameItemProbablySeek)
            playerContext.entriesLock.around {
                playerContext.audioPlayingEntry = nil
            }
        }
        processSource()
        checkRenderWaitingAndNotifyIfNeeded()
    }
    
    /// Clears pending queues and informs the delegate
    private func clearQueue() {
        let pendingItems = entriesQueue.pendingEntriesId()
        entriesQueue.removeAll()
        if !pendingItems.isEmpty {
            asyncOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioPlayerDidCancel(player: self, queuedItems: pendingItems)
            }
        }
    }
    
    /// Signals the packet process
    private func checkRenderWaitingAndNotifyIfNeeded() {
        if rendererContext.waiting {
            rendererContext.packetsSemaphore.signal()
        }
    }
    
    private func raiseUnxpected(error: AudioPlayerError) {
        playerContext.internalState = .error
        // todo raise on main thread from playback thread
        asyncOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioPlayerUnexpectedError(player: self, error: error)
        }
        Logger.error("Error: %@", category: .generic, args: error.localizedDescription)
    }
    
}

extension AudioPlayer: AudioStreamSourceDelegate {
    
    func dataAvailable(source: AudioStreamSource, data: Data) {
        guard let readingEntry = playerContext.audioReadingEntry,
              readingEntry.has(same: source) else { return }
        
        if !fileStreamProcessor.isFileStreamOpen {
            guard fileStreamProcessor.openFileStream(with: source.audioFileHint) == noErr else {
                raiseUnxpected(error: .audioSystemError(.fileStreamError))
                return
            }
        }
        
        // TODO: check for discontinuous stream and add flag
        if fileStreamProcessor.isFileStreamOpen {
            guard fileStreamProcessor.parseFileStreamBytes(data: data) == noErr else {
                if let playingEntry = playerContext.audioPlayingEntry,
                   playingEntry.has(same: source) {
                    raiseUnxpected(error: .streamParseBytesFailure)
                }
                return
            }
            
            playerContext.entriesLock.lock()
            if playerContext.audioReadingEntry === nil {
                source.close()
            }
            playerContext.entriesLock.unlock()
        }
    }
    
    func errorOccured(source: AudioStreamSource, error: Error) {
        guard let entry = playerContext.audioReadingEntry, entry.has(same: source) else { return }
        raiseUnxpected(error: .networkError(.failure(error)))
    }
    
    func endOfFileOccured(source: AudioStreamSource) {
        let hasSameSource = playerContext.audioReadingEntry?.has(same: source) ?? false
        guard playerContext.audioReadingEntry == nil || hasSameSource else {
            source.delegate = nil
            source.close()
            return
        }
        let queuedItemId = playerContext.audioReadingEntry?.id
        asyncOnMain { [weak self] in
            guard let self = self else { return }
            guard let itemId = queuedItemId else { return }
            self.delegate?.audioPlayerDidFinishBuffering(player: self, with: itemId)
        }
        
        guard let readingEntry = playerContext.audioReadingEntry else {
            source.delegate = nil
            source.close()
            return
        }
        
        readingEntry.framesState.lastFrameQueued = readingEntry.framesState.queued
        
        readingEntry.delegate = nil
        readingEntry.close()
        
        playerContext.entriesLock.lock()
        playerContext.audioReadingEntry = nil
        playerContext.entriesLock.unlock()
        processSource()
    }
    
    func metadataReceived(data: [String : String]) {
        asyncOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioPlayerDidReadMetadata(player: self, metadata: data)
        }
    }
    
}
