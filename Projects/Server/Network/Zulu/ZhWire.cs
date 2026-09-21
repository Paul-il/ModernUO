// Zuluhotel wire protocol (ZHW) - shared.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\ZhWire.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_protocol.py.

using System;

namespace Zulu.Wire;

/// <summary>Fills a buffer with cryptographically random bytes.</summary>
public delegate void ZhRandomFill(Span<byte> buffer);

/// <summary>
/// Слой 2 протокола: перестановка опкодов, своя на каждое поколение сборки.
/// <para>
/// Шифр (слой 1) закрывает поток целиком, поэтому перестановка не добавляет секретности -
/// она добавляет ПРОТУХАНИЕ. Тот, кто один раз вытащил таблицу из клиента, теряет её на
/// следующем поколении: разовый реверс превращается в подписку на реверс. Сама таблица
/// живёт в <see cref="ZhWireTable"/>, её печатает scripts/wire_protocol.py.
/// </para>
/// <para>
/// ИНВАРИАНТ: отображение применяется РОВНО к первому байту пакета и ровно один раз,
/// на границе провода. Всё, что выше, - обработчики, таблица длин, логи - видит настоящий
/// идентификатор. Длина пакета всегда ищется по настоящему идентификатору, поэтому
/// перестановка может быть любой биекцией.
/// </para>
/// </summary>
public static class ZhWire
{
    /// <summary>
    /// Whether the wire protocol is in force. The server flips this from configuration at
    /// startup; the client leaves it on. When false, ZHW is inert and the opcode map is the
    /// identity, so a single config flag reverts the shard to the stock UO protocol without
    /// touching code - that is the emergency handle if the transport misbehaves in production.
    /// </summary>
    public static bool Enabled { get; set; }

    /// <summary>Build generation both ends must agree on.</summary>
    public static uint Generation => ZhWireTable.Generation;

    /// <summary>First four bytes of a client hello: how a ZHW peer is told from a legacy one.</summary>
    public static ReadOnlySpan<byte> Magic => ZhWireTable.Magic;

    /// <summary>
    /// Per-generation key. Baked into both binaries, so it is obfuscation-grade, not secret -
    /// it raises the price of writing a bot from "read the docs" to "reverse the client", and
    /// that price is charged again every generation.
    /// </summary>
    public static ReadOnlySpan<byte> BuildKey => ZhWireTable.BuildKey;

    /// <summary>
    /// Source of random bytes. Each side installs its own at startup so this file stays free of
    /// platform crypto, which the browser-wasm build of the client does not fully have.
    /// </summary>
    public static ZhRandomFill FillRandom { get; set; }

    /// <summary>Real packet id to the byte that travels the wire.</summary>
    public static byte MapOut(byte packetId) => Enabled ? ZhWireTable.Forward[packetId] : packetId;

    /// <summary>Byte off the wire back to the real packet id.</summary>
    public static byte MapIn(byte wireId) => Enabled ? ZhWireTable.Reverse[wireId] : wireId;

    internal static void Fill(Span<byte> buffer)
    {
        var fill = FillRandom ?? throw new InvalidOperationException(
            "ZhWire.FillRandom is not installed. The handshake cannot run without a random source."
        );

        fill(buffer);
    }
}
