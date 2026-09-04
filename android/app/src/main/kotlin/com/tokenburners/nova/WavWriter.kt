package com.tokenburners.nova

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Minimal PCM16 mono WAV writer. whisper.cpp wants 16 kHz mono; that's what the
 * capture loop produces, so this just frames the raw samples with a 44-byte
 * header.
 */
object WavWriter {

    fun write(file: File, samples: ShortArray, sampleRate: Int = 16_000) {
        file.parentFile?.mkdirs()
        val byteRate = sampleRate * 2 // mono, 16-bit
        val dataSize = samples.size * 2

        val pcm = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) pcm.putShort(s)

        RandomAccessFile(file, "rw").use { out ->
            out.setLength(0)
            out.writeBytes("RIFF")
            out.write(intLE(36 + dataSize))
            out.writeBytes("WAVE")
            out.writeBytes("fmt ")
            out.write(intLE(16))            // subchunk1 size
            out.write(shortLE(1))           // PCM
            out.write(shortLE(1))           // channels
            out.write(intLE(sampleRate))
            out.write(intLE(byteRate))
            out.write(shortLE(2))           // block align
            out.write(shortLE(16))          // bits per sample
            out.writeBytes("data")
            out.write(intLE(dataSize))
            out.write(pcm.array())
        }
    }

    private fun intLE(v: Int) = byteArrayOf(
        (v and 0xff).toByte(),
        ((v shr 8) and 0xff).toByte(),
        ((v shr 16) and 0xff).toByte(),
        ((v shr 24) and 0xff).toByte(),
    )

    private fun shortLE(v: Int) = byteArrayOf(
        (v and 0xff).toByte(),
        ((v shr 8) and 0xff).toByte(),
    )
}
