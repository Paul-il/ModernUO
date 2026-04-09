using Server;

namespace Server.Engines.Spawners;

public abstract partial class BaseSpawner
{
    protected BaseSpawner(Serial serial) : base(serial)
    {
    }
}

[TypeAlias("Spawner", "Server.Engines.Spawners.Spawner")]
public partial class Spawner
{
    public Spawner(Serial serial) : base(serial)
    {
    }
}
