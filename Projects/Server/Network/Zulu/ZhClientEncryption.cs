/* Автор: Paul Gordon */

// ZHW, серверная половина. В клиент НЕ синхронизируется: это переходник к движку,
// а не часть протокола.

using System;
using Zulu.Wire;

namespace Server.Network;

/// <summary>
/// Переходник от <see cref="ZhSession"/> к контракту движка «шифруем на месте».
/// <para>
/// Направления включаются в РАЗНОЕ время, и это не прихоть: сервер начинает шифровать
/// исходящее сразу после ServerHello, а расшифровывать входящее - только после confirm,
/// потому что сам confirm приходит открытым текстом. Один общий флаг здесь дал бы либо
/// открытый ServerHello-ответ, либо confirm, расшифрованный дважды.
/// </para>
/// </summary>
internal sealed class ZhClientEncryption : IClientEncryption
{
    private readonly ZhSession _session;

    public ZhClientEncryption(ZhSession session) => _session = session;

    /// <summary>Включена ли расшифровка входящего потока.</summary>
    public bool InboundActive { get; private set; }

    /// <summary>
    /// Включает расшифровку входящего и разом расшифровывает хвост, приехавший в одном
    /// куске с confirm. Хвост обязан пройти через шифр ровно один раз и ровно здесь:
    /// движок расшифровывает только то, что пришло ПОСЛЕ установки шифра.
    /// </summary>
    public void StartInbound(Span<byte> pending)
    {
        if (InboundActive)
        {
            return;
        }

        InboundActive = true;
        _session.ClientToServer(pending);
    }

    public void ClientDecrypt(Span<byte> buffer)
    {
        if (InboundActive)
        {
            _session.ClientToServer(buffer);
        }
    }

    public void ServerEncrypt(Span<byte> buffer) => _session.ServerToClient(buffer);
}
