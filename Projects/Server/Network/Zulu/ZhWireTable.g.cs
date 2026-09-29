// Zuluhotel wire protocol (ZHW) - shared, GENERATED.
//
// НЕ ПРАВИТЬ РУКАМИ. Файл печатает scripts/wire_protocol.py, и копия в клиенте
// обязана быть байт в байт такой же.
//
// Поколение: 8
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
    public const uint Generation = 8;

    private static readonly byte[] _seed =
    {
        0x8A, 0x56, 0x09, 0x47, 0xB2, 0x80, 0x6E, 0xA1, 0xAD, 0x37, 0xB0, 0x15, 0xE8, 0x8B, 0x22, 0x47,
        0x5F, 0xFA, 0x48, 0x3A, 0xFD, 0x88, 0x8F, 0x4F, 0xB4, 0x2A, 0x86, 0x0E, 0xE1, 0x5C, 0xD8, 0x14
    };
}
