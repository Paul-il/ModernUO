using System;
using System.IO;

namespace Server;

public static class DeserializeCompatibilityScope
{
    [ThreadStatic]
    private static long? _entryEnd;

    public static IDisposable PushEntryBounds(long entryStart, long entryLength)
    {
        var previous = _entryEnd;
        _entryEnd = entryStart + entryLength;
        return new Scope(previous);
    }

    public static bool CanRead(IGenericReader reader, int byteCount)
    {
        if (byteCount <= 0 || _entryEnd is not long entryEnd)
        {
            return true;
        }

        var position = reader.Seek(0, SeekOrigin.Current);
        return position + byteCount <= entryEnd;
    }

    private readonly struct Scope : IDisposable
    {
        private readonly long? _previous;

        public Scope(long? previous)
        {
            _previous = previous;
        }

        public void Dispose()
        {
            _entryEnd = _previous;
        }
    }
}
