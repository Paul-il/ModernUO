/* Автор: Paul Gordon */

// ZHW, серверная половина. В клиент НЕ синхронизируется.

using System.Security.Cryptography;
using Server.Logging;
using Zulu.Wire;

namespace Server.Network;

public enum ZhProtocolMode
{
    /// <summary>Обычный протокол UO. ZHW инертен, перестановка опкодов - тождественная.</summary>
    Off,

    /// <summary>Каждое игровое соединение обязано начинаться с рукопожатия ZHW.</summary>
    Required
}

/// <summary>
/// Единственная точка, где решается, живёт ли шард на своём протоколе.
/// <para>
/// По умолчанию ВЫКЛЮЧЕНО. Включение запирает шард для всех клиентов, кроме собранных
/// с тем же поколением таблицы, поэтому флаг переводит оператор - и одновременно с
/// выкладкой клиента, не раньше. Обратный перевод в Off не требует пересборки: это и
/// есть аварийная ручка, если транспорт поведёт себя плохо на проде.
/// </para>
/// </summary>
public static class ZhWireConfig
{
    private static readonly ILogger logger = LogFactory.GetLogger(typeof(ZhWireConfig));

    public static ZhProtocolMode Mode { get; private set; }

    public static void Configure()
    {
        // Источник случайного ставим всегда: сам файл протокола общий с клиентом и не
        // имеет права знать про платформенную крипту, которой в browser-wasm нет.
        ZhWire.FillRandom = RandomNumberGenerator.Fill;

        Mode = ServerConfiguration.GetOrUpdateSetting("network.zhProtocol", ZhProtocolMode.Off);
        ZhWire.Enabled = Mode == ZhProtocolMode.Required;

        if (ZhWire.Enabled)
        {
            logger.Information("ZHW включён, поколение {Generation}", ZhWire.Generation);
        }
        else
        {
            logger.Information("ZHW выключен, шард слушает обычный протокол UO");
        }
    }
}
