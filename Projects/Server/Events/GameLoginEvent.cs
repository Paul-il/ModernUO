using System;
using System.Runtime.CompilerServices;
using Server.Network;

namespace Server;

public class GameLoginEventArgs
{
    public GameLoginEventArgs(NetState state, string username, string password)
    {
        State = state;
        Username = username;
        Password = password;
    }

    public NetState State { get; }

    public string Username { get; }

    public string Password { get; }

    public bool Accepted { get; set; }

    public CityInfo[] CityInfo { get; set; }
}

public static partial class EventSink
{
    public static event Action<GameLoginEventArgs> GameLogin;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void InvokeGameLogin(GameLoginEventArgs e) => GameLogin?.Invoke(e);
}
