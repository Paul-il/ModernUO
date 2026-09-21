// Zuluhotel wire protocol (ZHW) - shared.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\ZhSession.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_protocol.py.

using System;

namespace Zulu.Wire;

/// <summary>
/// A live ZHW session: two independent ChaCha20 keystreams, one per direction.
/// <para>
/// Both sides must feed bytes through in the exact order they travel the socket - the cipher
/// is a stream, not a block transform. TCP already guarantees that ordering, which is why ZHW
/// has no per-packet framing of its own.
/// </para>
/// </summary>
public sealed class ZhSession
{
    private readonly ChaCha20 _clientToServer;
    private readonly ChaCha20 _serverToClient;

    internal ZhSession(ChaCha20 clientToServer, ChaCha20 serverToClient)
    {
        _clientToServer = clientToServer;
        _serverToClient = serverToClient;
    }

    /// <summary>Transforms bytes travelling client to server, in place.</summary>
    public void ClientToServer(Span<byte> buffer) => _clientToServer.Process(buffer);

    /// <summary>Transforms bytes travelling server to client, in place.</summary>
    public void ServerToClient(Span<byte> buffer) => _serverToClient.Process(buffer);
}
