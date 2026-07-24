// Converts readable audio into the short linear-PCM format accepted by AlarmKit.

import AudioToolbox
import Foundation

enum AlarmAudioTranscoder {
  static let sampleRate = 44_100.0
  static let channelCount: UInt32 = 1
  static let bitDepth: UInt32 = 16
  static let maximumDuration = 29.0

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

    let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
      ExtAudioFileSetProperty(
        inputFile,
        kExtAudioFileProperty_ClientDataFormat,
        formatSize,
        &outputFormat
      ),
      fallback: .unsupportedFile
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
        &outputFormat
      ),
      fallback: .conversionFailed
    )

    let bufferFrameCapacity: UInt32 = 8_192
    let bytesPerFrame = Int(outputFormat.mBytesPerFrame)
    var sampleStorage = Data(count: Int(bufferFrameCapacity) * bytesPerFrame)
    let maximumFrames = Int64(maximumDuration * sampleRate)
    var framesWritten: Int64 = 0

    while framesWritten < maximumFrames {
      let remainingFrames = maximumFrames - framesWritten
      var frameCount = UInt32(min(Int64(bufferFrameCapacity), remainingFrames))
      let requestedByteCount = Int(frameCount) * bytesPerFrame

      let readStatus = sampleStorage.withUnsafeMutableBytes { bytes -> OSStatus in
        guard let baseAddress = bytes.baseAddress else { return kAudio_ParamError }
        var audioBufferList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: channelCount,
            mDataByteSize: UInt32(requestedByteCount),
            mData: baseAddress
          )
        )
        let status = ExtAudioFileRead(inputFile, &frameCount, &audioBufferList)
        guard status == noErr, frameCount > 0 else { return status }
        audioBufferList.mBuffers.mDataByteSize = frameCount * outputFormat.mBytesPerFrame
        return ExtAudioFileWrite(outputFile, frameCount, &audioBufferList)
      }

      try check(readStatus, fallback: .conversionFailed)
      guard frameCount > 0 else { break }
      framesWritten += Int64(frameCount)
    }

    guard framesWritten > 0 else {
      throw SoundLibraryError.noAudioTrack
    }
  }

  private static func check(_ status: OSStatus, fallback: SoundLibraryError) throws {
    guard status == noErr else {
      throw SoundLibraryError.audioToolboxFailure(status, fallback: fallback)
    }
  }
}
