// Zuluhotel wire protocol (ZHW) - shared primitive.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\Poly1305.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_sync.py.
//
// Poly1305 по RFC 8439, структура donna32 (5 предельных слов по 26 бит).
// Проверяется векторами из RFC в Poly1305Tests.

using System;
using System.Buffers.Binary;

namespace Zulu.Wire;

/// <summary>
/// Poly1305 one-time authenticator (RFC 8439). ZHW uses it to authenticate handshake
/// messages: it proves the peer holds the build key and that nobody edited the transcript.
/// </summary>
public static class Poly1305
{
    public const int KeySize = 32;
    public const int TagSize = 16;

    /// <summary>
    /// Computes the 16-byte tag of <paramref name="message"/> under the one-time
    /// <paramref name="key"/>. A key must never be reused across two messages - ZHW derives a
    /// fresh one per handshake step from the ChaCha20 key schedule.
    /// </summary>
    public static void ComputeTag(ReadOnlySpan<byte> key, ReadOnlySpan<byte> message, Span<byte> tag)
    {
        if (key.Length != KeySize)
        {
            throw new ArgumentException($"Poly1305 key must be {KeySize} bytes", nameof(key));
        }

        if (tag.Length != TagSize)
        {
            throw new ArgumentException($"Poly1305 tag must be {TagSize} bytes", nameof(tag));
        }

        // r, clamped per the spec
        var r0 = BinaryPrimitives.ReadUInt32LittleEndian(key) & 0x3ffffff;
        var r1 = (BinaryPrimitives.ReadUInt32LittleEndian(key[3..]) >> 2) & 0x3ffff03;
        var r2 = (BinaryPrimitives.ReadUInt32LittleEndian(key[6..]) >> 4) & 0x3ffc0ff;
        var r3 = (BinaryPrimitives.ReadUInt32LittleEndian(key[9..]) >> 6) & 0x3f03fff;
        var r4 = (BinaryPrimitives.ReadUInt32LittleEndian(key[12..]) >> 8) & 0x00fffff;

        var s1 = r1 * 5;
        var s2 = r2 * 5;
        var s3 = r3 * 5;
        var s4 = r4 * 5;

        uint h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;

        Span<byte> block = stackalloc byte[16];
        var offset = 0;

        while (offset < message.Length)
        {
            var remaining = message.Length - offset;
            uint hibit;

            scoped ReadOnlySpan<byte> chunk;
            if (remaining >= 16)
            {
                chunk = message.Slice(offset, 16);
                hibit = 1u << 24;
                offset += 16;
            }
            else
            {
                // Final short block: append a 1 byte, zero-pad, and drop the implicit 2^128 bit.
                block.Clear();
                message[offset..].CopyTo(block);
                block[remaining] = 1;
                chunk = block;
                hibit = 0;
                offset = message.Length;
            }

            h0 += BinaryPrimitives.ReadUInt32LittleEndian(chunk) & 0x3ffffff;
            h1 += (BinaryPrimitives.ReadUInt32LittleEndian(chunk[3..]) >> 2) & 0x3ffffff;
            h2 += (BinaryPrimitives.ReadUInt32LittleEndian(chunk[6..]) >> 4) & 0x3ffffff;
            h3 += (BinaryPrimitives.ReadUInt32LittleEndian(chunk[9..]) >> 6) & 0x3ffffff;
            h4 += (BinaryPrimitives.ReadUInt32LittleEndian(chunk[12..]) >> 8) | hibit;

            var d0 = (ulong)h0 * r0 + (ulong)h1 * s4 + (ulong)h2 * s3 + (ulong)h3 * s2 + (ulong)h4 * s1;
            var d1 = (ulong)h0 * r1 + (ulong)h1 * r0 + (ulong)h2 * s4 + (ulong)h3 * s3 + (ulong)h4 * s2;
            var d2 = (ulong)h0 * r2 + (ulong)h1 * r1 + (ulong)h2 * r0 + (ulong)h3 * s4 + (ulong)h4 * s3;
            var d3 = (ulong)h0 * r3 + (ulong)h1 * r2 + (ulong)h2 * r1 + (ulong)h3 * r0 + (ulong)h4 * s4;
            var d4 = (ulong)h0 * r4 + (ulong)h1 * r3 + (ulong)h2 * r2 + (ulong)h3 * r1 + (ulong)h4 * r0;

            var c = (uint)(d0 >> 26); h0 = (uint)d0 & 0x3ffffff;
            d1 += c; c = (uint)(d1 >> 26); h1 = (uint)d1 & 0x3ffffff;
            d2 += c; c = (uint)(d2 >> 26); h2 = (uint)d2 & 0x3ffffff;
            d3 += c; c = (uint)(d3 >> 26); h3 = (uint)d3 & 0x3ffffff;
            d4 += c; c = (uint)(d4 >> 26); h4 = (uint)d4 & 0x3ffffff;
            h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
            h1 += c;
        }

        // Fully carry h
        var carry = h1 >> 26; h1 &= 0x3ffffff;
        h2 += carry; carry = h2 >> 26; h2 &= 0x3ffffff;
        h3 += carry; carry = h3 >> 26; h3 &= 0x3ffffff;
        h4 += carry; carry = h4 >> 26; h4 &= 0x3ffffff;
        h0 += carry * 5; carry = h0 >> 26; h0 &= 0x3ffffff;
        h1 += carry;

        // Compute h + -p
        var g0 = h0 + 5; carry = g0 >> 26; g0 &= 0x3ffffff;
        var g1 = h1 + carry; carry = g1 >> 26; g1 &= 0x3ffffff;
        var g2 = h2 + carry; carry = g2 >> 26; g2 &= 0x3ffffff;
        var g3 = h3 + carry; carry = g3 >> 26; g3 &= 0x3ffffff;
        var g4 = h4 + carry - (1u << 26);

        // Branchless select: g4's borrow bit says whether h was already below p.
        var mask = (g4 >> 31) - 1;
        g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
        mask = ~mask;
        h0 = (h0 & mask) | g0;
        h1 = (h1 & mask) | g1;
        h2 = (h2 & mask) | g2;
        h3 = (h3 & mask) | g3;
        h4 = (h4 & mask) | g4;

        // h %= 2^128
        h0 = h0 | (h1 << 26);
        h1 = (h1 >> 6) | (h2 << 20);
        h2 = (h2 >> 12) | (h3 << 14);
        h3 = (h3 >> 18) | (h4 << 8);

        // mac = (h + pad) % 2^128
        var f = (ulong)h0 + BinaryPrimitives.ReadUInt32LittleEndian(key[16..]); h0 = (uint)f;
        f = (ulong)h1 + BinaryPrimitives.ReadUInt32LittleEndian(key[20..]) + (f >> 32); h1 = (uint)f;
        f = (ulong)h2 + BinaryPrimitives.ReadUInt32LittleEndian(key[24..]) + (f >> 32); h2 = (uint)f;
        f = (ulong)h3 + BinaryPrimitives.ReadUInt32LittleEndian(key[28..]) + (f >> 32); h3 = (uint)f;

        BinaryPrimitives.WriteUInt32LittleEndian(tag, h0);
        BinaryPrimitives.WriteUInt32LittleEndian(tag[4..], h1);
        BinaryPrimitives.WriteUInt32LittleEndian(tag[8..], h2);
        BinaryPrimitives.WriteUInt32LittleEndian(tag[12..], h3);
    }

    /// <summary>
    /// Constant-time tag comparison. Never compare handshake tags with SequenceEqual: an early
    /// exit leaks how many leading bytes were right, which is enough to forge one byte at a time.
    /// </summary>
    public static bool VerifyTag(ReadOnlySpan<byte> key, ReadOnlySpan<byte> message, ReadOnlySpan<byte> expected)
    {
        if (expected.Length != TagSize)
        {
            return false;
        }

        Span<byte> actual = stackalloc byte[TagSize];
        ComputeTag(key, message, actual);

        var diff = 0;
        for (var i = 0; i < TagSize; i++)
        {
            diff |= actual[i] ^ expected[i];
        }

        return diff == 0;
    }
}
