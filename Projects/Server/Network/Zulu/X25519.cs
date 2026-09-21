// Zuluhotel wire protocol (ZHW) - shared primitive.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\X25519.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_protocol.py.
//
// X25519 по RFC 7748. Порт curve25519-donna-c64: поле в системе счисления 2^51,
// пять слов, произведения через UInt128. Проверяется векторами RFC в X25519Tests.
//
// Зачем свой Диффи-Хеллман, а не ECDiffieHellman из BCL: клиент собирается в том
// числе под browser-wasm, где System.Security.Cryptography урезана. Плюс ключ на
// сессию даёт то, чего у шарда нет сегодня, - пароль в пакете 0x80 перестаёт
// лететь открытым текстом.

using System;
using System.Buffers.Binary;

namespace Zulu.Wire;

/// <summary>
/// X25519 Diffie-Hellman (RFC 7748).
/// </summary>
public static class X25519
{
    public const int KeySize = 32;

    private const ulong Mask51 = 0x7ffffffffffff;

    private static readonly byte[] BasePoint =
    {
        9, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    };

    /// <summary>
    /// Derives the public key for <paramref name="privateKey"/> (32 random bytes).
    /// </summary>
    public static void GetPublicKey(ReadOnlySpan<byte> privateKey, Span<byte> publicKey) =>
        ScalarMultiply(privateKey, BasePoint, publicKey);

    /// <summary>
    /// Computes the shared secret between our private key and the peer's public key.
    /// Returns false for the all-zero result, which is what a peer sending a low-order point
    /// produces: accepting it would mean both sides "agree" on a key an attacker also knows.
    /// </summary>
    public static bool TryAgree(ReadOnlySpan<byte> privateKey, ReadOnlySpan<byte> peerPublicKey, Span<byte> sharedSecret)
    {
        ScalarMultiply(privateKey, peerPublicKey, sharedSecret);

        var accumulator = 0;
        for (var i = 0; i < KeySize; i++)
        {
            accumulator |= sharedSecret[i];
        }

        return accumulator != 0;
    }

    public static void ScalarMultiply(ReadOnlySpan<byte> scalar, ReadOnlySpan<byte> point, Span<byte> output)
    {
        if (scalar.Length != KeySize || point.Length != KeySize || output.Length != KeySize)
        {
            throw new ArgumentException($"X25519 operands must be {KeySize} bytes");
        }

        Span<byte> e = stackalloc byte[KeySize];
        scalar.CopyTo(e);

        // Scalar clamping per RFC 7748.
        e[0] &= 248;
        e[31] &= 127;
        e[31] |= 64;

        var bp = new ulong[5];
        var x = new ulong[5];
        var z = new ulong[5];
        var zmone = new ulong[5];

        Expand(bp, point);
        ScalarMultiplyInternal(x, z, e, bp);
        Reciprocal(zmone, z);
        Multiply(z, x, zmone);
        Contract(output, z);
    }

    // output = in1 * in2
    private static void Multiply(ulong[] output, ulong[] in2, ulong[] input)
    {
        ulong r0 = input[0], r1 = input[1], r2 = input[2], r3 = input[3], r4 = input[4];
        ulong s0 = in2[0], s1 = in2[1], s2 = in2[2], s3 = in2[3], s4 = in2[4];

        var t0 = (UInt128)r0 * s0;
        var t1 = (UInt128)r0 * s1 + (UInt128)r1 * s0;
        var t2 = (UInt128)r0 * s2 + (UInt128)r2 * s0 + (UInt128)r1 * s1;
        var t3 = (UInt128)r0 * s3 + (UInt128)r3 * s0 + (UInt128)r1 * s2 + (UInt128)r2 * s1;
        var t4 = (UInt128)r0 * s4 + (UInt128)r4 * s0 + (UInt128)r3 * s1 + (UInt128)r1 * s3 + (UInt128)r2 * s2;

        r4 *= 19; r1 *= 19; r2 *= 19; r3 *= 19;

        t0 += (UInt128)r4 * s1 + (UInt128)r1 * s4 + (UInt128)r2 * s3 + (UInt128)r3 * s2;
        t1 += (UInt128)r4 * s2 + (UInt128)r2 * s4 + (UInt128)r3 * s3;
        t2 += (UInt128)r4 * s3 + (UInt128)r3 * s4;
        t3 += (UInt128)r4 * s4;

        r0 = (ulong)t0 & Mask51; var c = (ulong)(t0 >> 51);
        t1 += c; r1 = (ulong)t1 & Mask51; c = (ulong)(t1 >> 51);
        t2 += c; r2 = (ulong)t2 & Mask51; c = (ulong)(t2 >> 51);
        t3 += c; r3 = (ulong)t3 & Mask51; c = (ulong)(t3 >> 51);
        t4 += c; r4 = (ulong)t4 & Mask51; c = (ulong)(t4 >> 51);
        r0 += c * 19; c = r0 >> 51; r0 &= Mask51;
        r1 += c; c = r1 >> 51; r1 &= Mask51;
        r2 += c;

        output[0] = r0; output[1] = r1; output[2] = r2; output[3] = r3; output[4] = r4;
    }

    // output = in^(2^count)
    private static void SquareTimes(ulong[] output, ulong[] input, int count)
    {
        ulong r0 = input[0], r1 = input[1], r2 = input[2], r3 = input[3], r4 = input[4];

        do
        {
            var d0 = r0 * 2;
            var d1 = r1 * 2;
            var d2 = r2 * 2 * 19;
            var d419 = r4 * 19;
            var d4 = d419 * 2;

            var t0 = (UInt128)r0 * r0 + (UInt128)d4 * r1 + (UInt128)d2 * r3;
            var t1 = (UInt128)d0 * r1 + (UInt128)d4 * r2 + (UInt128)r3 * (r3 * 19);
            var t2 = (UInt128)d0 * r2 + (UInt128)r1 * r1 + (UInt128)d4 * r3;
            var t3 = (UInt128)d0 * r3 + (UInt128)d1 * r2 + (UInt128)r4 * d419;
            var t4 = (UInt128)d0 * r4 + (UInt128)d1 * r3 + (UInt128)r2 * r2;

            r0 = (ulong)t0 & Mask51; var c = (ulong)(t0 >> 51);
            t1 += c; r1 = (ulong)t1 & Mask51; c = (ulong)(t1 >> 51);
            t2 += c; r2 = (ulong)t2 & Mask51; c = (ulong)(t2 >> 51);
            t3 += c; r3 = (ulong)t3 & Mask51; c = (ulong)(t3 >> 51);
            t4 += c; r4 = (ulong)t4 & Mask51; c = (ulong)(t4 >> 51);
            r0 += c * 19; c = r0 >> 51; r0 &= Mask51;
            r1 += c; c = r1 >> 51; r1 &= Mask51;
            r2 += c;
        } while (--count > 0);

        output[0] = r0; output[1] = r1; output[2] = r2; output[3] = r3; output[4] = r4;
    }

    // output += input
    private static void Sum(ulong[] output, ulong[] input)
    {
        output[0] += input[0];
        output[1] += input[1];
        output[2] += input[2];
        output[3] += input[3];
        output[4] += input[4];
    }

    // output = input - output. Note the argument order: it mirrors donna's
    // fdifference_backwards, and the constants pre-add a multiple of p so the result
    // never goes negative in unsigned arithmetic. 152 is 19 << 3.
    private static void DifferenceBackwards(ulong[] output, ulong[] input)
    {
        const ulong two54m152 = (1UL << 54) - 152;
        const ulong two54m8 = (1UL << 54) - 8;

        output[0] = input[0] + two54m152 - output[0];
        output[1] = input[1] + two54m8 - output[1];
        output[2] = input[2] + two54m8 - output[2];
        output[3] = input[3] + two54m8 - output[3];
        output[4] = input[4] + two54m8 - output[4];
    }

    // output = input * scalar
    private static void ScalarProduct(ulong[] output, ulong[] input, ulong scalar)
    {
        var a = (UInt128)input[0] * scalar;
        output[0] = (ulong)a & Mask51;

        a = (UInt128)input[1] * scalar + (ulong)(a >> 51);
        output[1] = (ulong)a & Mask51;

        a = (UInt128)input[2] * scalar + (ulong)(a >> 51);
        output[2] = (ulong)a & Mask51;

        a = (UInt128)input[3] * scalar + (ulong)(a >> 51);
        output[3] = (ulong)a & Mask51;

        a = (UInt128)input[4] * scalar + (ulong)(a >> 51);
        output[4] = (ulong)a & Mask51;

        output[0] += (ulong)(a >> 51) * 19;
    }

    private static void Expand(ulong[] output, ReadOnlySpan<byte> input)
    {
        output[0] = BinaryPrimitives.ReadUInt64LittleEndian(input) & Mask51;
        output[1] = (BinaryPrimitives.ReadUInt64LittleEndian(input[6..]) >> 3) & Mask51;
        output[2] = (BinaryPrimitives.ReadUInt64LittleEndian(input[12..]) >> 6) & Mask51;
        output[3] = (BinaryPrimitives.ReadUInt64LittleEndian(input[19..]) >> 1) & Mask51;
        output[4] = (BinaryPrimitives.ReadUInt64LittleEndian(input[24..]) >> 12) & Mask51;
    }

    private static void Contract(Span<byte> output, ulong[] input)
    {
        ulong t0 = input[0], t1 = input[1], t2 = input[2], t3 = input[3], t4 = input[4];

        CarryPassFull(ref t0, ref t1, ref t2, ref t3, ref t4);
        CarryPassFull(ref t0, ref t1, ref t2, ref t3, ref t4);

        // Now 0 .. 2^255-1, properly carried. Two cases remain: 2^255-19 .. 2^255-1,
        // or 0 .. 2^255-20. Offsetting by 19 collapses them into one.
        t0 += 19;
        CarryPassFull(ref t0, ref t1, ref t2, ref t3, ref t4);

        t0 += 0x8000000000000 - 19;
        t1 += 0x8000000000000 - 1;
        t2 += 0x8000000000000 - 1;
        t3 += 0x8000000000000 - 1;
        t4 += 0x8000000000000 - 1;

        CarryPass(ref t0, ref t1, ref t2, ref t3, ref t4);
        t4 &= Mask51;

        t0 |= t1 << 51;
        t1 = (t1 >> 13) | (t2 << 38);
        t2 = (t2 >> 26) | (t3 << 25);
        t3 = (t3 >> 39) | (t4 << 12);

        BinaryPrimitives.WriteUInt64LittleEndian(output, t0);
        BinaryPrimitives.WriteUInt64LittleEndian(output[8..], t1);
        BinaryPrimitives.WriteUInt64LittleEndian(output[16..], t2);
        BinaryPrimitives.WriteUInt64LittleEndian(output[24..], t3);
    }

    private static void CarryPass(ref ulong t0, ref ulong t1, ref ulong t2, ref ulong t3, ref ulong t4)
    {
        t1 += t0 >> 51; t0 &= Mask51;
        t2 += t1 >> 51; t1 &= Mask51;
        t3 += t2 >> 51; t2 &= Mask51;
        t4 += t3 >> 51; t3 &= Mask51;
    }

    private static void CarryPassFull(ref ulong t0, ref ulong t1, ref ulong t2, ref ulong t3, ref ulong t4)
    {
        CarryPass(ref t0, ref t1, ref t2, ref t3, ref t4);
        t0 += 19 * (t4 >> 51);
        t4 &= Mask51;
    }

    private static void SwapConditional(ulong[] a, ulong[] b, ulong iswap)
    {
        var swap = 0UL - iswap;

        for (var i = 0; i < 5; i++)
        {
            var x = swap & (a[i] ^ b[i]);
            a[i] ^= x;
            b[i] ^= x;
        }
    }

    // Scratch space for one Montgomery ladder. Allocated once per ScalarMultiply instead of
    // once per ladder step: the ladder runs 256 steps, and eight throwaway arrays each would
    // put two thousand allocations per login on the game thread.
    private sealed class Scratch
    {
        public readonly ulong[] OrigX = new ulong[5];
        public readonly ulong[] OrigXPrime = new ulong[5];
        public readonly ulong[] ZZZ = new ulong[5];
        public readonly ulong[] XX = new ulong[5];
        public readonly ulong[] ZZ = new ulong[5];
        public readonly ulong[] XXPrime = new ulong[5];
        public readonly ulong[] ZZPrime = new ulong[5];
        public readonly ulong[] ZZZPrime = new ulong[5];
    }

    // One step of the Montgomery ladder: doubles Q and adds Q + Q'.
    private static void Monty(
        ulong[] x2, ulong[] z2,
        ulong[] x3, ulong[] z3,
        ulong[] x, ulong[] z,
        ulong[] xprime, ulong[] zprime,
        ulong[] qmqp,
        Scratch scratch
    )
    {
        var origx = scratch.OrigX;
        var origxprime = scratch.OrigXPrime;
        var zzz = scratch.ZZZ;
        var xx = scratch.XX;
        var zz = scratch.ZZ;
        var xxprime = scratch.XXPrime;
        var zzprime = scratch.ZZPrime;
        var zzzprime = scratch.ZZZPrime;

        Array.Copy(x, origx, 5);
        Sum(x, z);
        DifferenceBackwards(z, origx);

        Array.Copy(xprime, origxprime, 5);
        Sum(xprime, zprime);
        DifferenceBackwards(zprime, origxprime);
        Multiply(xxprime, xprime, z);
        Multiply(zzprime, x, zprime);
        Array.Copy(xxprime, origxprime, 5);
        Sum(xxprime, zzprime);
        DifferenceBackwards(zzprime, origxprime);
        SquareTimes(x3, xxprime, 1);
        SquareTimes(zzzprime, zzprime, 1);
        Multiply(z3, zzzprime, qmqp);

        SquareTimes(xx, x, 1);
        SquareTimes(zz, z, 1);
        Multiply(x2, xx, zz);
        DifferenceBackwards(zz, xx);
        ScalarProduct(zzz, zz, 121665);
        Sum(zzz, xx);
        Multiply(z2, zz, zzz);
    }

    private static void ScalarMultiplyInternal(ulong[] resultx, ulong[] resultz, ReadOnlySpan<byte> n, ulong[] q)
    {
        var nqpqx = new ulong[5];
        var nqpqz = new ulong[5];
        var nqx = new ulong[5];
        var nqz = new ulong[5];
        var nqpqx2 = new ulong[5];
        var nqpqz2 = new ulong[5];
        var nqx2 = new ulong[5];
        var nqz2 = new ulong[5];
        var scratch = new Scratch();

        Array.Copy(q, nqpqx, 5);
        nqpqz[0] = 1;
        nqx[0] = 1;
        // nqz stays zero: nq starts at the point at infinity.
        nqpqz2[0] = 1;
        nqz2[0] = 1;

        for (var i = 0; i < 32; i++)
        {
            var b = n[31 - i];

            for (var j = 0; j < 8; j++)
            {
                var bit = (ulong)(b >> 7);

                SwapConditional(nqx, nqpqx, bit);
                SwapConditional(nqz, nqpqz, bit);
                Monty(nqx2, nqz2, nqpqx2, nqpqz2, nqx, nqz, nqpqx, nqpqz, q, scratch);
                SwapConditional(nqx2, nqpqx2, bit);
                SwapConditional(nqz2, nqpqz2, bit);

                (nqx, nqx2) = (nqx2, nqx);
                (nqz, nqz2) = (nqz2, nqz);
                (nqpqx, nqpqx2) = (nqpqx2, nqpqx);
                (nqpqz, nqpqz2) = (nqpqz2, nqpqz);

                b <<= 1;
            }
        }

        Array.Copy(nqx, resultx, 5);
        Array.Copy(nqz, resultz, 5);
    }

    // out = z^(2^255 - 21), i.e. z^-1 by Fermat.
    private static void Reciprocal(ulong[] output, ulong[] z)
    {
        var a = new ulong[5];
        var t0 = new ulong[5];
        var b = new ulong[5];
        var c = new ulong[5];

        SquareTimes(a, z, 1);       // 2
        SquareTimes(t0, a, 2);      // 8
        Multiply(b, t0, z);         // 9
        Multiply(a, b, a);          // 11
        SquareTimes(t0, a, 1);      // 22
        Multiply(b, t0, b);         // 2^5 - 2^0
        SquareTimes(t0, b, 5);      // 2^10 - 2^5
        Multiply(b, t0, b);         // 2^10 - 2^0
        SquareTimes(t0, b, 10);     // 2^20 - 2^10
        Multiply(c, t0, b);         // 2^20 - 2^0
        SquareTimes(t0, c, 20);     // 2^40 - 2^20
        Multiply(t0, t0, c);        // 2^40 - 2^0
        SquareTimes(t0, t0, 10);    // 2^50 - 2^10
        Multiply(b, t0, b);         // 2^50 - 2^0
        SquareTimes(t0, b, 50);     // 2^100 - 2^50
        Multiply(c, t0, b);         // 2^100 - 2^0
        SquareTimes(t0, c, 100);    // 2^200 - 2^100
        Multiply(t0, t0, c);        // 2^200 - 2^0
        SquareTimes(t0, t0, 50);    // 2^250 - 2^50
        Multiply(t0, t0, b);        // 2^250 - 2^0
        SquareTimes(t0, t0, 5);     // 2^255 - 2^5
        Multiply(output, t0, a);    // 2^255 - 21
    }
}
