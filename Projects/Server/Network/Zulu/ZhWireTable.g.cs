// Zuluhotel wire protocol (ZHW) - shared, GENERATED.
//
// НЕ ПРАВИТЬ РУКАМИ. Файл печатает scripts/wire_protocol.py, и копия в клиенте
// обязана быть байт в байт такой же.
//
// Поколение: 7
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
    public const uint Generation = 7;

    private static readonly byte[] _seed =
    {
        0xD0, 0x16, 0xC7, 0x4B, 0x59, 0x60, 0x75, 0x5B, 0x7A, 0xCE, 0xED, 0x9A, 0x05, 0x97, 0x3A, 0x22,
        0x4D, 0x28, 0xDF, 0x05, 0x33, 0x3B, 0x1B, 0x50, 0x2E, 0x17, 0xA2, 0x6F, 0x22, 0x99, 0xF7, 0x89
    };
}
