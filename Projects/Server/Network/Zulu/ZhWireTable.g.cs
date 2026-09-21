// Zuluhotel wire protocol (ZHW) - shared, GENERATED.
//
// НЕ ПРАВИТЬ РУКАМИ. Файл печатает scripts/wire_protocol.py, и копия в клиенте
// обязана быть байт в байт такой же.
//
// Поколение: 4
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
    public const uint Generation = 4;

    private static readonly byte[] _seed =
    {
        0x8B, 0x31, 0xEE, 0x94, 0x15, 0xE4, 0x66, 0x85, 0x7E, 0x10, 0x57, 0xA5, 0x55, 0x4F, 0x5D, 0xD6,
        0xC6, 0x05, 0x62, 0xE0, 0xFD, 0x56, 0x39, 0x3F, 0xC0, 0x79, 0x08, 0x67, 0x98, 0x09, 0xBE, 0x7F
    };
}
