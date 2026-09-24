// Zuluhotel wire protocol (ZHW) - shared, GENERATED.
//
// НЕ ПРАВИТЬ РУКАМИ. Файл печатает scripts/wire_protocol.py, и копия в клиенте
// обязана быть байт в байт такой же.
//
// Поколение: 6
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
    public const uint Generation = 6;

    private static readonly byte[] _seed =
    {
        0xC4, 0x89, 0xAC, 0x96, 0x20, 0x32, 0x46, 0x1E, 0x42, 0xD6, 0x1D, 0xD5, 0xA6, 0x0B, 0x1B, 0x07,
        0x17, 0x35, 0x83, 0xD6, 0xD0, 0x66, 0x91, 0x60, 0x3D, 0x22, 0x12, 0xAB, 0x4E, 0xA8, 0x08, 0x1B
    };
}
