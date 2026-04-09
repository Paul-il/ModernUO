namespace Server.Misc;

public static class RenameRequests
{
    private static readonly string[] EmptyDisallowed = [];

    public static void Initialize()
    {
        EventSink.RenameRequest += EventSink_RenameRequest;
    }

    private static void EventSink_RenameRequest(Mobile from, Mobile targ, string name) => RenameRequest(from, targ, name);

    public static void RenameRequest(Mobile from, Mobile targ, string name)
    {
        if (!from.CanSee(targ) || !from.InRange(targ, 12) || !targ.CanBeRenamedBy(from))
        {
            return;
        }

        name = name.Trim();

        if (NameVerification.Validate(
                name,
                minLength: 1,
                maxLength: 16,
                allowLetters: true,
                allowDigits: false,
                noExceptionsAtStart: true,
                maxExceptions: 0,
                exceptions: null,
                disallowed: EmptyDisallowed,
                disallowedSV: null,
                startDisallowedSV: NameVerification.StartDisallowed
            ))
        {
            targ.Name = name;
        }
        else
        {
            from.SendMessage("That name is unacceptable.");
        }
    }
}
