// Zuluhotel wire protocol (ZHW) - shared.
//
// ЭТОТ ФАЙЛ ОБЩИЙ С КЛИЕНТОМ. Копия живёт в
//   C:\Games\client\TazUO-src\src\ClassicUO.Client\Network\Zulu\ZhWireDerive.cs
// и обязана быть байт в байт такой же. Синхронизация: python scripts/wire_protocol.py.
//
// ЗАЧЕМ ЭТОТ ФАЙЛ ЕСТЬ.
//
// Сначала поколение лежало в бинаре готовыми массивами: 4 байта Magic, 32 байта BuildKey
// и перестановка опкодов на 256 байт. Перестановку в файле видно невооружённым глазом -
// это единственный массив, в котором ровно 256 РАЗНЫХ байт, и такой находится сигнатурой
// за секунды, без всякого понимания кода. То есть смена поколения стоила стороннему
// инструменту один запуск извлекалки, и обещанное «протухание реверса» не работало.
//
// Теперь в бинаре лежит только зерно поколения - 32 байта, на вид неотличимые от любого
// другого мусора, - а Magic, BuildKey и обе таблицы РАЗВОРАЧИВАЮТСЯ из него на старте.
// Структурной приметы у зерна нет, поэтому добраться до него можно только через код
// разворота, то есть разобравшись в клиенте, а не грепом по файлу.
//
// В ПАМЯТИ таблицы тоже не лежат перестановкой: каждая хранится поксоренной со своей
// маской из того же зерна, маска снимается в момент обращения. Без этого весь выигрыш
// съедал бы дамп памяти - там перестановка нашлась бы по той же примете «256 разных
// байт». Цена - один лишний XOR на пакет.
//
// Чего это НЕ даёт: тот, кто разобрал клиент руками, достанет и зерно, и таблицы. Слой 2
// покупает не невозможность, а то, что работу придётся делать заново на КАЖДОМ поколении
// и делать её по коду, а не сигнатурой. Границы честно расписаны в ADR 0179 и 0180.

using System;

namespace Zulu.Wire;

internal static partial class ZhWireTable
{
    public const int MagicSize = 4;
    public const int BuildKeySize = 32;

    private const int MapSize = 256;

    // Первый байт Magic не должен совпадать с началом легитимного НЕ-ZHW потока, иначе
    // сервер не отличит опросчик списка шардов от клиента: 0xEF - сид, 0xF1 - freeshard
    // protocol, 0x80/0x91/0xA0 - вход. 0x00 исключён просто как слишком «пустой».
    // Сторожит ZhWireTests.Magic_НеНачинаетсяСЧужогоОпкода.
    private static readonly byte[] _reservedFirstBytes = { 0x00, 0x80, 0x91, 0xA0, 0xEF, 0xF1 };

    private static readonly byte[] _magic;
    private static readonly byte[] _buildKey;

    private static readonly byte[] _forwardMasked;
    private static readonly byte[] _forwardMask;
    private static readonly byte[] _reverseMasked;
    private static readonly byte[] _reverseMask;

    /// <summary>First four bytes of a client hello: how a ZHW peer is told from a legacy one.</summary>
    public static ReadOnlySpan<byte> Magic => _magic;

    /// <summary>Per-generation key mixed into the handshake tag.</summary>
    public static ReadOnlySpan<byte> BuildKey => _buildKey;

    /// <summary>Real packet id to the byte that travels the wire.</summary>
    public static byte Forward(byte packetId) => (byte)(_forwardMasked[packetId] ^ _forwardMask[packetId]);

    /// <summary>Byte off the wire back to the real packet id.</summary>
    public static byte Reverse(byte wireId) => (byte)(_reverseMasked[wireId] ^ _reverseMask[wireId]);

    // ЛОВУШКА НА БУДУЩЕЕ. Зерно приезжает инициализатором статического поля из другой
    // части этого partial-класса (ZhWireTable.g.cs). Язык гарантирует ровно одно: ВСЕ
    // инициализаторы статических полей отработают до тела статического конструктора.
    // Порядок инициализаторов МЕЖДУ частями partial-класса не определён, поэтому новое
    // статическое поле, читающее _seed в своём инициализаторе, получит null - молча, без
    // ошибки сборки. Всё, что зависит от зерна, живёт в теле конструктора ниже.
    static ZhWireTable()
    {
        var magic = new byte[MagicSize];
        var buildKey = new byte[BuildKeySize];
        var forward = new byte[MapSize];
        var reverse = new byte[MapSize];
        var forwardMask = new byte[MapSize];
        var reverseMask = new byte[MapSize];

        Derive(_seed, magic, buildKey, forward, reverse, forwardMask, reverseMask);

        for (var i = 0; i < MapSize; i++)
        {
            forward[i] ^= forwardMask[i];
            reverse[i] ^= reverseMask[i];
        }

        _magic = magic;
        _buildKey = buildKey;
        _forwardMasked = forward;
        _forwardMask = forwardMask;
        _reverseMasked = reverse;
        _reverseMask = reverseMask;
    }

    /// <summary>
    /// Expands a generation seed into every per-generation constant of the protocol.
    /// Internal so tests can drive it with seeds other than the compiled-in one.
    /// </summary>
    // ПОРЯДОК РАСХОДОВАНИЯ ПОТОКА - ЧАСТЬ ПРОТОКОЛА. Обе стороны разворачивают одно и то
    // же зерно и обязаны получить одно и то же, поэтому любая перестановка шагов ниже
    // меняет таблицу при ТОМ ЖЕ номере поколения - расхождение, которого по номеру не
    // видно. Менять порядок можно только вместе со сменой поколения, то есть вместе с
    // выкладкой клиента. Сторожит ZhWireTests.Разворот_ЗафиксированНаЭталонномЗерне: он
    // падает на любой правке этого метода, и падение значит «бампни поколение», а не
    // «почини тест». Отпечаток общих файлов в zhw-generation.txt ловит то же самое на
    // стороне выкладки.
    internal static void Derive(
        ReadOnlySpan<byte> seed,
        Span<byte> magic,
        Span<byte> buildKey,
        Span<byte> forward,
        Span<byte> reverse,
        Span<byte> forwardMask,
        Span<byte> reverseMask
    )
    {
        var stream = new SeedStream(seed);

        stream.Fill(magic);

        while (IsReservedFirstByte(magic[0]))
        {
            magic[0] = stream.Next();
        }

        stream.Fill(buildKey);

        for (var i = 0; i < MapSize; i++)
        {
            forward[i] = (byte)i;
        }

        // Перемешивание Фишера-Йетса. Байты, попавшие в смещённый хвост диапазона,
        // отбрасываем - иначе распределение перекосится в сторону младших индексов.
        for (var i = MapSize - 1; i > 0; i--)
        {
            var limit = i + 1;
            var bound = MapSize - MapSize % limit;

            int r;

            do
            {
                r = stream.Next();
            }
            while (r >= bound);

            var j = r % limit;
            (forward[i], forward[j]) = (forward[j], forward[i]);
        }

        for (var real = 0; real < MapSize; real++)
        {
            reverse[forward[real]] = (byte)real;
        }

        stream.Fill(forwardMask);
        stream.Fill(reverseMask);
    }

    private static bool IsReservedFirstByte(byte value)
    {
        for (var i = 0; i < _reservedFirstBytes.Length; i++)
        {
            if (_reservedFirstBytes[i] == value)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Deterministic byte stream expanded from the generation seed. ChaCha20 is already the
    /// only PRF in ZHW, so expansion adds no new primitive - and no new thing to get wrong.
    /// </summary>
    private sealed class SeedStream
    {
        private readonly ChaCha20 _cipher;
        private readonly byte[] _block = new byte[ChaCha20.BlockSize];

        // Сколько байт текущего блока уже роздано. BlockSize значит «блока нет».
        private int _offset = ChaCha20.BlockSize;

        public SeedStream(ReadOnlySpan<byte> seed)
        {
            Span<byte> nonce = stackalloc byte[ChaCha20.NonceSize];
            nonce.Clear();
            _cipher = new ChaCha20(seed, nonce);
        }

        public byte Next()
        {
            if (_offset == _block.Length)
            {
                _cipher.Keystream(_block);
                _offset = 0;
            }

            return _block[_offset++];
        }

        public void Fill(Span<byte> destination)
        {
            for (var i = 0; i < destination.Length; i++)
            {
                destination[i] = Next();
            }
        }
    }
}
