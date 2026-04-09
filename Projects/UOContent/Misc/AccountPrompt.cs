using System;
using System.Reflection;
using Server.Accounting;
using Server.Engines.CharacterCreation;
using Server.Logging;

namespace Server.Misc;

public static class AccountPrompt
{
    private static readonly ILogger logger = LogFactory.GetLogger(typeof(AccountPrompt));

    private static readonly bool AutoCreateDefaultOwnerAccount;
    private static readonly string DefaultOwnerAcctName;
    private static readonly string DefaultOwnerAcctPassword;
    private static readonly string DefaultOwnerPlayerName;

    static AccountPrompt()
    {
        AutoCreateDefaultOwnerAccount =
            ServerConfiguration.GetOrUpdateSetting("accountPrompt.autoCreateDefaultOwnerAccount", true);
        DefaultOwnerAcctName =
            ServerConfiguration.GetOrUpdateSetting("accountPrompt.defaultOwnerAcctName", "owner");
        DefaultOwnerAcctPassword =
            ServerConfiguration.GetOrUpdateSetting("accountPrompt.defaultOwnerAcctPassword", "owner");
        DefaultOwnerPlayerName =
            ServerConfiguration.GetOrUpdateSetting("accountPrompt.defaultOwnerPlayerName", "owner");
    }

    public static void Initialize()
    {
        if (Accounts.Count != 0)
        {
            return;
        }

        var key = ConsoleKey.D;
        if (!AutoCreateDefaultOwnerAccount)
        {
            logger.Warning("This server has no accounts.");
            logger.Information("Do you want to create the owner account now? (y/n), or create the default owner account? (d)");

            var answer = ConsoleInputHandler.ReadLine();
            key = answer.InsensitiveEquals("y") ? ConsoleKey.Y :
                answer.InsensitiveEquals("d") ? ConsoleKey.D :
                ConsoleKey.N;
        }

        switch (key)
        {
            case ConsoleKey.Y:
                CreateOwnerAccount();
                break;
            case ConsoleKey.D:
                CreateDefaultOwnerAccount();
                break;
            default:
                logger.Warning("No owner account created.");
                break;
        }
    }

    private static void CreateOwnerAccount()
    {
        logger.Information("Input Username:");
        var username = ConsoleInputHandler.ReadLine();

        logger.Information("Input Password:");
        var password = ConsoleInputHandler.ReadLine();

        var account = new Account(username, password)
        {
            AccessLevel = AccessLevel.Owner
        };

        ServerAccess.AddProtectedAccount(account, true);
        logger.Information("Owner account created: {Username}", username);
    }

    private static void CreateDefaultOwnerAccount()
    {
        var account = new Account(DefaultOwnerAcctName, DefaultOwnerAcctPassword)
        {
            AccessLevel = AccessLevel.Owner
        };

        ServerAccess.AddProtectedAccount(account, true);

        var cities = TryGetExternalStartingCities() ?? CharacterCreation.GetStartingCities();
        var city = cities.Length > 0 ? Utility.RandomList(cities) : default;

        var args = new CharacterCreatedEventArgs(
            null,
            account,
            DefaultOwnerPlayerName,
            false,
            Race.Human.RandomSkinHue(),
            [130, 130, 130],
            city,
            [(SkillName.Alchemy, (byte)0), (SkillName.Anatomy, (byte)0), (SkillName.Archery, (byte)0)],
            Utility.RandomDyedHue(),
            Utility.RandomDyedHue(),
            Race.Human.RandomHair(false),
            Race.Human.RandomHairHue(),
            Race.Human.RandomFacialHair(false),
            Race.Human.RandomHairHue(),
            0,
            Race.Human
        );

        if (!TryInvokeExternalCharacterCreation(args))
        {
            logger.Warning("Default owner account created without starting character because no external character creation handler accepted the request.");
        }

        logger.Information(
            "Default owner account created ({Username} / {Password}).",
            DefaultOwnerAcctName,
            DefaultOwnerAcctPassword
        );
    }

    private static CityInfo[] TryGetExternalStartingCities()
    {
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            var name = assembly.GetName().Name;
            if (string.Equals(name, "UOContent", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var accountHandlerType = assembly.GetType("Server.Misc.AccountHandler", throwOnError: false);
            var field = accountHandlerType?.GetField(
                "StartingCities",
                BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static
            );

            if (field?.GetValue(null) is CityInfo[] cities && cities.Length > 0)
            {
                return cities;
            }

            var characterCreationType = assembly.GetType("Server.Misc.CharacterCreation", throwOnError: false);
            var getter = characterCreationType?.GetMethod(
                "GetStartingCities",
                BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static,
                null,
                Type.EmptyTypes,
                null
            );

            if (getter?.Invoke(null, null) is CityInfo[] externalCities && externalCities.Length > 0)
            {
                return externalCities;
            }
        }

        return null;
    }

    private static bool TryInvokeExternalCharacterCreation(CharacterCreatedEventArgs args)
    {
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            var name = assembly.GetName().Name;
            if (string.Equals(name, "UOContent", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var type = assembly.GetType("Server.Misc.CharacterCreation", throwOnError: false);
            var method = type?.GetMethod(
                "HandleCharacterCreation",
                BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static,
                null,
                [typeof(CharacterCreatedEventArgs)],
                null
            );

            if (method == null)
            {
                continue;
            }

            try
            {
                method.Invoke(null, [args]);
                return true;
            }
            catch (TargetInvocationException ex)
            {
                logger.Warning(ex.InnerException ?? ex, "External character creation failed during default owner setup.");
                return false;
            }
            catch (Exception ex)
            {
                logger.Warning(ex, "External character creation failed during default owner setup.");
                return false;
            }
        }

        return false;
    }
}
