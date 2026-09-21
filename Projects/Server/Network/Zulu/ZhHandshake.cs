// Zuluhotel wire protocol (ZHW) - shared.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\ZhHandshake.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_protocol.py.
//
// Формат на проводе (всё, что до шифра, идёт открытым текстом и имеет
// ФИКСИРОВАННУЮ длину - на этом держится граница «где кончается рукопожатие»):
//
//   ClientHello, 72 байта
//     [0..3]    Magic поколения
//     [4..7]    Generation, big-endian
//     [8..39]   эфемерный публичный ключ клиента (X25519)
//     [40..55]  случайный клиентский нонс
//     [56..71]  Poly1305 по [0..55] на ключе из BuildKey
//
//   ServerHello, 56 байт
//     [0..31]   эфемерный публичный ключ сервера (X25519)
//     [32..39]  случайный серверный нонс
//     [40..55]  Poly1305 по (ClientHello || ServerHello[0..39]) на ключе из ECDH
//
//   ClientConfirm, 16 байт
//     Poly1305 по (ClientHello || ServerHello) на отдельном ключе из ECDH
//
// Дальше байт в байт - шифрованный поток, внутри которого живёт обычный протокол UO
// с переставленными опкодами.
//
// Порядок включения шифра (важен, легко ошибиться):
//   клиент: шлёт hello -> читает ServerHello -> ВКЛЮЧАЕТ расшифровку входящего
//           -> шлёт confirm -> ВКЛЮЧАЕТ шифрование исходящего
//   сервер: читает hello -> шлёт ServerHello -> ВКЛЮЧАЕТ шифрование исходящего
//           -> читает confirm -> ВКЛЮЧАЕТ расшифровку входящего
// Confirm приходит ОТКРЫТЫМ текстом: сервер обязан прочитать его до включения
// расшифровки, иначе первые 16 байт будут расшифрованы дважды.

using System;
using System.Buffers.Binary;

namespace Zulu.Wire;

public enum ZhHandshakeResult
{
    Ok,
    BadMagic,
    BadGeneration,
    BadTag,
    BadKeyExchange
}

/// <summary>
/// One connection's ZHW handshake. A single instance drives one side of one connection and
/// then holds the resulting <see cref="Session"/>.
/// </summary>
public sealed class ZhHandshake
{
    public const int ClientHelloSize = 72;
    public const int ServerHelloSize = 56;
    public const int ClientConfirmSize = 16;

    private const int MagicOffset = 0;
    private const int GenerationOffset = 4;
    private const int ClientKeyOffset = 8;
    private const int ClientNonceOffset = 40;
    private const int ClientNonceSize = 16;
    private const int ClientHelloTagOffset = 56;

    private const int ServerKeyOffset = 0;
    private const int ServerNonceOffset = 32;
    private const int ServerNonceSize = 8;
    private const int ServerHelloTagOffset = 40;

    private const int TranscriptSize = ClientHelloSize + ServerHelloSize;
    private const int ServerHelloSignedSize = ClientHelloSize + ServerHelloTagOffset;

    private readonly byte[] _transcript = new byte[TranscriptSize];
    private readonly byte[] _privateKey = new byte[X25519.KeySize];
    private readonly byte[] _confirmKey = new byte[Poly1305.KeySize];

    private bool _keysDerived;

    /// <summary>The live session, available once this side has derived the shared key.</summary>
    public ZhSession Session { get; private set; }

    // ------------------------------------------------------------------ client side

    /// <summary>
    /// Generates an ephemeral key pair and writes the client hello. Destination must be
    /// exactly <see cref="ClientHelloSize"/> bytes.
    /// </summary>
    public void WriteClientHello(Span<byte> destination)
    {
        if (destination.Length != ClientHelloSize)
        {
            throw new ArgumentException($"Client hello must be {ClientHelloSize} bytes", nameof(destination));
        }

        ZhWire.Fill(_privateKey);

        ZhWire.Magic.CopyTo(destination[MagicOffset..]);
        BinaryPrimitives.WriteUInt32BigEndian(destination[GenerationOffset..], ZhWire.Generation);
        X25519.GetPublicKey(_privateKey, destination.Slice(ClientKeyOffset, X25519.KeySize));
        ZhWire.Fill(destination.Slice(ClientNonceOffset, ClientNonceSize));

        Span<byte> tagKey = stackalloc byte[Poly1305.KeySize];
        DeriveHelloTagKey(destination.Slice(ClientNonceOffset, ClientNonceSize), tagKey);
        Poly1305.ComputeTag(tagKey, destination[..ClientHelloTagOffset], destination.Slice(ClientHelloTagOffset, Poly1305.TagSize));

        destination.CopyTo(_transcript);
    }

    /// <summary>
    /// Verifies the server hello, derives the session and produces the confirm tag the client
    /// must send back. Call only after <see cref="WriteClientHello"/>.
    /// </summary>
    public ZhHandshakeResult ReadServerHello(ReadOnlySpan<byte> serverHello, Span<byte> confirm)
    {
        if (serverHello.Length != ServerHelloSize || confirm.Length != ClientConfirmSize)
        {
            return ZhHandshakeResult.BadTag;
        }

        serverHello.CopyTo(_transcript.AsSpan(ClientHelloSize));

        Span<byte> handshakeKey = stackalloc byte[Poly1305.KeySize];
        if (!DeriveKeys(serverHello.Slice(ServerKeyOffset, X25519.KeySize), handshakeKey))
        {
            return ZhHandshakeResult.BadKeyExchange;
        }

        var signed = _transcript.AsSpan(0, ServerHelloSignedSize);
        var tag = serverHello.Slice(ServerHelloTagOffset, Poly1305.TagSize);

        if (!Poly1305.VerifyTag(handshakeKey, signed, tag))
        {
            return ZhHandshakeResult.BadTag;
        }

        Poly1305.ComputeTag(_confirmKey, _transcript, confirm);
        return ZhHandshakeResult.Ok;
    }

    // ------------------------------------------------------------------ server side

    /// <summary>
    /// Validates a client hello, derives the session and writes the server hello.
    /// Destination must be exactly <see cref="ServerHelloSize"/> bytes.
    /// </summary>
    public ZhHandshakeResult AcceptClientHello(ReadOnlySpan<byte> clientHello, Span<byte> destination)
    {
        if (clientHello.Length != ClientHelloSize || destination.Length != ServerHelloSize)
        {
            return ZhHandshakeResult.BadTag;
        }

        if (!clientHello[MagicOffset..(MagicOffset + 4)].SequenceEqual(ZhWire.Magic))
        {
            return ZhHandshakeResult.BadMagic;
        }

        if (BinaryPrimitives.ReadUInt32BigEndian(clientHello[GenerationOffset..]) != ZhWire.Generation)
        {
            return ZhHandshakeResult.BadGeneration;
        }

        Span<byte> tagKey = stackalloc byte[Poly1305.KeySize];
        DeriveHelloTagKey(clientHello.Slice(ClientNonceOffset, ClientNonceSize), tagKey);

        if (!Poly1305.VerifyTag(tagKey, clientHello[..ClientHelloTagOffset], clientHello.Slice(ClientHelloTagOffset, Poly1305.TagSize)))
        {
            return ZhHandshakeResult.BadTag;
        }

        clientHello.CopyTo(_transcript);

        ZhWire.Fill(_privateKey);
        X25519.GetPublicKey(_privateKey, destination.Slice(ServerKeyOffset, X25519.KeySize));
        ZhWire.Fill(destination.Slice(ServerNonceOffset, ServerNonceSize));

        // The transcript must hold the server hello before the tag is computed over it.
        destination.CopyTo(_transcript.AsSpan(ClientHelloSize));

        Span<byte> handshakeKey = stackalloc byte[Poly1305.KeySize];
        if (!DeriveKeys(clientHello.Slice(ClientKeyOffset, X25519.KeySize), handshakeKey))
        {
            return ZhHandshakeResult.BadKeyExchange;
        }

        var signed = _transcript.AsSpan(0, ServerHelloSignedSize);
        Poly1305.ComputeTag(handshakeKey, signed, destination.Slice(ServerHelloTagOffset, Poly1305.TagSize));

        // Keep the transcript in sync with the tag we just wrote, so the confirm check below
        // authenticates the exact bytes that went out.
        destination.CopyTo(_transcript.AsSpan(ClientHelloSize));

        return ZhHandshakeResult.Ok;
    }

    /// <summary>
    /// Checks the client's confirm tag. Until this passes, the peer has only proved it knows
    /// the build key; afterwards it has proved it derived the same session key, which is what
    /// makes a replayed hello useless.
    /// </summary>
    public bool VerifyClientConfirm(ReadOnlySpan<byte> confirm) =>
        confirm.Length == ClientConfirmSize && _keysDerived && Poly1305.VerifyTag(_confirmKey, _transcript, confirm);

    // ------------------------------------------------------------------ key schedule

    // The hello tag proves knowledge of the per-generation build key. Nothing here is secret
    // from someone holding the client binary, and it is not meant to be: it is the toll gate
    // that has to be paid again on every generation.
    private static void DeriveHelloTagKey(ReadOnlySpan<byte> clientNonce, Span<byte> tagKey) =>
        ChaCha20.Derive(ZhWire.BuildKey, clientNonce[..ChaCha20.NonceSize], 0, tagKey);

    private bool DeriveKeys(ReadOnlySpan<byte> peerPublicKey, Span<byte> handshakeKey)
    {
        Span<byte> shared = stackalloc byte[X25519.KeySize];

        if (!X25519.TryAgree(_privateKey, peerPublicKey, shared))
        {
            return false;
        }

        // Nonce for the key schedule: server nonce first, then the head of the client nonce.
        // Both ends build it from the transcript, so neither side alone picks the whole thing.
        Span<byte> nonce = stackalloc byte[ChaCha20.NonceSize];
        _transcript.AsSpan(ClientHelloSize + ServerNonceOffset, ServerNonceSize).CopyTo(nonce);
        _transcript.AsSpan(ClientNonceOffset, 4).CopyTo(nonce[ServerNonceSize..]);

        Span<byte> block0 = stackalloc byte[ChaCha20.BlockSize];
        Span<byte> block1 = stackalloc byte[ChaCha20.BlockSize];
        ChaCha20.Derive(shared, nonce, 0, block0);
        ChaCha20.Derive(shared, nonce, 1, block1);

        var clientToServer = new ChaCha20(block0[..32], block1[..ChaCha20.NonceSize]);
        var serverToClient = new ChaCha20(block0[32..64], block1.Slice(ChaCha20.NonceSize, ChaCha20.NonceSize));

        block1.Slice(24, Poly1305.KeySize).CopyTo(handshakeKey);
        ChaCha20.Derive(shared, nonce, 2, _confirmKey);

        Session = new ZhSession(clientToServer, serverToClient);
        _keysDerived = true;
        return true;
    }
}
