// Converts readable audio into a short, loop-smoothed PCM alarm clip.

import AudioToolbox
import Foundation

enum AlarmAudioTranscoder {
  static let sampleRate = 44_100.0
  static let channelCount: UInt32 = 1
  static let bitDepth: UInt32 = 16
  static let maximumDuration = 29.0

  private static let bufferFrameCapacity = 8_192
  private static let crossfadeDuration = 0.008

  static func transcode(source: URL, destination: URL) throws {
    var inputFile: ExtAudioFileRef?
    try check(
      ExtAudioFileOpenURL(source as CFURL, &inputFile),
      fallback: .unreadableFile
    )
    guard let inputFile else {
      throw SoundLibraryError.unreadableFile
    }
    defer { ExtAudioFileDispose(inputFile) }

    var processingFormat = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
      mChannelsPerFrame: channelCount,
      mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
      mReserved: 0
    )
    let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
      ExtAudioFileSetProperty(
        inputFile,
        kExtAudioFileProperty_ClientDataFormat,
        formatSize,
        &processingFormat
      ),
      fallback: .unsupportedFile
    )

    let samples = try readSamples(from: inputFile, format: processingFormat)
    guard !samples.isEmpty else {
      throw SoundLibraryError.noAudioTrack
    }

    let loopSmoothedSamples = smoothLoopBoundary(in: samples)
    var processedSamples = compress(loopSmoothedSamples)

    var outputFormat = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bitDepth / 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: bitDepth / 8,
      mChannelsPerFrame: channelCount,
      mBitsPerChannel: bitDepth,
      mReserved: 0
    )

    var outputFile: ExtAudioFileRef?
    try check(
      ExtAudioFileCreateWithURL(
        destination as CFURL,
        kAudioFileWAVEType,
        &outputFormat,
        nil,
        AudioFileFlags.eraseFile.rawValue,
        &outputFile
      ),
      fallback: .conversionFailed
    )
    guard let outputFile else {
      throw SoundLibraryError.conversionFailed
    }
    defer { ExtAudioFileDispose(outputFile) }

    try check(
      ExtAudioFileSetProperty(
        outputFile,
        kExtAudioFileProperty_ClientDataFormat,
        formatSize,
        &processingFormat
      ),
      fallback: .conversionFailed
    )
    try write(samples: &processedSamples, to: outputFile, format: processingFormat)
  }

  private static func readSamples(
    from inputFile: ExtAudioFileRef,
    format: AudioStreamBasicDescription
  ) throws -> [Float] {
    let maximumFrames = Int(maximumDuration * sampleRate)
    var samples: [Float] = []
    samples.reserveCapacity(maximumFrames)
    var sampleBuffer = [Float](repeating: 0, count: bufferFrameCapacity)

    while samples.count < maximumFrames {
      let requestedFrames = min(bufferFrameCapacity, maximumFrames - samples.count)
      var frameCount = UInt32(requestedFrames)
      let readStatus = sampleBuffer.withUnsafeMutableBufferPointer { buffer -> OSStatus in
        guard let baseAddress = buffer.baseAddress else { return kAudio_ParamError }
        var audioBufferList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: channelCount,
            mDataByteSize: UInt32(requestedFrames) * format.mBytesPerFrame,
            mData: baseAddress
          )
        )
        return ExtAudioFileRead(inputFile, &frameCount, &audioBufferList)
      }

      try check(readStatus, fallback: .conversionFailed)
      guard frameCount > 0 else { break }
      samples.append(contentsOf: sampleBuffer.prefix(Int(frameCount)))
    }

    return samples
  }

  private static func smoothLoopBoundary(in samples: [Float]) -> [Float] {
    let requestedFadeFrames = Int(crossfadeDuration * sampleRate)
    let fadeFrames = min(requestedFadeFrames, samples.count / 4)
    guard fadeFrames >= 2 else { return samples }

    let splitIndex = quietSplitIndex(in: samples, minimumEdgeDistance: fadeFrames)
    let firstClip = Array(samples[..<splitIndex])
    let secondClip = Array(samples[splitIndex...])
    guard firstClip.count >= fadeFrames, secondClip.count >= fadeFrames else { return samples }

    // Treat the chosen audio as a circle: swap the clips, blend the original end into
    // the original beginning, then restore chronological order around that tiny seam.
    let endOfSecond = secondClip.suffix(fadeFrames)
    let startOfFirst = firstClip.prefix(fadeFrames)
    let crossfade = zip(endOfSecond, startOfFirst).enumerated().map { index, pair in
      let progress = Float(index + 1) / Float(fadeFrames + 1)
      let fadeOut = cos(progress * .pi / 2)
      let fadeIn = sin(progress * .pi / 2)
      return pair.0 * fadeOut + pair.1 * fadeIn
    }

    var reordered: [Float] = []
    reordered.reserveCapacity(samples.count - fadeFrames)
    reordered.append(contentsOf: crossfade)
    reordered.append(contentsOf: firstClip.dropFirst(fadeFrames))
    reordered.append(contentsOf: secondClip.dropLast(fadeFrames))
    return reordered
  }

  private static func quietSplitIndex(
    in samples: [Float],
    minimumEdgeDistance: Int
  ) -> Int {
    let analysisWindow = max(32, Int(sampleRate * 0.02))
    let lowerBound = max(minimumEdgeDistance, samples.count / 10)
    let upperBound = min(samples.count - minimumEdgeDistance, samples.count * 9 / 10)
    guard upperBound > lowerBound + analysisWindow else {
      return samples.count / 2
    }

    var squaredPrefix = [Double](repeating: 0, count: samples.count + 1)
    for index in samples.indices {
      let sample = Double(samples[index])
      squaredPrefix[index + 1] = squaredPrefix[index] + sample * sample
    }

    let halfWindow = analysisWindow / 2
    let strideLength = max(1, analysisWindow / 4)
    var quietestIndex = samples.count / 2
    var quietestEnergy = Double.greatestFiniteMagnitude

    for candidate in stride(from: lowerBound, through: upperBound, by: strideLength) {
      let windowStart = max(0, candidate - halfWindow)
      let windowEnd = min(samples.count, candidate + halfWindow)
      let energy = squaredPrefix[windowEnd] - squaredPrefix[windowStart]
      if energy < quietestEnergy {
        quietestEnergy = energy
        quietestIndex = candidate
      }
    }

    return quietestIndex
  }

  private static func compress(_ samples: [Float]) -> [Float] {
    let thresholdDecibels: Float = -12
    let ratio: Float = 3
    let makeupGain = pow(Float(10), Float(2) / 20)
    let attackCoefficient = exp(Float(-1) / Float(sampleRate * 0.004))
    let releaseCoefficient = exp(Float(-1) / Float(sampleRate * 0.09))
    let minimumLevel: Float = 0.000_001
    var envelope: Float = 0

    var compressed = samples.map { sample -> Float in
      let level = abs(sample)
      let coefficient = level > envelope ? attackCoefficient : releaseCoefficient
      envelope = coefficient * envelope + (1 - coefficient) * level

      guard envelope > minimumLevel else { return sample * makeupGain }
      let envelopeDecibels = 20 * log10(envelope)
      let gainReductionDecibels: Float
      if envelopeDecibels > thresholdDecibels {
        let compressedDecibels =
          thresholdDecibels + (envelopeDecibels - thresholdDecibels) / ratio
        gainReductionDecibels = compressedDecibels - envelopeDecibels
      } else {
        gainReductionDecibels = 0
      }
      let compressionGain = pow(Float(10), gainReductionDecibels / 20)
      return sample * compressionGain * makeupGain
    }

    let peak = compressed.reduce(Float(0)) { max($0, abs($1)) }
    if peak > 0.97 {
      let limiterGain = Float(0.97) / peak
      compressed = compressed.map { $0 * limiterGain }
    }
    return compressed
  }

  private static func write(
    samples: inout [Float],
    to outputFile: ExtAudioFileRef,
    format: AudioStreamBasicDescription
  ) throws {
    var writeStatus = noErr
    samples.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        writeStatus = kAudio_ParamError
        return
      }

      var offset = 0
      while offset < buffer.count, writeStatus == noErr {
        let frameCount = min(bufferFrameCapacity, buffer.count - offset)
        var audioBufferList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: channelCount,
            mDataByteSize: UInt32(frameCount) * format.mBytesPerFrame,
            mData: baseAddress.advanced(by: offset)
          )
        )
        writeStatus = ExtAudioFileWrite(outputFile, UInt32(frameCount), &audioBufferList)
        offset += frameCount
      }
    }
    try check(writeStatus, fallback: .conversionFailed)
  }

  private static func check(_ status: OSStatus, fallback: SoundLibraryError) throws {
    guard status == noErr else {
      throw SoundLibraryError.audioToolboxFailure(status, fallback: fallback)
    }
  }
}
