/* Автор: Paul Gordon */

// ZHW, серверная половина. В клиент НЕ синхронизируется.
//
// Здесь живёт вся логика рукопожатия для одного соединения. В NetState.cs остаются
// только короткие зацепки, чтобы диff по движку читался, а не терялся.
//
// Порядок включения шифра (ошибиться легко, отлаживать больно):
//   читаем hello -> шлём ServerHello -> ВКЛЮЧАЕМ шифрование исходящего
//                -> читаем confirm   -> ВКЛЮЧАЕМ расшифровку входящего
// Confirm приходит ОТКРЫТЫМ текстом, поэтому расшифровка входящего включается строго
// после того, как он вычтен из буфера. Подробности формата - в ZhHandshake.

using System;
using Zulu.Wire;

namespace Server.Network;

public partial class NetState
{
    private ZhHandshake _zhHandshake;
    private ZhClientEncryption _zhEncryption;

    // Входящее расшифровывается и опкоды снимаются с провода. Ровно этот флаг означает
    // «внутри трубы уже обычный протокол UO».
    private bool _zhInbound;

    // Confirm разобран, но ещё не вычтен из буфера. Расшифровку включаем на следующем
    // витке разбора, когда хвост за confirm станет началом читаемого куска.
    private bool _zhPendingInbound;

    // Обратная перестановка пишется ОБРАТНО в приёмный буфер, а буфер при разорванном
    // пакете не сдвигается: разбор ломается на AwaitingPartialPacket (или Throttled) и
    // возвращается к тому же первому байту следующим приёмом. Без этого флага MapIn лёг
    // бы на уже снятый опкод второй раз, и пакет превратился бы в чужой. Снимается ровно
    // там, где буфер сдвигается, - после CommitRead.
    private bool _zhHeadMapped;

    /// <summary>
    /// Снимает перестановку с первого байта ровно один раз на пакет. Возвращает
    /// настоящий идентификатор - и когда снял сам, и когда он уже был снят до разрыва.
    /// </summary>
    private byte ZhUnmapHead(Span<byte> buffer, byte packetId)
    {
        if (_zhHeadMapped)
        {
            return packetId;
        }

        _zhHeadMapped = true;
        return buffer[0] = ZhWire.MapIn(packetId);
    }

    /// <summary>Шифруем ли мы исходящее и переставляем ли опкоды на выходе.</summary>
    private bool ZhOutbound => _zhEncryption != null;

    /// <summary>
    /// Разбирает client hello и отвечает server hello. С этого момента всё исходящее
    /// уходит шифрованным, входящее - ещё нет.
    /// </summary>
    private bool ZhAcceptHello(ReadOnlySpan<byte> buffer)
    {
        _zhHandshake = new ZhHandshake();

        Span<byte> serverHello = stackalloc byte[ZhHandshake.ServerHelloSize];
        var result = _zhHandshake.AcceptClientHello(buffer[..ZhHandshake.ClientHelloSize], serverHello);

        if (result != ZhHandshakeResult.Ok)
        {
            _zhHandshake = null;
            LogInfo($"ZHW: рукопожатие отклонено ({result})");
            return false;
        }

        // ServerHello уходит ОТКРЫТЫМ и до установки шифра: клиент ещё не вывел ключ.
        // Не уехал - значит клиент будет ждать его вечно, и честнее разорвать сразу.
        if (!SendRaw(serverHello))
        {
            _zhHandshake = null;
            LogInfo("ZHW: не удалось отправить ServerHello");
            return false;
        }

        _zhEncryption = new ZhClientEncryption(_zhHandshake.Session);
        _encryption = _zhEncryption;
        return true;
    }

    /// <summary>
    /// Проверяет confirm. До него собеседник доказал только знание ключа сборки; после -
    /// что вывел тот же сеансовый ключ, и переигранное чужое hello перестаёт что-либо стоить.
    /// </summary>
    private bool ZhAcceptConfirm(ReadOnlySpan<byte> buffer)
    {
        if (!_zhHandshake.VerifyClientConfirm(buffer[..ZhHandshake.ClientConfirmSize]))
        {
            LogInfo("ZHW: confirm не сошёлся");
            return false;
        }

        _zhHandshake = null;
        _zhPendingInbound = true;
        return true;
    }

    /// <summary>
    /// Включает расшифровку входящего и разом расшифровывает хвост, приехавший вместе
    /// с confirm. Вызывать ровно один раз и ровно перед первым разбором этого хвоста.
    /// </summary>
    private void ZhStartInbound(Span<byte> pending)
    {
        _zhPendingInbound = false;
        _zhInbound = true;
        _zhEncryption.StartInbound(pending);
    }

    /// <summary>
    /// Отшивает клиента, который не умеет ZHW. Ответить всё-таки надо: молчание выглядит
    /// для игрока как «сервер лежит», а 0x82 рисует понятную ошибку входа.
    /// </summary>
    private void ZhRejectLegacy()
    {
        SendRaw(stackalloc byte[] { 0x82, (byte)ALRReason.BadComm });
        Disconnect("ZHW: клиент без поддержки протокола");
    }

    /// <summary>
    /// Кладёт байты в сокет как есть: без сжатия, без перестановки опкодов и без шифра.
    /// Только для самого рукопожатия, которое по определению живёт до них всех.
    /// Возвращает false, если места в буфере не нашлось: молча потерять рукопожатие
    /// хуже, чем разорвать соединение.
    /// </summary>
    private bool SendRaw(ReadOnlySpan<byte> span)
    {
        if (span.Length == 0 || !GetSendBuffer(out var buffer) || buffer.Length < span.Length)
        {
            return false;
        }

        span.CopyTo(buffer);
        _socket.SendBuffer.CommitWrite(span.Length);

        if (!_flushQueued)
        {
            _flushPending.Enqueue(this);
            _flushQueued = true;
        }

        return true;
    }
}
