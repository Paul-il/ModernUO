// Zuluhotel wire protocol (ZHW) - shared primitive.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\ChaCha20.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_sync.py.
// Отсюда же запрет на BCL-крипту: веб-клиент собирается под browser-wasm, где
// System.Security.Cryptography доступна частично. Всё считаем сами.
//
// ChaCha20 по RFC 8439. Проверяется векторами из RFC в ChaCha20Tests.

using System;
using System.Buffers.Binary;

namespace Zulu.Wire;

/// <summary>
/// ChaCha20 stream cipher (RFC 8439). Keystream generator with a 32-bit block counter,
/// used both as the session cipher and as the key-derivation PRF for ZHW.
/// </summary>
public sealed class ChaCha20
{
    public const int KeySize = 32;
    public const int NonceSize = 12;
    public const int BlockSize = 64;

    // "expand 32-byte k"
    private const uint C0 = 0x61707865;
    private const uint C1 = 0x3320646e;
    private const uint C2 = 0x79622d32;
    private const uint C3 = 0x6b206574;

    private readonly uint[] _state = new uint[16];
    private readonly byte[] _block = new byte[BlockSize];

    // How many bytes of _block have already been consumed. BlockSize means "none buffered".
    private int _blockOffset = BlockSize;

    public ChaCha20(ReadOnlySpan<byte> key, ReadOnlySpan<byte> nonce, uint counter = 0)
    {
        if (key.Length != KeySize)
        {
            throw new ArgumentException($"ChaCha20 key must be {KeySize} bytes", nameof(key));
        }

        if (nonce.Length != NonceSize)
        {
            throw new ArgumentException($"ChaCha20 nonce must be {NonceSize} bytes", nameof(nonce));
        }

        _state[0] = C0;
        _state[1] = C1;
        _state[2] = C2;
        _state[3] = C3;

        for (var i = 0; i < 8; i++)
        {
            _state[4 + i] = BinaryPrimitives.ReadUInt32LittleEndian(key[(i * 4)..]);
        }

        _state[12] = counter;

        for (var i = 0; i < 3; i++)
        {
            _state[13 + i] = BinaryPrimitives.ReadUInt32LittleEndian(nonce[(i * 4)..]);
        }
    }

    /// <summary>
    /// XORs <paramref name="buffer"/> with the next bytes of the keystream, in place.
    /// The cipher is stateful: callers must process the stream strictly in order, which is
    /// exactly what a TCP byte stream gives us on both ends.
    /// </summary>
    public void Process(Span<byte> buffer)
    {
        var i = 0;

        // Finish whatever is left of the previously generated block first.
        while (i < buffer.Length && _blockOffset < BlockSize)
        {
            buffer[i++] ^= _block[_blockOffset++];
        }

        while (i < buffer.Length)
        {
            NextBlock();

            var take = Math.Min(BlockSize, buffer.Length - i);
            for (var j = 0; j < take; j++)
            {
                buffer[i + j] ^= _block[j];
            }

            i += take;
            _blockOffset = take;
        }
    }

    /// <summary>
    /// Writes raw keystream bytes into <paramref name="output"/>. Used for key derivation,
    /// where there is no plaintext to XOR against.
    /// </summary>
    public void Keystream(Span<byte> output)
    {
        output.Clear();
        Process(output);
    }

    private void NextBlock()
    {
        Block(_state, _block);

        // 32-bit counter, wraps per RFC 8439. A session would have to push 256 GB through a
        // single direction to reach that, and the connection dies long before.
        _state[12]++;
    }

    private static void Block(uint[] state, Span<byte> output)
    {
        uint x0 = state[0], x1 = state[1], x2 = state[2], x3 = state[3];
        uint x4 = state[4], x5 = state[5], x6 = state[6], x7 = state[7];
        uint x8 = state[8], x9 = state[9], x10 = state[10], x11 = state[11];
        uint x12 = state[12], x13 = state[13], x14 = state[14], x15 = state[15];

        for (var i = 0; i < 10; i++)
        {
            // Column rounds
            QuarterRound(ref x0, ref x4, ref x8, ref x12);
            QuarterRound(ref x1, ref x5, ref x9, ref x13);
            QuarterRound(ref x2, ref x6, ref x10, ref x14);
            QuarterRound(ref x3, ref x7, ref x11, ref x15);

            // Diagonal rounds
            QuarterRound(ref x0, ref x5, ref x10, ref x15);
            QuarterRound(ref x1, ref x6, ref x11, ref x12);
            QuarterRound(ref x2, ref x7, ref x8, ref x13);
            QuarterRound(ref x3, ref x4, ref x9, ref x14);
        }

        BinaryPrimitives.WriteUInt32LittleEndian(output, x0 + state[0]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[4..], x1 + state[1]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[8..], x2 + state[2]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[12..], x3 + state[3]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[16..], x4 + state[4]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[20..], x5 + state[5]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[24..], x6 + state[6]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[28..], x7 + state[7]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[32..], x8 + state[8]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[36..], x9 + state[9]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[40..], x10 + state[10]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[44..], x11 + state[11]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[48..], x12 + state[12]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[52..], x13 + state[13]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[56..], x14 + state[14]);
        BinaryPrimitives.WriteUInt32LittleEndian(output[60..], x15 + state[15]);
    }

    private static void QuarterRound(ref uint a, ref uint b, ref uint c, ref uint d)
    {
        a += b; d ^= a; d = RotateLeft(d, 16);
        c += d; b ^= c; b = RotateLeft(b, 12);
        a += b; d ^= a; d = RotateLeft(d, 8);
        c += d; b ^= c; b = RotateLeft(b, 7);
    }

    private static uint RotateLeft(uint value, int offset) => (value << offset) | (value >> (32 - offset));

    /// <summary>
    /// One-shot keystream derivation: the ZHW key schedule uses ChaCha20 as its only PRF so
    /// that the whole protocol rests on three primitives and nothing from the BCL.
    /// </summary>
    public static void Derive(ReadOnlySpan<byte> key, ReadOnlySpan<byte> nonce, uint counter, Span<byte> output)
    {
        var chacha = new ChaCha20(key, nonce, counter);
        chacha.Keystream(output);
    }
}
