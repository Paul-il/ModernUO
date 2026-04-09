using System;
using System.Runtime.CompilerServices;
using Server.Network;

namespace Server;

public static partial class EventSink
{
    public static event Action<NetState, int> DeleteRequest;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void InvokeDeleteRequest(NetState state, int index) => DeleteRequest?.Invoke(state, index);
}
