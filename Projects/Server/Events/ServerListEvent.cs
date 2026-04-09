using System;
using System.Collections.Generic;
using System.Net;
using System.Runtime.CompilerServices;
using Server.Accounting;
using Server.Network;

namespace Server;

public class ServerListEventArgs
{
    public ServerListEventArgs(NetState state, IAccount account)
    {
        State = state;
        Account = account;
        Servers = [];
    }

    public NetState State { get; }

    public IAccount Account { get; }

    public bool Rejected { get; set; }

    public List<ServerInfo> Servers { get; }

    public void AddServer(string name, IPEndPoint address) => AddServer(name, 0, TimeZoneInfo.Local, address);

    public void AddServer(string name, int fullPercent, TimeZoneInfo tz, IPEndPoint address) =>
        Servers.Add(new ServerInfo(name, fullPercent, tz, address));
}

public static partial class EventSink
{
    public static event Action<ServerListEventArgs> ServerList;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void InvokeServerList(ServerListEventArgs e) => ServerList?.Invoke(e);
}
