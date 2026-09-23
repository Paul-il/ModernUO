// Zuluhotel wire protocol (ZHW) - shared, GENERATED.
//
// НЕ ПРАВИТЬ РУКАМИ. Файл печатает scripts/wire_protocol.py, и копия в клиенте
// обязана быть байт в байт такой же.
//
// Поколение: 5
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
    public const uint Generation = 5;

    private static readonly byte[] _seed =
    {
        0xDA, 0x54, 0x79, 0x12, 0xCF, 0xFA, 0x79, 0x0C, 0x7B, 0x06, 0x60, 0x46, 0x2B, 0x2E, 0xFF, 0xFC,
        0x8B, 0xF0, 0x8C, 0xBF, 0x42, 0x55, 0x22, 0xE3, 0x39, 0x3C, 0x07, 0xB4, 0xB4, 0x5F, 0x01, 0x06
    };
}
