// Zuluhotel wire protocol (ZHW) - shared, GENERATED.
//
// НЕ ПРАВИТЬ РУКАМИ. Файл печатает scripts/wire_protocol.py, и копия в клиенте
// обязана быть байт в байт такой же.
//
// Поколение: 9
//
// Здесь лежит ТОЛЬКО зерно. Magic, BuildKey и обе таблицы опкодов разворачиваются из
// него на старте - как и зачем, расписано в ZhWireDerive.cs. Готовых таблиц в бинаре
// нет намеренно: перестановку на 256 разных байт видно в файле сигнатурой, а зерно от
// любого другого мусора не отличается.
//
// Зерно случайное и невоспроизводимое по номеру поколения. Старое поколение достаётся
// не пересчётом, а из истории git по этому файлу.

namespace Zulu.Wire;

internal static partial class ZhWireTable
{
    public const uint Generation = 9;

    private static readonly byte[] _seed =
    {
        0x88, 0x72, 0xB9, 0x4D, 0x05, 0x0E, 0xCF, 0xD0, 0xAC, 0xB4, 0x10, 0x77, 0x4D, 0x5E, 0x31, 0x8E,
        0x6B, 0xCB, 0x81, 0x77, 0xBD, 0x3C, 0x4C, 0x31, 0x54, 0x52, 0x51, 0xE4, 0xCF, 0xFC, 0xD9, 0x4F
    };
}
