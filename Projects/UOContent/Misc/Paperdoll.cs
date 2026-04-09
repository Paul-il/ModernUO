using Server.Network;

namespace Server.Misc
{
    public static class Paperdoll
    {
        public static void Initialize()
        {
            EventSink.PaperdollRequest += EventSink_PaperdollRequest;
        }

        public static void EventSink_PaperdollRequest(Mobile beholder, Mobile beheld)
        {
            var state = beholder.NetState;
            if (state == null)
            {
                return;
            }

            state.SendDisplayPaperdoll(
                beheld.Serial,
                Titles.ComputeTitle(beholder, beheld),
                beheld.Warmode,
                beheld.AllowEquipFrom(beholder)
            );

            if (!ObjectPropertyList.Enabled)
            {
                return;
            }

            // Live shard pushes the full OPL payload for equipped items when the paperdoll opens,
            // so tooltips and cliloc-backed labels resolve immediately instead of waiting for hover/query.
            for (var i = 0; i < beheld.Items.Count; ++i)
            {
                var item = beheld.Items[i];
                if (item.Layer == Layer.Backpack || item.Layer == Layer.Bank)
                {
                    continue;
                }

                item.SendPropertiesTo(state);
            }

            // NOTE: OSI sends MobileUpdate when opening your own paperdoll.
            // It has a very bad rubber-banding affect. What positive affects does it have?
        }
    }
}
