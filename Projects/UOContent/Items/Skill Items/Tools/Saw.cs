using ModernUO.Serialization;
using Server.Engines.Craft;
using Server.Gumps;
using Server.Targeting;

namespace Server.Items;

[Flippable(0x1034, 0x1035)]
[SerializationGenerator(0, false)]
public partial class Saw : BaseTool
{
    [Constructible]
    public Saw() : base(0x1034)
    {
    }

    [Constructible]
    public Saw(int uses) : base(uses, 0x1034)
    {
    }

    public override double DefaultWeight => 2.0;

    public override CraftSystem CraftSystem => DefCarpentry.CraftSystem;

    public override void OnDoubleClick(Mobile from)
    {
        if (!IsChildOf(from.Backpack) && Parent != from)
        {
            from.SendLocalizedMessage(1042001); // That must be in your pack for you to use it.
            return;
        }

        from.SendMessage("Select logs to work with.");
        from.Target = new InternalTarget(this);
    }

    private class InternalTarget : Target
    {
        private readonly Saw _tool;

        public InternalTarget(Saw tool) : base(2, false, TargetFlags.None)
        {
            _tool = tool;
        }

        protected override void OnTarget(Mobile from, object targeted)
        {
            if (_tool.Deleted)
            {
                return;
            }

            if (!_tool.IsChildOf(from.Backpack) && _tool.Parent != from)
            {
                from.SendLocalizedMessage(1042001); // That must be in your pack for you to use it.
                return;
            }

            if (targeted is Item item && item.IsChildOf(from.Backpack) && IsLog(item))
            {
                var system = _tool.CraftSystem;
                var num = system.CanCraft(from, _tool, null);

                if (num > 0 && (num != 1044267 || !Core.SE))
                {
                    from.SendLocalizedMessage(num);
                }
                else
                {
                    from.SendGump(new CraftGump(from, system, _tool, null));
                }
            }
            else
            {
                from.SendMessage("You must target logs in your backpack.");
            }
        }

        private static bool IsLog(Item item)
        {
            var t = item.GetType();
            while (t != null && t != typeof(object))
            {
                var n = t.Name;
                if (n == "Log" || n == "BaseLog")
                {
                    return true;
                }
                t = t.BaseType;
            }
            return false;
        }
    }
}
