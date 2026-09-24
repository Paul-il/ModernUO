using ModernUO.Serialization;
using Server.Accounting;
using Server.Network;

namespace Server.Items;

[SerializationGenerator(0, false)]
public partial class BankBox : Container
{
    [SerializableField(0, setter: "private")]
    private Mobile _owner;

    [SerializableField(1, setter: "private")]
    private bool _opened;

    public BankBox(Mobile owner) : base(0xE7C)
    {
        Layer = Layer.Bank;
        Movable = false;
        Owner = owner;
    }

    // Zuluhotel: the bank is limited by weight, not by the ModernUO 125-item default.
    public const int MaxBankWeight = 65000;

    // Not a gameplay limit: the container content packet (0x3C) has a ushort length and
    // 20 bytes per item, so it can list at most (65535 - 5) / 20 = 3276 items.
    public const int MaxBankItems = 3000;

    public override int DefaultMaxWeight => MaxBankWeight;

    public override int DefaultMaxItems => MaxBankItems;

    public override bool IsVirtualItem => true;

    public static bool SendDeleteOnClose { get; set; }

    // Hook that resolves the player's effective language preference (Options.Language-aware).
    // ZuluContent registers this at startup so the bank overhead respects the options gump,
    // not just the client-reported language. Falls back to Mobile.Language if unset.
    public static System.Func<Mobile, string> ResolveLanguage { get; set; }

    public void Open()
    {
        if (!ServerFeatureFlags.BankAccess && Owner?.AccessLevel < AccessLevel.Administrator)
        {
            Owner.SendMessage(0x22, "Bank access is temporarily disabled.");
            return;
        }

        Opened = true;

        if (Owner != null)
        {
            var lang = ResolveLanguage?.Invoke(Owner) ?? Owner.Language;
            var isRu = !string.IsNullOrEmpty(lang) &&
                       (lang.StartsWith("RUS", System.StringComparison.OrdinalIgnoreCase) ||
                        lang.Equals("RU", System.StringComparison.OrdinalIgnoreCase) ||
                        lang.StartsWith("UKR", System.StringComparison.OrdinalIgnoreCase) ||
                        lang.StartsWith("BEL", System.StringComparison.OrdinalIgnoreCase));

            var text = isRu
                ? $"В банке {TotalItems} предметов, {TotalWeight} из {MaxWeight} камней"
                : $"Bank container has {TotalItems} items, {TotalWeight} of {MaxWeight} stones";

            Owner.PrivateOverheadMessage(
                MessageType.Regular,
                0x3B2,
                false,
                text,
                Owner.NetState
            );

            Owner.NetState?.SendEquipUpdate(this);
            DisplayTo(Owner);
        }
    }

    [AfterDeserialization]
    private void AfterDeserialization()
    {
        if (Owner == null)
        {
            Timer.DelayCall(Delete);
        }
    }

    public void Close()
    {
        Opened = false;

        if (SendDeleteOnClose)
        {
            Owner?.NetState.SendRemoveEntity(Serial);
        }
    }

    public override void OnSingleClick(Mobile from)
    {
    }

    public override void OnDoubleClick(Mobile from)
    {
    }

    public override DeathMoveResult OnParentDeath(Mobile parent) => DeathMoveResult.RemainEquipped;

    public override bool IsAccessibleTo(Mobile check) =>
        (check == Owner && Opened || check.AccessLevel >= AccessLevel.GameMaster) && base.IsAccessibleTo(check);

    public override bool OnDragDrop(Mobile from, Item dropped) =>
        (from == Owner && Opened || from.AccessLevel >= AccessLevel.GameMaster) && base.OnDragDrop(from, dropped);

    public override bool OnDragDropInto(Mobile from, Item item, Point3D p) =>
        (from == Owner && Opened || from.AccessLevel >= AccessLevel.GameMaster) &&
        base.OnDragDropInto(from, item, p);

    public override bool CheckHold(Mobile m, Item item, bool message, bool checkItems, int plusItems, int plusWeight)
    {
        // This is a horrible hack.
        // TODO: Refactor this by moving BankBox out of the core.
        if (AccountGold.Enabled && AccountGold.ConvertOnBank && item.GetType().Name is "Gold" or "BankCheck")
        {
            return true;
        }

        return base.CheckHold(m, item, message, checkItems, plusItems, plusWeight);
    }

    public override int GetTotal(TotalType type)
    {
        if (AccountGold.Enabled && Owner?.Account != null && type == TotalType.Gold)
        {
            return Owner.Account.TotalGold;
        }

        return base.GetTotal(type);
    }
}
