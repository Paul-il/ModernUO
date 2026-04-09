/*************************************************************************
 * ModernUO                                                              *
 * Copyright 2019-2026 - ModernUO Development Team                       *
 * Email: hi@modernuo.com                                                *
 * File: RegionJsonSerializer.cs                                         *
 *                                                                       *
 * This program is free software: you can redistribute it and/or modify  *
 * it under the terms of the GNU General Public License as published by  *
 * the Free Software Foundation, either version 3 of the License, or     *
 * (at your option) any later version.                                   *
 *                                                                       *
 * You should have received a copy of the GNU General Public License     *
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *
 *************************************************************************/

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Server.Json;
using Server.Logging;

namespace Server;

public static class RegionJsonSerializer
{
    private static readonly ILogger logger = LogFactory.GetLogger(typeof(RegionJsonSerializer));

    private static JsonDerivedType[] _derivedTypes = { new(typeof(Region), nameof(Region)) };

    public static IJsonTypeInfoResolver RegionJsonTypeInfoResolver => new DefaultJsonTypeInfoResolver()
    {
        Modifiers =
        {
            static typeInfo =>
            {
                if (typeInfo.Type != typeof(Region))
                {
                    return;
                }

                typeInfo.PolymorphismOptions = new JsonPolymorphismOptions();
                for (var i = 0; i < _derivedTypes.Length; i++)
                {
                    typeInfo.PolymorphismOptions.DerivedTypes.Add(_derivedTypes[i]);
                }
            },
            static typeInfo =>
            {
                if (!typeInfo.Type.IsAssignableTo(typeof(Region)))
                {
                    return;
                }

                typeInfo.OnDeserialized = o =>
                {
                    if (o is Region region && Core.Expansion >= region.MinExpansion && Core.Expansion <= region.MaxExpansion)
                    {
                        // Set the child level since it is not part of the JSON data, and our constructor skips setting parent.
                        if (region.Parent != null)
                        {
                            region.ChildLevel = region.Parent.ChildLevel + 1;
                        }
                        region.Register();
                    }
                };
            }
        }
    };

    private static JsonSerializerOptions _options = new(JsonConfig.DefaultOptions)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingDefault,
        TypeInfoResolver = RegionJsonTypeInfoResolver,
    };

    public static void Register<TRegion>() where TRegion : Region
    {
        for (var i = 0; i < _derivedTypes.Length; i++)
        {
            if (_derivedTypes[i].DerivedType == typeof(TRegion))
            {
                throw new Exception(
                    $"Type '{typeof(TRegion)}' has already been registered for serialization with the region loader."
                );
            }
        }

        Array.Resize(ref _derivedTypes, _derivedTypes.Length + 1);
        _derivedTypes[^1] = new JsonDerivedType(typeof(TRegion), typeof(TRegion).Name);
    }

    internal static void LoadRegions()
    {
        var path = Path.Join(Core.BaseDirectory, "Data/regions.json");

        var failures = new List<string>();
        var count = 0;

        logger.Information("Loading regions");

        var stopwatch = Stopwatch.StartNew();
        var regions = JsonConfig.Deserialize<List<DynamicJson>>(path);
        if (regions == null)
        {
            throw new JsonException($"Failed to deserialize {path}.");
        }

        foreach (var json in regions)
        {
            var type = AssemblyHandler.FindTypeByName(json.Type);

            if (type == null || !typeof(Region).IsAssignableFrom(type))
            {
                failures.Add($"\tInvalid region type {json.Type}");
                continue;
            }

            var region = type.CreateInstance<Region>(json, JsonConfig.DefaultOptions);
            if (region == null)
            {
                failures.Add($"\tFailed creating region type {json.Type}");
                continue;
            }

            if (Core.Expansion >= region.MinExpansion && Core.Expansion <= region.MaxExpansion)
            {
                region.Register();
                count++;
            }
        }

        stopwatch.Stop();

        if (failures.Count == 0)
        {
            logger.Information(
                "Loading regions {Status} ({Count} regions, {Failures} failures) ({Duration:F2} seconds)",
                "done",
                count,
                failures.Count,
                stopwatch.Elapsed.TotalSeconds
            );
        }
        else
        {
            logger.Warning(
                "Loading regions {Status} ({Count} regions, {Failures} failures) ({Duration:F2} seconds)",
                "completed with warnings",
                count,
                failures.Count,
                stopwatch.Elapsed.TotalSeconds
            );
            logger.Warning(string.Join(Environment.NewLine, failures));
        }
    }
}
